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
  @index_rollover_delta 1_500

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

  If Store has buffers [1,2,10] it size would be 10.
  """
  @spec size(__MODULE__.t()) :: number()
  def size(store)
  def size(%__MODULE__{heap: %Heap{data: nil}}), do: 0

  def size(%__MODULE__{prev_index: nil, end_index: last, heap: heap}) do
    size = if Heap.size(heap) == 1, do: 1, else: last - Heap.root(heap).index + 1
    size
  end

  def size(store) do
    %__MODULE__{prev_index: prev_index, end_index: end_index} = store
    heap_size(prev_index, end_index)
  end

  @doc """
  Retrieves next buffer if the top element's timestamp is less than given min_time.

  See get_next_buffer/1
  """
  def get_next_buffer(store, min_time) do
    store.heap
    |> Heap.root()
    |> case do
      %__MODULE__.Record{timestamp: time} when time <= min_time -> get_next_buffer(store)
      _ -> {:error, :not_present}
    end
  end

  @doc """
  Retrieves next buffer.

  If Store is empty or does not contain next buffer it will return error.
  """
  @spec get_next_buffer(t) :: {:ok, {__MODULE__.Record.t(), t}} | {:error, get_buffer_error()}
  def get_next_buffer(store)
  def get_next_buffer(%__MODULE__{heap: %Heap{data: nil}}), do: {:error, :not_present}

  def get_next_buffer(%__MODULE__{prev_index: nil, heap: heap} = store) do
    {record, updated_heap} = Heap.split(heap)

    {:ok, {record, %__MODULE__{store | heap: updated_heap, prev_index: record.index}}}
  end

  def get_next_buffer(%__MODULE__{prev_index: prev_index, heap: heap} = store) do
    %__MODULE__.Record{index: index} = Heap.root(heap)

    next_index = prev_index + 1

    if next_index == index do
      {record, updated_heap} = Heap.split(heap)

      record = %{record | index: rem(record.index, @seq_number_limit)}

      updated_store =
        %__MODULE__{store | heap: updated_heap}
        |> bump_prev_index(next_index)

      {:ok, {record, updated_store}}
    else
      {:error, :not_present}
    end
  end

  @doc """
  Skips buffer.
  """
  @spec skip_buffer(t) :: {:ok, t} | {:error}
  def skip_buffer(store)
  def skip_buffer(%__MODULE__{prev_index: nil}), do: {:error, :store_not_initialized}

  def skip_buffer(%__MODULE__{prev_index: last} = store),
    do: {:ok, bump_prev_index(store, last + 1)}

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
    index = seq_num + roc * @seq_number_limit

    cond do
      is_fresh_packet?(prev_index, index) ->
        record = __MODULE__.Record.new(buffer, index)
        {:ok, add_to_heap(store, record)}

      has_rolled_over?(roc, prev_index, index) ->
        record = __MODULE__.Record.new(buffer, index + @seq_number_limit)
        {:ok, add_to_heap(store, record)}

      true ->
        {:error, :late_packet}
    end
  end

  defp is_fresh_packet?(prev_index, index), do: index > prev_index

  defp has_rolled_over?(roc, prev_index, index) do
    next_rollover = (roc + 1) * @seq_number_limit

    prev_index > next_rollover - @index_rollover_delta and
      index + @seq_number_limit < next_rollover + @index_rollover_delta
  end

  defp add_to_heap(%__MODULE__{heap: heap} = store, %__MODULE__.Record{} = record) do
    if contains_index(heap, record.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, record)}
      |> update_end_index(record.index)
    end
  end

  defp bump_prev_index(store, next_index)

  defp bump_prev_index(store, next_index) when rem(next_index, @seq_number_limit) == 0,
    do: %__MODULE__{store | prev_index: next_index, rollover_count: store.rollover_count + 1}

  defp bump_prev_index(store, next_index), do: %__MODULE__{store | prev_index: next_index}

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

  defp heap_size(last, ending), do: ending - last

  def to_list(nil), do: []

  def to_list(%__MODULE__{heap: heap}),
    do: Enum.into(heap, [])
end
