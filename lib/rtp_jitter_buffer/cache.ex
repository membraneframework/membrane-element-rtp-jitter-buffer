defmodule Membrane.Element.RTP.JitterBuffer.Cache do
  use Bunch

  @moduledoc """
  Cache for RTP packets. Packets are stored in `Heap` ordered by sequence number.

  ## Fields
    - `rollover` - contains buffers waiting for rollover to happen and get inserted into the heap
    - `heap - contains` records containing buffers
    - `prev_seq_num` - sequence number of the last packet that has been served
    - `end_seq_num` - sequence number of the oldest packet inserted into the cache

  Cache is considered initialized when at least one record has been inserted.
  When a cache is uninitialized it can only receive records.
  """
  alias Membrane.Element.RTP.JitterBuffer.Types
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Buffer

  @max_seq_number 65_535
  @seq_num_rollover_delta 1_500

  defstruct prev_seq_num: nil,
            end_seq_num: nil,
            heap: Heap.new(&CacheRecord.rtp_comparator/2),
            rollover: nil

  @type t :: %__MODULE__{
          prev_seq_num: Types.sequence_number() | nil,
          end_seq_num: Types.sequence_number() | nil,
          heap: Heap.t(),
          rollover: t() | nil
        }

  @typedoc """
  An atom describing an error that may happen during insertion.
  """
  @type insert_error :: :late_packet

  @typedoc """
  An atom describing an error that may happen when fetching a buffer
  from Cache.
  """
  @type get_buffer_error :: :not_present

  @doc """
  Calls `insert_buffer/3` with metadata extracted from `Membrane.Buffer` passed as second argument.
  """
  @spec insert_buffer(t(), Buffer.t()) :: {:ok, t()} | {:error, insert_error()}
  def insert_buffer(cache, buffer) do
    seq_number = extract_seq_num(buffer)
    insert_buffer(cache, buffer, seq_number)
  end

  @doc """
  Inserts buffer into Cache.

  When Cache is uninitialized it will accept any buffer as if it arrived on time.

  Every subsequent buffer must have sequence number bigger then previous one
  or be part of rollover.
  """
  @spec insert_buffer(t(), Buffer.t(), Types.sequence_number()) ::
          {:ok, t()} | {:error, insert_error()}
  def insert_buffer(%__MODULE__{prev_seq_num: nil} = cache, buffer, seq_num) do
    updated_cache =
      %__MODULE__{cache | prev_seq_num: seq_num - 1}
      |> add_to_heap(CacheRecord.new(buffer, seq_num))

    {:ok, updated_cache}
  end

  def insert_buffer(%__MODULE__{prev_seq_num: prev_seq_num} = cache, buffer, seq_num) do
    cond do
      is_fresh_packet?(prev_seq_num, seq_num) ->
        record = CacheRecord.new(buffer, seq_num)
        {:ok, add_to_heap(cache, record)}

      has_rolled_over?(prev_seq_num, seq_num) ->
        {:ok, add_to_rollover(cache, buffer)}

      true ->
        {:error, :late_packet}
    end
  end

  @spec size(__MODULE__.t()) :: number()
  def size(cache)
  def size(%__MODULE__{heap: %Heap{data: nil}, rollover: nil}), do: 0

  def size(cache) do
    %__MODULE__{prev_seq_num: prev_seq_num, end_seq_num: end_seq_num, rollover: rollover} = cache
    heap_size(prev_seq_num, end_seq_num) + rollover_size(rollover)
  end

  @doc """
  Retrieves next buffer.

  If Cache is empty or does not contain next buffer it will return error.
  """
  @spec get_next_buffer(t) :: {:ok, {CacheRecord.t(), t}} | {:error, get_buffer_error()}
  def get_next_buffer(cache)
  def get_next_buffer(%__MODULE__{heap: %Heap{data: nil}}), do: {:error, :not_present}

  def get_next_buffer(%__MODULE__{prev_seq_num: prev_seq_num, heap: heap} = cache) do
    %CacheRecord{seq_num: seq_num} = Heap.root(heap)

    next_seq_num = calc_next_seq_num(prev_seq_num)

    if next_seq_num == seq_num do
      {record, updated_heap} = Heap.split(heap)

      updated_cache =
        %__MODULE__{cache | heap: updated_heap}
        |> bump_prev_seq_num(next_seq_num)

      {:ok, {record, updated_cache}}
    else
      {:error, :not_present}
    end
  end

  @doc """
  Skips buffer.

  If cache is uninitialized returns error.
  """
  @spec skip_buffer(t) :: {:ok, t} | {:error}
  def skip_buffer(cache)
  def skip_buffer(%__MODULE__{prev_seq_num: nil}), do: {:error, :cache_not_initialized}

  def skip_buffer(%__MODULE__{prev_seq_num: last} = cache),
    do: {:ok, bump_prev_seq_num(cache, calc_next_seq_num(last))}

  def dump(nil), do: []
  def dump(%__MODULE__{heap: heap, rollover: rollover}), do: Enum.into(heap, []) ++ dump(rollover)

  # Private API

  defp is_fresh_packet?(prev_seq_num, seq_num)

  defp is_fresh_packet?(prev_seq_num, seq_num)
       when seq_num > prev_seq_num,
       do: true

  defp is_fresh_packet?(_, _), do: false

  defp has_rolled_over?(prev_seq_num, seq_num)

  defp has_rolled_over?(prev_seq_num, seq_num)
       when prev_seq_num > @max_seq_number - @seq_num_rollover_delta and
              seq_num < @seq_num_rollover_delta,
       do: true

  defp has_rolled_over?(_, _), do: false

  defp add_to_heap(%__MODULE__{heap: heap} = cache, %CacheRecord{} = record) do
    if Heap.member?(heap, record) do
      cache
    else
      %__MODULE__{cache | heap: Heap.push(heap, record)}
      |> update_end_seq_num(record.seq_num)
    end
  end

  defp add_to_rollover(%__MODULE__{rollover: nil} = cache, %Buffer{} = buffer),
    do: add_to_rollover(%__MODULE__{cache | rollover: %__MODULE__{prev_seq_num: -1}}, buffer)

  defp add_to_rollover(%__MODULE__{rollover: rollover} = cache, %Buffer{} = buffer) do
    rollover
    |> insert_buffer(buffer)
    ~>> ({:ok, result} -> %__MODULE__{cache | rollover: result})
  end

  defp extract_seq_num(%Buffer{} = buffer),
    do: buffer ~> (%Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} -> seq_num)

  defp pour_rollover(%__MODULE__{rollover: rollover}),
    do: rollover

  defp calc_next_seq_num(seq_number), do: (seq_number + 1) |> rem(@max_seq_number + 1)

  defp bump_prev_seq_num(cache, next_seq_num)

  defp bump_prev_seq_num(cache, @max_seq_number) do
    cache
    |> pour_rollover()
    ~> %__MODULE__{&1 | prev_seq_num: @max_seq_number}
  end

  defp bump_prev_seq_num(cache, next_seq_num), do: %__MODULE__{cache | prev_seq_num: next_seq_num}

  defp update_end_seq_num(%__MODULE__{end_seq_num: last} = cache, added_seq_num)
       when added_seq_num > last or last == nil,
       do: %__MODULE__{cache | end_seq_num: added_seq_num}

  defp update_end_seq_num(%__MODULE__{end_seq_num: last} = cache, added_seq_num)
       when last >= added_seq_num,
       do: cache

  defp heap_size(last, ending), do: ending - last

  defp rollover_size(%__MODULE__{} = rollover), do: size(rollover)
  defp rollover_size(nil), do: 0
end
