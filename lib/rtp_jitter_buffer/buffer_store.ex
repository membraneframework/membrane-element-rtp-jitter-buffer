defmodule Membrane.Element.RTP.JitterBuffer.BufferStore do
  @moduledoc """
  Store for RTP packets. Packets are stored in `Heap` ordered by packet index. Packet index is
  defined in RFC 3711 (SRTP) as: 2^16 * rollover count + sequence number.

  ## Fields
    - `rollover_count` - count of all performed rollovers
    - `heap` - contains records containing buffers
    - `prev_index` - index of the last packet that has been served
    - `end_index` - index of the oldest packet inserted into the store

  """
  use Bunch
  alias Membrane.Element.RTP.JitterBuffer
  alias Membrane.Buffer

  @seq_number_limit 65_536
  @seq_num_rollover_delta 1_500

  defstruct prev_index: nil,
            end_index: nil,
            heap: Heap.new(&__MODULE__.Record.rtp_comparator/2),
            rollover_count: 0

  @type t :: %__MODULE__{
          prev_index: JitterBuffer.packet_index() | nil,
          end_index: JitterBuffer.packet_index() | nil,
          heap: Heap.t(),
          rollover_count: non_neg_integer()
        }

  @typedoc """
  An atom describing an error that may happen during insertion.
  """
  @type insert_error :: :late_packet

  @typedoc """
  An atom describing an error that may happen when fetching a buffer
  from the Store.
  """
  @type get_buffer_error :: :not_present

  @doc """
  Inserts buffer into the Store.

  Every subsequent buffer must have sequence number Bigger than the previously returned
  one or be part of rollover.
  """
  @spec insert_buffer(t(), Buffer.t()) :: {:ok, t()} | {:error, insert_error()}
  def insert_buffer(store, %Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer),
    do: do_insert_buffer(store, buffer, seq_num)

  @doc """
  Calculates size of the Store.

  Size is calculated by counting `slots` between youngest (buffer with
  smallest sequence number) and oldest buffer.

  If Store has buffers [1,2,10] its size would be 10.
  """
  @spec size(__MODULE__.t()) :: number()
  def size(store)
  def size(%__MODULE__{heap: %Heap{data: nil}}), do: 0

  def size(%__MODULE__{prev_index: nil, end_index: last, heap: heap}) do
    size = if Heap.size(heap) == 1, do: 1, else: last - Heap.root(heap).index + 1
    size
  end

  def size(%__MODULE__{prev_index: prev_index, end_index: end_index}) do
    end_index - prev_index
  end

  @doc """
  Shifts the store to the buffer with the next sequence number.

  If this buffer is present, it will be returned.
  Otherwise it will be treated as late and rejected on attempt to insert into the store.
  """
  @spec shift(t) :: {__MODULE__.Record.t() | nil, t}
  def shift(store)

  def shift(%__MODULE__{prev_index: nil, heap: heap} = store) do
    {record, updated_heap} = Heap.split(heap)

    {record, %__MODULE__{store | heap: updated_heap, prev_index: record.index}}
  end

  def shift(%__MODULE__{prev_index: prev_index, heap: heap} = store) do
    record = Heap.root(heap)

    expected_next_index = prev_index + 1

    {result, store} =
      if record != nil and record.index == expected_next_index do
        updated_heap = Heap.pop(heap)

        updated_store = %__MODULE__{store | heap: updated_heap}

        {record, updated_store}
      else
        {nil, store}
      end

    {result, bump_prev_index(store)}
  end

  @doc """
  Shifts the store until the first gap in sequence numbers of records
  """
  @spec shift_ordered(t) :: {[__MODULE__.Record.t() | nil], t}
  def shift_ordered(store) do
    {records, store} = do_shift_ordered(store, [])
    {Enum.reverse(records), store}
  end

  defp do_shift_ordered(%__MODULE__{heap: heap, prev_index: prev_index} = store, acc) do
    heap
    |> Heap.root()
    |> case do
      %__MODULE__.Record{index: index} when index == prev_index + 1 ->
        {record, store} = shift(store)
        do_shift_ordered(store, [record | acc])

      _ ->
        {acc, store}
    end
  end

  @doc """
  Shifts the store as long as it contains a buffer with the timestamp older than provided duration
  """
  @spec shift_older_than(t, Membrane.Time.t()) :: {[__MODULE__.Record.t() | nil], t}
  def shift_older_than(store, max_age) do
    max_age_timestamp = Membrane.Time.monotonic_time() - max_age
    {records, store} = do_shift_older_than(store, max_age_timestamp, [])
    {Enum.reverse(records), store}
  end

  defp do_shift_older_than(%__MODULE__{heap: heap} = store, boundary_time, acc) do
    heap
    |> Heap.root()
    |> case do
      %__MODULE__.Record{timestamp: time} when time <= boundary_time ->
        {record, store} = shift(store)
        do_shift_older_than(store, boundary_time, [record | acc])

      _ ->
        {acc, store}
    end
  end

  @doc """
  Returns all buffers that are stored in the `BufferStore`.
  """
  @spec dump(nil | t()) :: [__MODULE__.Record.t()]
  def dump(%__MODULE__{} = store), do: to_list(store)

  # Private API

  @spec do_insert_buffer(t(), Buffer.t(), JitterBuffer.sequence_number()) ::
          {:ok, t()} | {:error, insert_error()}
  defp do_insert_buffer(%__MODULE__{prev_index: nil} = store, buffer, seq_num) do
    updated_store = add_to_heap(store, __MODULE__.Record.new(buffer, seq_num))
    {:ok, updated_store}
  end

  defp do_insert_buffer(
         %__MODULE__{prev_index: prev_index, rollover_count: roc} = store,
         buffer,
         seq_num
       ) do
    index =
      if has_rolled_over?(prev_index, seq_num) do
        seq_num + (roc + 1) * @seq_number_limit
      else
        seq_num + roc * @seq_number_limit
      end

    if is_fresh_packet?(prev_index, index) do
      record = __MODULE__.Record.new(buffer, index)
      {:ok, add_to_heap(store, record)}
    else
      {:error, :late_packet}
    end
  end

  defp is_fresh_packet?(prev_index, index), do: index > prev_index

  # Checks if the sequence number has rolled over
  # Assumes the rollover happened if old sequence number was within @seq_num_rollover_delta from the limit
  # and the new one is below @seq_num_rollover_delta.
  # This means it can report a false positive but only if a packet is late by more than (limit - 2 * delta)
  # which is highly unlikely.
  @spec has_rolled_over?(JitterBuffer.packet_index(), JitterBuffer.sequence_number()) :: boolean
  defp has_rolled_over?(prev_index, seq_num) do
    prev_seq_num = rem(prev_index, @seq_number_limit)

    prev_seq_num > @seq_number_limit - @seq_num_rollover_delta and
      seq_num < @seq_num_rollover_delta
  end

  defp add_to_heap(%__MODULE__{heap: heap} = store, %__MODULE__.Record{} = record) do
    if contains_index(heap, record.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, record)}
      |> update_end_index(record.index)
    end
  end

  defp bump_prev_index(%{prev_index: prev, rollover_count: roc} = store)
       when rem(prev + 1, @seq_number_limit) == 0,
       do: %__MODULE__{store | prev_index: prev + 1, rollover_count: roc + 1}

  defp bump_prev_index(store), do: %__MODULE__{store | prev_index: store.prev_index + 1}

  defp update_end_index(%__MODULE__{end_index: last} = store, added_index)
       when added_index > last or last == nil,
       do: %__MODULE__{store | end_index: added_index}

  defp update_end_index(%__MODULE__{end_index: last} = store, added_index)
       when last >= added_index,
       do: store

  defp contains_index(heap, index) do
    Enum.reduce_while(heap, false, fn
      %__MODULE__.Record{index: ^index}, _acc -> {:halt, true}
      _, _ -> {:cont, false}
    end)
  end

  def to_list(nil), do: []

  def to_list(%__MODULE__{heap: heap}),
    do: Enum.into(heap, [])
end
