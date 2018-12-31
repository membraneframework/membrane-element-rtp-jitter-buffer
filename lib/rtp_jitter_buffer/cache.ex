defmodule Membrane.Element.RTP.JitterBuffer.Cache do
  # TODO Write more detailed
  @moduledoc """
  Cache for RTP packets. Packets are stored in `Heap` ordered by sequence number.

  ## Fields
    - `rollover` - contains buffers waiting for rollover to happen and get inserted into heap
    - `heap - contains` records containing buffers
    - `last_timestamp` - timestamp of last packet that has been served
    - `last_seq_num` - sequence number of last packet that has been served
  """
  alias Membrane.Element.RTP.JitterBuffer.Types
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Buffer

  @last_seq_num 65_535
  @seq_num_rollover_delta 1_500

  @enforce_keys [:heap]
  defstruct [:last_seq_num, :last_timestamp, :heap, :rollover]

  @type t :: %__MODULE__{
          last_timestamp: pos_integer() | nil,
          last_seq_num: Types.sequence_number() | nil,
          heap: Heap.t(),
          rollover: [Membrane.Buffer.t()]
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
  Creates new uninitialized Cache.
  """
  @spec new() :: t()
  def new() do
    heap = Heap.new(&CacheRecord.rtp_comparator/2)
    %__MODULE__{heap: heap, rollover: []}
  end

  @doc """
  Calls `insert_buffer/4` with metadata extracted from `Membrane.Buffer` passed as second argument.
  """
  @spec insert_buffer(t(), Buffer.t()) :: {:ok, t()} | {:error, insert_error()}
  def insert_buffer(cache, buffer) do
    {seq_number, timestamp} = extract_metadata(buffer)
    insert_buffer(cache, buffer, seq_number, timestamp)
  end

  @doc """
  Inserts buffer into Cache.

  When Cache is uninitialized it will accept any buffer as if it arrived on time.

  Every subsequent buffer must have sequence number bigger then previous one
  or be part of rollover.
  """
  @spec insert_buffer(t(), Buffer.t(), Types.sequence_number(), Types.timestamp()) ::
          {:ok, t()} | {:error, insert_error()}
  def insert_buffer(
        %__MODULE__{last_timestamp: nil, last_seq_num: nil} = cache,
        buffer,
        seq_num,
        timestamp
      ) do
    updated_cache =
      %__MODULE__{cache | last_seq_num: seq_num - 1, last_timestamp: timestamp - 1}
      |> add_to_heap(CacheRecord.new(buffer, seq_num, timestamp))

    {:ok, updated_cache}
  end

  def insert_buffer(cache, buffer, seq_num, timestamp) do
    %__MODULE__{
      last_seq_num: last_seq_num,
      last_timestamp: last_timestamp
    } = cache

    cond do
      is_fresh_packet?(last_seq_num, last_timestamp, seq_num, timestamp) ->
        record = CacheRecord.new(buffer, seq_num, timestamp)
        {:ok, add_to_heap(cache, record)}

      has_rolled_over?(last_seq_num, last_timestamp, seq_num, timestamp) ->
        {:ok, add_to_rollover(cache, buffer)}

      true ->
        {:error, :late_packet}
    end
  end

  @doc """
  Retrieves next buffer.

  If Cache is empty or does not contain next buffer it will return error.
  """
  @spec get_next_buffer(t) :: {:ok, {CacheRecord.t(), t}} | {:error, get_buffer_error()}
  def get_next_buffer(cache)
  def get_next_buffer(%__MODULE__{heap: %Heap{data: nil}}), do: {:error, :not_present}

  def get_next_buffer(%__MODULE__{last_seq_num: last_seq_num, heap: heap} = cache) do
    %CacheRecord{seq_num: seq_num, timestamp: timestamp} = Heap.root(heap)

    next_seq_num = calc_next_seq_num(last_seq_num)

    if next_seq_num == seq_num do
      {record, updated_heap} = Heap.split(heap)

      updated_cache =
        %__MODULE__{cache | heap: updated_heap, last_timestamp: timestamp}
        |> bump_last_seq_num(next_seq_num)

      {:ok, {record, updated_cache}}
    else
      {:error, :not_present}
    end
  end

  @doc """
  Skips buffer.
  """
  @spec skip_buffer(t) :: t
  def skip_buffer(cache)
  def skip_buffer(%__MODULE__{last_seq_num: nil} = cache), do: cache

  def skip_buffer(%__MODULE__{last_seq_num: last} = cache),
    do: bump_last_seq_num(cache, calc_next_seq_num(last))

  # Private API

  defp is_fresh_packet?(last_seq_num, last_timestamp, seq_num, timestamp)

  defp is_fresh_packet?(last_seq_num, last_timestamp, seq_num, timestamp)
       when timestamp >= last_timestamp and seq_num > last_seq_num,
       do: true

  defp is_fresh_packet?(_, _, _, _), do: false

  defp has_rolled_over?(last_seq_num, last_timestamp, seq_num, timestamp)

  defp has_rolled_over?(last_seq_num, _, seq_num, _)
       when last_seq_num > @last_seq_num - @seq_num_rollover_delta and
              seq_num < @seq_num_rollover_delta,
       do: true

  defp has_rolled_over?(_, _, _, _), do: false

  defp add_to_heap(%__MODULE__{heap: heap} = cache, %CacheRecord{} = record),
    do: %__MODULE__{cache | heap: Heap.push(heap, record)}

  defp add_to_rollover(%__MODULE__{rollover: rollover} = cache, %Buffer{} = buffer),
    do: %__MODULE__{cache | rollover: [buffer | rollover]}

  defp extract_metadata(%Buffer{} = buffer) do
    %Buffer{metadata: %{rtp: %{sequence_number: seq_num, timestamp: timestamp}}} = buffer
    {seq_num, timestamp}
  end

  defp pour_rollover(%__MODULE__{rollover: rollover} = cache) do
    # Since we reached next cycle and buffers for 0 and forth are stored in rollover
    # we create a brand new Heap
    heap =
      rollover
      |> Enum.map(fn buffer ->
        {seq_num, timestamp} = extract_metadata(buffer)
        CacheRecord.new(buffer, seq_num, timestamp)
      end)
      |> Enum.reduce(Heap.new(&CacheRecord.rtp_comparator/2), fn record, heap ->
        Heap.push(heap, record)
      end)

    %__MODULE__{cache | heap: heap, rollover: []}
  end

  defp calc_next_seq_num(seq_number)
  defp calc_next_seq_num(@last_seq_num), do: 0
  defp calc_next_seq_num(seq_number) when seq_number in 0..(@last_seq_num - 1), do: seq_number + 1

  defp bump_last_seq_num(cache, next_seq_num)

  defp bump_last_seq_num(cache, @last_seq_num) do
    cache
    |> pour_rollover()
    |> (fn c -> %__MODULE__{c | last_seq_num: @last_seq_num} end).()
  end

  defp bump_last_seq_num(cache, next_seq_num), do: %__MODULE__{cache | last_seq_num: next_seq_num}
end
