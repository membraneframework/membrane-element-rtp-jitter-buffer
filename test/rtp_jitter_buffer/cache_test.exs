defmodule Membrane.Element.RTP.JitterBuffer.CacheTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer.{Cache, CacheHelper}
  alias Cache.CacheRecord
  alias Membrane.Test.BufferFactory

  @base_seq_num 65_505
  @next_seq_num @base_seq_num + 1

  @base_timestamp @base_seq_num * BufferFactory.timestamp_increment()
  @next_timestamp @next_seq_num * BufferFactory.timestamp_increment()

  setup_all do
    [base_cache: new_testing_cache(@base_seq_num, @base_timestamp)]
  end

  describe "When adding buffer to Cache it" do
    test "accepts first buffer" do
      buffer = BufferFactory.sample_buffer(@base_seq_num)
      cache = Cache.new()

      assert {:ok, updated_cache} = Cache.insert_buffer(cache, buffer)
      assert CacheHelper.has_buffer(updated_cache, buffer)
    end

    test "refuses packet with seq_number smaller than last served", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@base_seq_num - 1)

      assert {:error, :late_packet} = Cache.insert_buffer(cache, buffer)
    end

    test "accepts buffer that got in time", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      assert {:ok, updated_cache} = Cache.insert_buffer(cache, buffer)
      assert CacheHelper.has_buffer(updated_cache, buffer)
    end

    test "puts buffer to rollover cache if sequence number has rolled over", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(10)
      assert {:ok, cache} = Cache.insert_buffer(cache, buffer)
      assert Enum.member?(cache.rollover, buffer)
    end

    test "extracts RTP metadata correctly from buffer", %{base_cache: cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, %Cache{heap: heap}} = Cache.insert_buffer(cache, buffer)

      assert %Cache.CacheRecord{seq_num: @next_seq_num, timestamp: @next_timestamp} =
               Heap.root(heap)
    end
  end

  describe "When getting buffer from Cache it" do
    setup %{base_cache: base_cache} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, cache} = Cache.insert_buffer(base_cache, buffer)

      [
        cache: cache,
        buffer: buffer
      ]
    end

    test "returns root buffer", %{cache: cache, buffer: buffer} do
      assert {:ok, {record, empty_cache}} = Cache.get_next_buffer(cache)
      assert record.buffer == buffer
      assert empty_cache.heap.size == 0
      assert empty_cache.last_seq_num == record.seq_num
      assert empty_cache.last_timestamp == record.timestamp
    end

    test "returns error when heap is empty", %{base_cache: cache} do
      assert {:error, :not_present} == Cache.get_next_buffer(cache)
    end

    test "returns error when heap is not empty, but next buffer is not present", %{cache: cache} do
      broken_cache = %Cache{
        cache
        | last_seq_num: @base_seq_num - 1,
          last_timestamp: @base_timestamp - 1
      }

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
      cache = %Cache{base_cache | last_seq_num: 65_533, last_timestamp: 0}
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

  describe "When skipping buffer" do
    test "bumps next seq_num", %{base_cache: %Cache{last_seq_num: last} = cache} do
      assert %Cache{last_seq_num: next} = Cache.skip_buffer(cache)
      assert next = last + 1
    end

    test "does nothing is cache has never seen a buffer" do
      cache = Cache.new()
      assert cache == Cache.skip_buffer(cache)
    end

    test "rolls over if needed", %{base_cache: cache} do
      updated_cache = %Cache{cache | last_seq_num: 65_535}
      assert %Cache{cache | last_seq_num: 0} == Cache.skip_buffer(updated_cache)
    end
  end

  defp new_testing_cache(seq_num, timestamp) do
    %Cache{
      last_timestamp: timestamp,
      last_seq_num: seq_num,
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
end
