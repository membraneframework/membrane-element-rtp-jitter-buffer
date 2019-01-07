defmodule Membrane.Element.RTP.JitterBuffer do
  @doc """
  Element that buffers and reorders RTP packets based on sequence_number.
  """
  use Membrane.Element.Base.Filter
  alias Membrane.Element.RTP.JitterBuffer.Cache
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Caps.RTP, as: Caps

  # TODO Maybe this buffer should be "toilet" type element not pull nor pull
  # With current approach we can't ever fully empty buffer

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
                will start send buffer through `:output` pad.
                """
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:slot_count]
    defstruct cache: %Cache{}, slot_count: 0

    @type t :: %__MODULE__{
            cache: Cache.t(),
            slot_count: pos_integer()
          }
  end

  # TODO recalculate bytes to buffers
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_init(%__MODULE__{slot_count: slot_count}),
    do: {:ok, %State{slot_count: slot_count}}

  @impl true
  def handle_process(:input, buffer, _context, %State{cache: cache} = state) do
    case Cache.insert_buffer(cache, buffer) do
      {:ok, result} ->
        new_state = %State{state | cache: result}

        if buffer_full?(new_state) do
          retrieve_buffer(new_state)
        else
          {:ok, new_state}
        end

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp retrieve_buffer(%State{cache: cache} = state) do
    case Cache.get_next_buffer(cache) do
      {:ok, {%CacheRecord{buffer: out_buffer}, cache}} ->
        action = [{:buffer, {:output, out_buffer}}]
        {{:ok, action}, %State{state | cache: cache}}

      {:error, :not_present} ->
        {:ok, updated_cache} = Cache.skip_buffer(cache)
        action = [{:event, {:output, %Membrane.Event.Discontinuity{}}}]
        {{:ok, action}, %State{state | cache: updated_cache}}
    end
  end

  defp buffer_full?(%State{cache: cache, slot_count: slot_count}),
    do: Cache.size(cache) >= slot_count
end
