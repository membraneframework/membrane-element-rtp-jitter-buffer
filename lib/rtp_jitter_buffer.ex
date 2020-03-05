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
                spec: Membrane.Time.t() | nil,
                default: nil,
                description: """
                Approximation of the highest acceptable delay for a packet. It serves as an
                alternative to slot count when a transmitting live data. Please note that a small
                enough max delay makes the slot count irrelevant. Expressed in nanoseconds since
                insertion time.
                """
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:slot_count]
    defstruct store: %BufferStore{},
              slot_count: 0,
              max_delay: nil

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            slot_count: pos_integer(),
            max_delay: Membrane.Time.t() | nil
          }
  end

  @impl true
  def handle_init(%__MODULE__{slot_count: slot_count, max_delay: max_delay}),
    do: {:ok, %State{slot_count: slot_count, max_delay: max_delay}}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %State{max_delay: max_delay} = state)
      when not is_nil(max_delay) do
    {records, store} = BufferStore.shift_older_than(state.store, max_delay)
    lb = length(records)

    demands = if lb < size, do: [demand: {:input, size - lb}], else: []

    actions = records |> Enum.map(&record_to_action/1)
    {{:ok, actions ++ demands}, %{state | store: store}}
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

        {buffers, store} =
          if buffer_full?(state) do
            {buffer, store} = BufferStore.shift(store)

            {[buffer], store}
          else
            {[], store}
          end

        {too_old_buffers, store} =
          if state.max_delay != nil do
            now = Membrane.Time.os_time()
            oldest_acceptable_time = now - state.max_delay
            BufferStore.shift_older_than(store, oldest_acceptable_time)
          else
            {[], store}
          end

        actions = (buffers ++ too_old_buffers) |> Enum.map(&record_to_action/1)

        {{:ok, actions ++ [redemand: :output]}, %{state | store: store}}

      {:error, :late_packet} ->
        warn("Late packet has arrived")
        {{:ok, redemand: :output}, state}
    end
  end

  defp record_to_action(nil), do: {:event, {:output, %Membrane.Event.Discontinuity{}}}
  defp record_to_action(%BufferStore.Record{buffer: buffer}), do: {:buffer, {:output, buffer}}

  defp buffer_full?(%State{store: store, slot_count: slot_count}),
    do: BufferStore.size(store) >= slot_count
end
