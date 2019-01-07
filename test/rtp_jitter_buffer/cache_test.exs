defmodule Membrane.Element.RTP.JitterBuffer.CacheTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer.{Cache, CacheHelper}
  alias Cache.CacheRecord
  alias Membrane.Test.BufferFactory

  @base_seq_num 65_505
  @next_seq_num @base_seq_num + 1

  setup_all do
    [base_cache: new_testing_cache(@base_seq_num)]
  end

  describe "When adding buffer to the Cache it" do
    test "accepts first buffer" do
      buffer = BufferFactory.sample_buffer(@base_seq_num)

      assert {:ok, updated_cache} = Cache.insert_buffer(%Cache{}, buffer)
      assert CacheHelper.has_buffer(updated_cache, buffer)
    end

    test "refuses packet with a seq_number smaller than last served", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@base_seq_num - 1)

      assert {:error, :late_packet} = Cache.insert_buffer(cache, buffer)
    end

    test "accepts a buffer that got in time", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      assert {:ok, updated_cache} = Cache.insert_buffer(cache, buffer)
      assert CacheHelper.has_buffer(updated_cache, buffer)
    end

    test "puts it to the rollover if a sequence number has rolled over", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(10)
      assert {:ok, cache} = Cache.insert_buffer(cache, buffer)
      assert Enum.member?(cache.rollover, buffer)
    end

    test "extracts the RTP metadata correctly from buffer", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, %Cache{heap: heap}} = Cache.insert_buffer(cache, buffer)

      assert %CacheRecord{seq_num: read_seq_num} = Heap.root(heap)

      assert read_seq_num == @next_seq_num
    end

    test "does not change the Cache when duplicate is inserted", %{base_cache: base_cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, cache} = Cache.insert_buffer(base_cache, buffer)
      assert {:ok, ^cache} = Cache.insert_buffer(cache, buffer)
    end
  end

  describe "When getting a buffer from Cache it" do
    setup %{base_cache: base_cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, cache} = Cache.insert_buffer(base_cache, buffer)

      [
        cache: cache,
        buffer: buffer
      ]
    end

    test "returns the root buffer", %{cache: cache, buffer: buffer} do
      assert {:ok, {record, empty_cache}} = Cache.get_next_buffer(cache)
      assert record.buffer == buffer
      assert empty_cache.heap.size == 0
      assert empty_cache.last_seq_num == record.seq_num
    end

    test "returns an error when heap is empty", %{base_cache: cache} do
      assert {:error, :not_present} == Cache.get_next_buffer(cache)
    end

    test "returns an error when heap is not empty, but the next buffer is not present", %{
      cache: cache
    } do
      broken_cache = %Cache{cache | last_seq_num: @base_seq_num - 1}
      assert {:error, :not_present} == Cache.get_next_buffer(broken_cache)
    end

    test "sorts buffers by sequence_number", %{base_cache: cache} do
      test_base = 1..100

      test_base
      |> Enum.into([])
      |> Enum.shuffle()
      |> enum_into_cache(cache)
      |> (fn cache -> cache.heap end).()
      |> Enum.zip(test_base)
      |> Enum.each(fn {record, base_element} ->
        assert %CacheRecord{seq_num: seq_num} = record
        assert seq_num == base_element
      end)
    end

    test "handles rollover", %{base_cache: base_cache} do
      cache = %Cache{base_cache | last_seq_num: 65_533}
      before_rollover_seq_nums = 65_534..65_535
      after_rollover_seq_nums = 0..10

      combined = Enum.into(before_rollover_seq_nums, []) ++ Enum.into(after_rollover_seq_nums, [])
      combined_cache = enum_into_cache(combined, cache)

      Enum.reduce(combined, combined_cache, fn elem, cache ->
        {:ok, {record, cache}} = Cache.get_next_buffer(cache)
        assert %CacheRecord{seq_num: ^elem} = record
        cache
      end)
    end
  end

  describe "When skipping buffer it" do
    test "increments sequence number", %{base_cache: %Cache{last_seq_num: last} = cache} do
      assert {:ok, %Cache{last_seq_num: next}} = Cache.skip_buffer(cache)
      assert next = last + 1
    end

    test "returns an error if the Cache is uninitialized" do
      assert {:error, :cache_not_initialized} == Cache.skip_buffer(%Cache{})
    end

    test "rolls over if needed", %{base_cache: cache} do
      updated_cache = %Cache{cache | last_seq_num: 65_535}
      assert {:ok, %Cache{cache | last_seq_num: 0}} == Cache.skip_buffer(updated_cache)
    end
  end

  describe "when counting size it" do
    test "counts empty slots as if they occupied space", %{base_cache: base} do
      wanted_size = 10
      buffer = BufferFactory.sample_buffer(@base_seq_num + wanted_size)
      {:ok, cache} = Cache.insert_buffer(base, buffer)

      assert Cache.size(cache) == wanted_size
    end

    test "returns 1 if the Cache has exactly one record", %{base_cache: base_cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, cache} = Cache.insert_buffer(base_cache, buffer)
      assert Cache.size(cache) == 1
    end

    test "returns 0 if the Cache is empty", %{base_cache: cache} do
      assert Cache.size(cache) == 0
    end

    test "handles rollover size" do
      rollover = rollover_with_blanks()

      cache = %Cache{rollover: rollover, last_seq_num: 50, end_seq_num: 50}
      assert Cache.size(cache) == 10
    end

    test "takes into account empty slots in both rollover and heap", %{base_cache: base} do
      buffer = BufferFactory.sample_buffer(@base_seq_num + 10)

      {:ok, cache} =
        %Cache{base | rollover: rollover_with_blanks()}
        |> Cache.insert_buffer(buffer)

      assert Cache.size(cache) == 20
    end
  end

  defp new_testing_cache(seq_num) do
    %Cache{
      last_seq_num: seq_num,
      end_seq_num: seq_num,
      rollover: [],
      heap: Heap.new(&CacheRecord.rtp_comparator/2)
    }
  end

  defp enum_into_cache(enumerable, cache) do
    Enum.reduce(enumerable, cache, fn elem, acc ->
      buffer = BufferFactory.sample_buffer(elem)
      {:ok, cache} = Cache.insert_buffer(acc, buffer)
      cache
    end)
  end

  # Returns shuffled rollover list that span over 10 slots
  defp rollover_with_blanks() do
    (Enum.into(1..2, []) ++ Enum.into(5..7, []) ++ Enum.into(9..10, []))
    |> Enum.shuffle()
    |> Enum.map(&BufferFactory.sample_buffer/1)
  end
end
