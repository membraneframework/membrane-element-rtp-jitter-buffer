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

  def_options latency: [
                type: :time,
                default: 200 |> Membrane.Time.millisecond(),
                description: """
                Delay introduced by JitterBuffer
                """
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:latency]
    defstruct store: %BufferStore{},
              latency: 0,
              waiting?: true,
              no_input_timeout: nil

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            latency: Membrane.Time.t(),
            waiting?: boolean(),
            no_input_timeout: reference
          }
  end

  @impl true
  def handle_init(%__MODULE__{latency: latency}),
    do: {:ok, %State{latency: latency}}

  @impl true
  def handle_start_of_stream(:input, _context, state) do
    Process.send_after(
      self(),
      :send_buffers,
      state.latency |> Membrane.Time.to_milliseconds()
    )

    {:ok, %{state | waiting?: true}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state),
    do: {{:ok, demand: {:input, size}}, state}

  @impl true
  def handle_end_of_stream(:input, _context, %State{store: store} = state) do
    store
    |> BufferStore.dump()
    |> Enum.map(&record_to_action/1)
    ~> {{:ok, &1 ++ [end_of_stream: :output]}, %State{state | store: %BufferStore{}}}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store, waiting?: true} = state) do
    _ = BufferStore.insert_buffer(store, buffer)
    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store} = state) do
    state = reset_timer(state)

    case BufferStore.insert_buffer(store, buffer) do
      {:ok, result} ->
        state = %State{state | store: result}
        send_buffers(state)

      {:error, :late_packet} ->
        warn("Late packet has arrived")
        {{:ok, redemand: :output}, state}
    end
  end

  @impl true
  def handle_other(:send_buffers, _context, state) do
    send_buffers(state)
  end

  defp send_buffers(%State{store: store} = state) do
    # Shift buffers that stayed in queue longer than latency and any gaps before them
    {too_old_records, store} = BufferStore.shift_older_than(store, state.latency)
    # Additionally, shift buffers as long as there are no gaps
    {buffers, store} = BufferStore.shift_ordered(store)

    actions = (too_old_records ++ buffers) |> Enum.map(&record_to_action/1)

    {{:ok, actions ++ [redemand: :output]}, %{state | store: store}}
  end

  @spec reset_timer(State.t()) :: State.t()
  defp reset_timer(%State{no_input_timeout: timer, latency: latency} = state) do
    if timer != nil do
      Process.cancel_timer(timer)
    end

    new_timer =
      Process.send_after(self(), :send_buffers, latency |> Membrane.Time.to_milliseconds())

    %State{state | no_input_timeout: new_timer}
  end

  defp record_to_action(nil), do: {:event, {:output, %Membrane.Event.Discontinuity{}}}
  defp record_to_action(%BufferStore.Record{buffer: buffer}), do: {:buffer, {:output, buffer}}
end
