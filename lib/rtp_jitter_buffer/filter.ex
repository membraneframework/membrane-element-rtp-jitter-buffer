defmodule Membrane.Element.RTP.JitterBuffer.Filter do
  use Membrane.Element.Base.Filter
  alias Membrane.Buffer
  alias Membrane.Element.RTP.JitterBuffer.Cache
  alias Membrane.Caps.RTP, as: Caps

  @roll_over_seq_num -1

  # TODO rename filter to something buffer like

  # Properties of Jitter Buffer
  # 2. Clock must be based on RTP clock / timestamp thingy bober
  # 3. Must handle sequence number overflow
  # 4. Must drop packet with too old deadline
  # 5. If packet does not come in the deadline must drop and send next valid

  # TODO Add buffer size
  # TODO handle rollover

  # Rollover strategy
  # Add field to state for rollover packets
  # When adding if rollover is list
  #  IF packet number is between last and max seq num
  #    add it to  cache
  #  else
  #    add it to rollover list

  # When last possible seqnum is served
  #   Pour rollover list to cache
  #   set last seq to -1 (so 0 packet will be released next)

  @deadline_interval 20
  @initial_deadline 100

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
                # TODO: Replace with time calulcated from RTP data
                description: "Amount of time between ticks in ms",
                default: 30
              ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:cache, :next_deadline]
    defstruct @enforce_keys ++ [:last_seq_num, :last_timestamp]

    @type t :: %__MODULE__{
            last_seq_num: 0..65536,
            last_timestamp: pos_integer() | nil,
            cache: Heap.t(),
            next_deadline: nil | 0..65536
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
  def handle_process(:input, buffer, _context, state) do
    %State{cache: cache, last_seq_num: last_seq_num} = state
    %Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer

    case seq_num do
      # SeqNum Rollover?
      0 ->
        nil

      value when value > last_seq_num ->
        updated_cache = Cache.insert(cache, {seq_num, buffer})
        {:ok, %State{state | cache: updated_cache}}

      # Lost packet came late ignore it
      value when value <= last_seq_num ->
        {:ok, state}
    end
  end

  @impl true
  def handle_other(:tick, _context, state) do
    %State{last_seq_num: last, cache: cache} = state
    next_should_be_served = last + 1

    cache
    |> Cache.first()
    |> handle_cache_lookup_result(next_should_be_served, state)
  end

  # TODO find a better name for me
  @spec handle_cache_lookup_result(
          {Cache.cache_record() | nil, Heap.t()},
          0..65536,
          State.t()
        ) :: Membrane.Element.Base.Mixin.CommonBehaviour.callback_return_t()
  defp handle_cache_lookup_result(result, next_expected_seq_number, state)

  defp handle_cache_lookup_result({{head_seq_num, buffer}, cache}, head_seq_num, state) do
    command = [buffer: {:output, buffer}]

    new_state = %State{
      state
      | cache: cache,
        last_seq_num: head_seq_num,
        next_deadline: nil
    }

    {{:ok, command}, new_state}
  end

  defp handle_cache_lookup_result({nil, _}, next, state) do
    apply_deadline(next, state)
  end

  defp handle_cache_lookup_result({{_, _}, _}, next, state) do
    apply_deadline(next, state)
  end

  defp apply_deadline(next, %State{next_deadline: next_deadline} = state) do
    next_deadline_value =
      case next_deadline do
        # packet is not yet on deadline
        nil ->
          @initial_deadline

        # packet is already on deadline
        value when is_number(value) ->
          value - @deadline_interval
      end

    cond do
      next_deadline_value <= 0 ->
        {:ok, %State{state | last_seq_num: next, next_deadline: nil}}

      true ->
        {:ok, %State{state | next_deadline: next_deadline_value}}
    end
  end
end
