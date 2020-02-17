defmodule Membrane.Element.RTP.JitterBuffer do
  @doc """
  Element that buffers and reorders RTP packets based on sequence_number.
  """
  use Membrane.Filter
  use Bunch
  alias Membrane.Element.RTP.JitterBuffer.BufferStore
  alias Membrane.Caps.RTP, as: Caps

  use Membrane.Log

  @type packet_index :: non_neg_integer()
  @type sequence_number :: 0..65_535
  @type timestamp :: pos_integer()

  def_output_pad :output,
    caps: Caps

  def_input_pad :input,
    caps: Caps,
    demand_unit: :buffers

  def_options slot_count: [
                type: :number,
                spec: pos_integer(),
                description: """
                Number of slots for buffers. Each time last slot is filled `JitterBuffer`
                will send buffer through `:output` pad.
                """
              ],
              max_delay: [
                spec: non_neg_integer() | nil,
                default: nil,
                description: """
                Approximate of the highest acceptable delay for a packet. It serves as an
                alternative to slot count when a transmitting live data. Please not that a small
                enough max delay makes the slot count irrelevant. Expressed in nanoseconds since
                insertion time.
                """
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:slot_count]
    defstruct store: %BufferStore{},
              slot_count: 0,
              interarrival_jitter: 0,
              max_delay: 0

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            slot_count: pos_integer(),
            interarrival_jitter: non_neg_integer(),
            max_delay: non_neg_integer()
          }
  end

  @impl true
  def handle_init(%__MODULE__{slot_count: slot_count, max_delay: max_delay}),
    do: {:ok, %State{slot_count: slot_count, max_delay: max_delay}}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %State{max_delay: max_delay} = state)
      when not is_nil(max_delay) do
    {store, buffers} = retrieve_stale_buffers(state.store, max_delay)
    lb = length(buffers)

    demands = if lb < size, do: [demand: {:input, size - lb}], else: []
    buffers = [buffer: {:output, buffers}]

    {{:ok, buffers ++ demands}, %{state | store: store}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state),
    do: {{:ok, demand: {:input, size}}, state}

  @impl true
  def handle_end_of_stream(:input, _context, %State{store: store} = state) do
    store
    |> BufferStore.dump()
    |> Enum.map(fn %BufferStore.Record{buffer: buffer} -> buffer end)
    ~> {{:ok, [buffer: {:output, &1}, end_of_stream: :output]},
     %State{state | store: %BufferStore{}}}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store} = state) do
    case BufferStore.insert_buffer(store, buffer) do
      {:ok, result} ->
        state = %State{state | store: result}

        if buffer_full?(state) do
          retrieve_buffer(state)
        else
          {{:ok, redemand: :output}, state}
        end

      {:error, :late_packet} ->
        warn("Late packet has arrived")
        {{:ok, redemand: :output}, state}
    end
  end

  defp retrieve_stale_buffers(store, max_delay) do
    current_time = Membrane.Time.os_time()
    min_time = current_time - max_delay
    do_retrieve_stale_buffers(store, min_time, [])
  end

  defp do_retrieve_stale_buffers(store, min_time, acc) do
    store
    |> BufferStore.get_next_buffer(min_time)
    |> case do
      {:ok, {%BufferStore.Record{buffer: buffer}, store}} ->
        do_retrieve_stale_buffers(store, min_time, [buffer | acc])

      {:error, :not_present} ->
        {store, acc}
    end
  end

  defp retrieve_buffer(%State{store: store} = state) do
    case BufferStore.get_next_buffer(store) do
      {:ok, {%BufferStore.Record{buffer: out_buffer}, store}} ->
        action = [buffer: {:output, out_buffer}]
        {{:ok, action}, %State{state | store: store}}

      {:error, :not_present} ->
        {:ok, updated_store} = BufferStore.skip_buffer(store)
        action = [event: {:output, %Membrane.Event.Discontinuity{}}, redemand: :output]
        {{:ok, action}, %State{state | store: updated_store}}
    end
  end

  defp buffer_full?(%State{store: store, slot_count: slot_count}),
    do: BufferStore.size(store) >= slot_count
end
