defmodule Membrane.Element.RTP.JitterBuffer.Filter do
  use Membrane.Element.Base.Filter
  alias Membrane.Element.RTP.JitterBuffer.Cache
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Caps.RTP, as: Caps

  # TODO rename filter to something buffer like

  # Properties of Jitter Buffer
  # 2. Clock must be based on RTP clock / timestamp thingy bober
  # 3. Must handle sequence number overflow
  # 4. Must drop packet with too old deadline
  # 5. If packet does not come in the deadline must drop and send next valid

  # Possible corner case
  # when timestamp of last (seq_num=65536) and first (seq_num=0)

  # TODO Add buffer size

  # Problem with using timestamps is that few packets can have same timestamp but different seq_num

  @deadline_interval 20
  @initial_deadline 100
  @seq_number_delta 100
  @max_seq_num :math.pow(2, 16) - 1

  defguard is_?(new_seq_num, last_seq_num)
           when new_seq_num < @seq_number_delta and
                  last_seq_num < @max_seq_num - @seq_number_delta

  def_output_pads output: [
                    caps: Caps
                  ]

  def_input_pads input: [
                   caps: Caps,
                   demand_unit: :buffers
                 ]

  def_options setup_clock: [
                description: "Function that sets up scheduler"
              ],
              clock_interval: [
                # TODO: Replace with time calculated from RTP data
                description: "Amount of time between ticks in ms",
                default: 30
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:cache, :next_deadline]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            cache: Cache.t(),
            next_deadline: nil | pos_integer()
          }
  end

  @impl true
  def handle_init(options) do
    %__MODULE__{
      setup_clock: setup_clock,
      clock_interval: clock_interval
    } = options

    setup_clock.(clock_interval)
    {:ok, %State{cache: Cache.new(), next_deadline: nil}}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{cache: cache} = state) do
    case Cache.insert_buffer(cache, buffer) do
      {:ok, result} -> {:ok, %State{state | cache: result}}
      {:error, _reason} -> {:ok, state}
    end
  end

  @impl true
  def handle_other(:tick, _context, %State{cache: cache} = state) do
    cache
    |> Cache.get_next_buffer()
    |> handle_cache_lookup_result(state)
  end

  @spec handle_cache_lookup_result(
          {:ok, {CacheRecord.t(), t}} | {:error, Cache.get_buffer_error()},
          State.t()
        ) :: Membrane.Element.Base.Mixin.CommonBehaviour.callback_return_t()
  defp handle_cache_lookup_result(result, state)

  defp handle_cache_lookup_result({:ok, {%CacheRecord{buffer: buffer}, cache}}, state) do
    command = [buffer: {:output, buffer}]
    new_state = %State{state | cache: cache, next_deadline: nil}
    {{:ok, command}, new_state}
  end

  defp handle_cache_lookup_result({:error, :not_present}, state) do
    apply_deadline(state)
  end

  defp apply_deadline(%State{next_deadline: next_deadline} = state) do
    next_deadline_value =
      case next_deadline do
        # packet is not yet on deadline
        nil ->
          @initial_deadline

        # packet is already on deadline
        value when is_number(value) ->
          value - @deadline_interval
      end

    if next_deadline_value <= 0 do
      {:ok, %State{state | cache: Cache.skip_buffer(state.cache), next_deadline: nil}}
    else
      {:ok, %State{state | next_deadline: next_deadline_value}}
    end
  end
end
