defmodule Membrane.Element.RTP.JitterBuffer do
  @doc """
  Element that buffers and reorders RTP packets based on sequence_number.
  """
  use Membrane.Element.Base.Filter
  use Bunch
  alias Membrane.Event.EndOfStream
  alias Membrane.Element.RTP.JitterBuffer.BufferStore
  alias Membrane.Caps.RTP, as: Caps

  @type sequence_number :: 0..65_535
  @type timestamp :: pos_integer()

  def_output_pads output: [
                    caps: Caps
                  ]

  def_input_pads input: [
                   caps: Caps,
                   demand_unit: :buffers
                 ]

  def_options slot_count: [
                type: :number,
                spec: pos_integer(),
                description: """
                Number of slots for buffers. Each time last slot is filled `JitterBuffer`
                will send buffer through `:output` pad.
                """
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:slot_count]
    defstruct store: %BufferStore{}, slot_count: 0

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            slot_count: pos_integer()
          }
  end

  @impl true
  def handle_init(%__MODULE__{slot_count: slot_count}),
    do: {:ok, %State{slot_count: slot_count}}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_event(:input, %EndOfStream{}, _context, %State{store: store} = state) do
    store
    |> BufferStore.dump()
    |> Enum.map(fn %BufferStore.Record{buffer: buffer} -> buffer end)
    ~> {{:ok, [buffer: {:output, &1}]}, %State{state | store: %BufferStore{}}}
  end

  def handle_event(_pad, _event, _context, state), do: {:ok, state}

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

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp retrieve_buffer(%State{store: store} = state) do
    case BufferStore.get_next_buffer(store) do
      {:ok, {%BufferStore.Record{buffer: out_buffer}, store}} ->
        action = [buffer: {:output, out_buffer}]
        {{:ok, action}, %State{state | store: store}}

      {:error, :not_present} ->
        {:ok, updated_store} = BufferStore.skip_buffer(store)
        action = [event: {:output, %Membrane.Event.Discontinuity{}}]
        {{:ok, action}, %State{state | store: updated_store}}
    end
  end

  defp buffer_full?(%State{store: store, slot_count: slot_count}),
    do: BufferStore.size(store) >= slot_count
end
