defmodule Membrane.Element.RTP.JitterBuffer.BufferStore do
  @moduledoc """
  Store for RTP packets. Packets are stored in `Heap` ordered by sequence number.

  ## Fields
    - `rollover` - contains buffers waiting for rollover to happen and get inserted into the heap
    - `heap - contains` records containing buffers
    - `prev_seq_num` - sequence number of the last packet that has been served
    - `end_seq_num` - sequence number of the oldest packet inserted into the store

  Store is considered initialized when at least one record has been inserted.
  When a store is uninitialized it can only receive records.
  """
  use Bunch
  alias Membrane.Element.RTP.JitterBuffer
  alias Membrane.Buffer

  @max_seq_number 65_535
  @seq_num_rollover_delta 1_500

  defstruct prev_seq_num: nil,
            end_seq_num: nil,
            heap: Heap.new(&__MODULE__.Record.rtp_comparator/2),
            rollover: nil

  @type t :: %__MODULE__{
          prev_seq_num: JitterBuffer.sequence_number() | nil,
          end_seq_num: JitterBuffer.sequence_number() | nil,
          heap: Heap.t(),
          rollover: t() | nil
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

  When Store is uninitialized it will accept any buffer as if it arrived on time.

  Every subsequent buffer must have sequence number bigger then previous one
  or be part of rollover.
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
  def size(%__MODULE__{heap: %Heap{data: nil}, rollover: nil}), do: 0

  def size(store) do
    %__MODULE__{prev_seq_num: prev_seq_num, end_seq_num: end_seq_num, rollover: rollover} = store
    heap_size(prev_seq_num, end_seq_num) + rollover_size(rollover)
  end

  @doc """
  Retrieves next buffer.

  If Store is empty or does not contain next buffer it will return error.
  """
  @spec get_next_buffer(t) :: {:ok, {__MODULE__.Record.t(), t}} | {:error, get_buffer_error()}
  def get_next_buffer(store)
  def get_next_buffer(%__MODULE__{heap: %Heap{data: nil}}), do: {:error, :not_present}

  def get_next_buffer(%__MODULE__{prev_seq_num: prev_seq_num, heap: heap} = store) do
    %__MODULE__.Record{seq_num: seq_num} = Heap.root(heap)

    next_seq_num = calc_next_seq_num(prev_seq_num)

    if next_seq_num == seq_num do
      {record, updated_heap} = Heap.split(heap)

      updated_store =
        %__MODULE__{store | heap: updated_heap}
        |> bump_prev_seq_num(next_seq_num)

      {:ok, {record, updated_store}}
    else
      {:error, :not_present}
    end
  end

  @doc """
  Skips buffer.

  If store is uninitialized returns error.
  """
  @spec skip_buffer(t) :: {:ok, t} | {:error}
  def skip_buffer(store)
  def skip_buffer(%__MODULE__{prev_seq_num: nil}), do: {:error, :store_not_initialized}

  def skip_buffer(%__MODULE__{prev_seq_num: last} = store),
    do: {:ok, bump_prev_seq_num(store, calc_next_seq_num(last))}

  @doc """
  Returns all buffers that are stored in the `BufferStore`.
  """
  @spec dump(nil | t()) :: [__MODULE__.Record.t()]
  def dump(%__MODULE__{} = store), do: to_list(store)

  # Private API

  @spec do_insert_buffer(t(), Buffer.t(), JitterBuffer.sequence_number()) ::
          {:ok, t()} | {:error, insert_error()}
  defp do_insert_buffer(%__MODULE__{prev_seq_num: nil} = store, buffer, seq_num) do
    updated_store =
      %__MODULE__{store | prev_seq_num: seq_num - 1}
      |> add_to_heap(__MODULE__.Record.new(buffer, seq_num))

    {:ok, updated_store}
  end

  defp do_insert_buffer(%__MODULE__{prev_seq_num: prev_seq_num} = store, buffer, seq_num) do
    cond do
      is_fresh_packet?(prev_seq_num, seq_num) ->
        record = __MODULE__.Record.new(buffer, seq_num)
        {:ok, add_to_heap(store, record)}

      has_rolled_over?(prev_seq_num, seq_num) ->
        {:ok, add_to_rollover(store, buffer)}

      true ->
        {:error, :late_packet}
    end
  end

  defp is_fresh_packet?(prev_seq_num, seq_num), do: seq_num > prev_seq_num

  defp has_rolled_over?(prev_seq_num, seq_num) do
    prev_seq_num > @max_seq_number - @seq_num_rollover_delta and seq_num < @seq_num_rollover_delta
  end

  defp add_to_heap(%__MODULE__{heap: heap} = store, %__MODULE__.Record{} = record) do
    if Heap.member?(heap, record) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, record)}
      |> update_end_seq_num(record.seq_num)
    end
  end

  defp add_to_rollover(%__MODULE__{rollover: nil} = store, %Buffer{} = buffer),
    do: add_to_rollover(%__MODULE__{store | rollover: %__MODULE__{prev_seq_num: -1}}, buffer)

  defp add_to_rollover(%__MODULE__{rollover: rollover} = store, %Buffer{} = buffer) do
    rollover
    |> insert_buffer(buffer)
    ~>> ({:ok, result} -> %__MODULE__{store | rollover: result})
  end

  defp pour_rollover(%__MODULE__{rollover: rollover}),
    do: rollover

  defp calc_next_seq_num(seq_number), do: (seq_number + 1) |> rem(@max_seq_number + 1)

  defp bump_prev_seq_num(store, next_seq_num)

  defp bump_prev_seq_num(store, @max_seq_number) do
    store
    |> pour_rollover()
    ~> %__MODULE__{&1 | prev_seq_num: @max_seq_number}
  end

  defp bump_prev_seq_num(store, next_seq_num), do: %__MODULE__{store | prev_seq_num: next_seq_num}

  defp update_end_seq_num(%__MODULE__{end_seq_num: last} = store, added_seq_num)
       when added_seq_num > last or last == nil,
       do: %__MODULE__{store | end_seq_num: added_seq_num}

  defp update_end_seq_num(%__MODULE__{end_seq_num: last} = store, added_seq_num)
       when last >= added_seq_num,
       do: store

  defp heap_size(last, ending), do: ending - last

  defp rollover_size(%__MODULE__{} = rollover), do: size(rollover)
  defp rollover_size(nil), do: 0

  defp to_list(nil), do: []

  defp to_list(%__MODULE__{heap: heap, rollover: rollover}),
    do: Enum.into(heap, []) ++ to_list(rollover)
end
