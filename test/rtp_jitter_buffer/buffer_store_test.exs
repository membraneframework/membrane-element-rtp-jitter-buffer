defmodule Membrane.Element.RTP.JitterBuffer.BufferStoreTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer.{BufferStore, BufferStoreHelper}
  alias Membrane.Test.BufferFactory

  @base_seq_num 65_505
  @next_seq_num @base_seq_num + 1

  setup_all do
    [base_store: new_testing_store(@base_seq_num)]
  end

  describe "When adding buffer to the BufferStore it" do
    test "accepts first buffer" do
      buffer = BufferFactory.sample_buffer(@base_seq_num)

      assert {:ok, updated_store} = BufferStore.insert_buffer(%BufferStore{}, buffer)
      assert BufferStoreHelper.has_buffer(updated_store, buffer)
    end

    test "refuses packet with a seq_number smaller than last served", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@base_seq_num - 1)

      assert {:error, :late_packet} = BufferStore.insert_buffer(store, buffer)
    end

    test "accepts a buffer that got in time", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      assert {:ok, updated_store} = BufferStore.insert_buffer(store, buffer)
      assert BufferStoreHelper.has_buffer(updated_store, buffer)
    end

    test "puts it to the rollover if a sequence number has rolled over", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(10)
      assert {:ok, store} = BufferStore.insert_buffer(store, buffer)
      assert BufferStoreHelper.has_buffer(store.rollover, buffer)
    end

    test "extracts the RTP metadata correctly from buffer", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, %BufferStore{heap: heap}} = BufferStore.insert_buffer(store, buffer)

      assert %BufferStore.Record{seq_num: read_seq_num} = Heap.root(heap)

      assert read_seq_num == @next_seq_num
    end

    test "does not change the BufferStore when duplicate is inserted", %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)
      assert {:ok, ^store} = BufferStore.insert_buffer(store, buffer)
    end
  end

  describe "When getting a buffer from BufferStore it" do
    setup %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)

      [
        store: store,
        buffer: buffer
      ]
    end

    test "returns the root buffer", %{store: store, buffer: buffer} do
      assert {:ok, {record, empty_store}} = BufferStore.get_next_buffer(store)
      assert record.buffer == buffer
      assert empty_store.heap.size == 0
      assert empty_store.prev_seq_num == record.seq_num
    end

    test "returns an error when heap is empty", %{base_store: store} do
      assert {:error, :not_present} == BufferStore.get_next_buffer(store)
    end

    test "returns an error when heap is not empty, but the next buffer is not present", %{
      store: store
    } do
      broken_store = %BufferStore{store | prev_seq_num: @base_seq_num - 1}
      assert {:error, :not_present} == BufferStore.get_next_buffer(broken_store)
    end

    test "sorts buffers by sequence_number", %{base_store: store} do
      test_base = 1..100

      test_base
      |> Enum.into([])
      |> Enum.shuffle()
      |> enum_into_store(store)
      |> (fn store -> store.heap end).()
      |> Enum.zip(test_base)
      |> Enum.each(fn {record, base_element} ->
        assert %BufferStore.Record{seq_num: seq_num} = record
        assert seq_num == base_element
      end)
    end

    test "handles rollover", %{base_store: base_store} do
      store = %BufferStore{base_store | prev_seq_num: 65_533}
      before_rollover_seq_nums = 65_534..65_535
      after_rollover_seq_nums = 0..10

      combined = Enum.into(before_rollover_seq_nums, []) ++ Enum.into(after_rollover_seq_nums, [])
      combined_store = enum_into_store(combined, store)

      Enum.reduce(combined, combined_store, fn elem, store ->
        {:ok, {record, store}} = BufferStore.get_next_buffer(store)
        assert %BufferStore.Record{seq_num: ^elem} = record
        store
      end)
    end
  end

  describe "When skipping buffer it" do
    test "increments sequence number", %{base_store: %BufferStore{prev_seq_num: last} = store} do
      assert {:ok, %BufferStore{prev_seq_num: next}} = BufferStore.skip_buffer(store)
      assert next = last + 1
    end

    test "returns an error if the BufferStore is uninitialized" do
      assert {:error, :store_not_initialized} == BufferStore.skip_buffer(%BufferStore{})
    end

    test "rolls over if needed", %{base_store: store} do
      updated_store = %BufferStore{store | prev_seq_num: 65_535}

      assert {:ok, %BufferStore{store | prev_seq_num: 0}} ==
               BufferStore.skip_buffer(updated_store)
    end
  end

  describe "When counting size it" do
    test "counts empty slots as if they occupied space", %{base_store: base} do
      wanted_size = 10
      buffer = BufferFactory.sample_buffer(@base_seq_num + wanted_size)
      {:ok, store} = BufferStore.insert_buffer(base, buffer)

      assert BufferStore.size(store) == wanted_size
    end

    test "returns 1 if the BufferStore has exactly one record", %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_seq_num)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)
      assert BufferStore.size(store) == 1
    end

    test "returns 0 if the BufferStore is empty", %{base_store: store} do
      assert BufferStore.size(store) == 0
    end

    test "handles rollover size" do
      rollover = rollover_with_blanks()

      store = %BufferStore{rollover: rollover, prev_seq_num: 50, end_seq_num: 50}
      assert BufferStore.size(store) == 10
    end

    test "takes into account empty slots in both rollover and heap", %{base_store: base} do
      buffer = BufferFactory.sample_buffer(@base_seq_num + 10)

      {:ok, store} =
        %BufferStore{base | rollover: rollover_with_blanks()}
        |> BufferStore.insert_buffer(buffer)

      assert BufferStore.size(store) == 20
    end
  end

  describe "When dumping it" do
    test "returns list that contains both buffers from heap and rollover" do
      store = enum_into_store(1..10)
      rollover = enum_into_store(1..10)
      result = BufferStore.dump(%BufferStore{store | rollover: rollover})
      assert is_list(result)
      assert Enum.count(result) == 20
    end

    test "returns empty list if no records are inside" do
      assert BufferStore.dump(%BufferStore{}) == []
    end
  end

  defp new_testing_store(seq_num) do
    %BufferStore{
      prev_seq_num: seq_num,
      end_seq_num: seq_num,
      rollover: nil,
      heap: Heap.new(&BufferStore.Record.rtp_comparator/2)
    }
  end

  defp enum_into_store(enumerable, store \\ %BufferStore{}) do
    Enum.reduce(enumerable, store, fn elem, acc ->
      buffer = BufferFactory.sample_buffer(elem)
      {:ok, store} = BufferStore.insert_buffer(acc, buffer)
      store
    end)
  end

  # Returns shuffled rollover list that span over 10 slots
  defp rollover_with_blanks() do
    (Enum.into(1..2, []) ++ Enum.into(5..7, []) ++ Enum.into(9..10, []))
    |> Enum.shuffle()
    |> enum_into_store(%BufferStore{prev_seq_num: 0})
  end
end
