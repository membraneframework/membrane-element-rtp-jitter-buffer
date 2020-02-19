defmodule Membrane.Element.RTP.JitterBuffer.BufferStoreTest do
  use ExUnit.Case
  use Bunch

  alias Membrane.Element.RTP.JitterBuffer.{BufferStore, BufferStoreHelper}
  alias Membrane.Test.BufferFactory

  @seq_number_limit 65_536
  @base_index 65_505
  @next_index @base_index + 1

  setup_all do
    [base_store: new_testing_store(@base_index)]
  end

  describe "When adding buffer to the BufferStore it" do
    test "accepts first buffer and does not initiate" do
      buffer = BufferFactory.sample_buffer(@base_index)

      assert {:ok, updated_store} = BufferStore.insert_buffer(%BufferStore{}, buffer)
      assert BufferStoreHelper.has_buffer(updated_store, buffer)
    end

    test "refuses packet with a seq_number smaller than last served", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@base_index - 1)

      assert {:error, :late_packet} = BufferStore.insert_buffer(store, buffer)
    end

    test "accepts a buffer that got in time", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@next_index)
      assert {:ok, updated_store} = BufferStore.insert_buffer(store, buffer)
      assert BufferStoreHelper.has_buffer(updated_store, buffer)
    end

    test "puts it to the rollover if a sequence number has rolled over", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(10)
      assert {:ok, store} = BufferStore.insert_buffer(store, buffer)
      assert BufferStoreHelper.has_buffer(store, buffer)
    end

    test "extracts the RTP metadata correctly from buffer", %{base_store: store} do
      buffer = BufferFactory.sample_buffer(@next_index)
      {:ok, %BufferStore{heap: heap}} = BufferStore.insert_buffer(store, buffer)

      assert %BufferStore.Record{index: read_index} = Heap.root(heap)

      assert read_index == @next_index
    end

    test "does not change the BufferStore when duplicate is inserted", %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_index)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)
      assert {:ok, ^store} = BufferStore.insert_buffer(store, buffer)
    end
  end

  describe "When getting a buffer from BufferStore it" do
    setup %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_index)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)

      [
        store: store,
        buffer: buffer
      ]
    end

    test "returns the root buffer and initializes it", %{store: store, buffer: buffer} do
      assert {:ok, {record, empty_store}} = BufferStore.get_next_buffer(store)
      assert record.buffer == buffer
      assert empty_store.heap.size == 0
      assert empty_store.prev_index == record.index
    end

    test "returns an error when heap is empty", %{base_store: store} do
      assert {:error, :not_present} == BufferStore.get_next_buffer(store)
    end

    test "returns an error when heap is not empty, but the next buffer is not present", %{
      store: store
    } do
      broken_store = %BufferStore{store | prev_index: @base_index - 1}
      assert {:error, :not_present} == BufferStore.get_next_buffer(broken_store)
    end

    test "sorts buffers by index number", %{base_store: store} do
      test_base = 1..100

      test_base
      |> Enum.into([])
      |> Enum.shuffle()
      |> enum_into_store(store)
      |> (fn store -> store.heap end).()
      |> Enum.zip(test_base)
      |> Enum.each(fn {record, base_element} ->
        assert %BufferStore.Record{index: index} = record
        assert rem(index, 65_536) == base_element
      end)
    end

    test "handles rollover", %{base_store: base_store} do
      store = %BufferStore{base_store | prev_index: 65_533}
      before_rollover_indexs = 65_534..65_535
      after_rollover_indexs = 0..10

      combined = Enum.into(before_rollover_indexs, []) ++ Enum.into(after_rollover_indexs, [])
      combined_store = enum_into_store(combined, store)

      store =
        Enum.reduce(combined, combined_store, fn elem, store ->
          {:ok, {record, store}} = BufferStore.get_next_buffer(store)
          assert %BufferStore.Record{index: ^elem} = record
          store
        end)

      assert store.rollover_count == 1
    end

    test "handles empty rollover", %{base_store: base_store} do
      store = %BufferStore{base_store | prev_index: 65_533}
      base_data = Enum.into(65_534..65_535, [])
      store = enum_into_store(base_data, store)

      Enum.reduce(base_data, store, fn elem, store ->
        {:ok, {record, store}} = BufferStore.get_next_buffer(store)
        assert %BufferStore.Record{index: ^elem} = record
        store
      end)
    end

    test "handles later rollovers" do
      m = @seq_number_limit

      store = %BufferStore{prev_index: 3 * m - 6, rollover_count: 2}

      store =
        (Enum.into((m - 5)..(m - 1), []) ++ Enum.into(0..4, []))
        |> enum_into_store(store)

      assert BufferStore.size(store) == 10
    end

    test "handles late packets after a rollover" do
      indexes = [65_535, 0, 65_534]
      store = enum_into_store(indexes, %BufferStore{prev_index: 65_533})

      Enum.each(indexes, fn _index ->
        assert {:ok, {_record, store}} = BufferStore.get_next_buffer(store)
      end)
    end

    test "returns only stale buffers if min_time is given" do
      store = enum_into_store([1, 2])
      time = Membrane.Time.os_time()
      store = enum_into_store([3], store)

      assert {:ok, {%BufferStore.Record{index: 1}, store}} =
               BufferStore.get_next_buffer(store, time)

      assert {:ok, {%BufferStore.Record{index: 2}, store}} =
               BufferStore.get_next_buffer(store, time)

      assert {:error, _} = BufferStore.get_next_buffer(store, time)
      assert {:ok, {%BufferStore.Record{index: 3}, _}} = BufferStore.get_next_buffer(store)
    end
  end

  describe "When skipping buffer it" do
    test "increments sequence number", %{base_store: %BufferStore{prev_index: last} = store} do
      assert {:ok, %BufferStore{prev_index: next}} = BufferStore.skip_buffer(store)
      assert next = last + 1
    end

    test "returns an error if the BufferStore is uninitialized" do
      assert {:error, :store_not_initialized} == BufferStore.skip_buffer(%BufferStore{})
    end
  end

  describe "When counting size it" do
    test "counts empty slots as if they occupied space", %{base_store: base} do
      wanted_size = 10
      buffer = BufferFactory.sample_buffer(@base_index + wanted_size)
      {:ok, store} = BufferStore.insert_buffer(base, buffer)

      assert BufferStore.size(store) == wanted_size
    end

    test "returns 1 if the BufferStore has exactly one record", %{base_store: base_store} do
      buffer = BufferFactory.sample_buffer(@next_index)
      {:ok, store} = BufferStore.insert_buffer(base_store, buffer)
      assert BufferStore.size(store) == 1
    end

    test "returns 0 if the BufferStore is empty", %{base_store: store} do
      assert BufferStore.size(store) == 0
    end

    test "takes into account empty slots both before and after a rollover" do
      store = store_with_blanks(@seq_number_limit - 4)
      assert BufferStore.size(store) == 10
    end

    test "if store is not initialized and heap has exactly one element returns 1" do
      {:ok, store} = %BufferStore{} |> BufferStore.insert_buffer(BufferFactory.sample_buffer(2))
      assert BufferStore.size(store) == 1
    end

    test "if store is not initialized and heap has more than one element return proper size" do
      wanted_size = 10
      next_index = @base_index + wanted_size - 1

      {:ok, store} =
        %BufferStore{}
        |> BufferStore.insert_buffer(BufferFactory.sample_buffer(@base_index))
        ~> ({:ok, store} ->
              BufferStore.insert_buffer(store, BufferFactory.sample_buffer(next_index)))

      assert BufferStore.size(store) == wanted_size
    end
  end

  describe "When dumping it" do
    test "returns list that contains buffers from heap" do
      store = enum_into_store(1..10)
      result = BufferStore.dump(store)
      assert is_list(result)
      assert Enum.count(result) == 10
    end

    test "returns empty list if no records are inside" do
      assert BufferStore.dump(%BufferStore{}) == []
    end
  end

  defp new_testing_store(index) do
    %BufferStore{
      prev_index: index,
      end_index: index,
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

  # Returns shuffled store that span over 10 slots
  defp store_with_blanks(base) do
    (Enum.into(1..2, []) ++ Enum.into(5..7, []) ++ Enum.into(9..10, []))
    |> Enum.shuffle()
    |> Enum.map(&rem(&1 + base, @seq_number_limit))
    |> enum_into_store(%BufferStore{
      prev_index: rem(base, @seq_number_limit),
      rollover_count: div(base, @seq_number_limit)
    })
  end
end
