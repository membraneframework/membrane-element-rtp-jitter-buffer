defmodule Membrane.Event.RTCP.MetadataRequest do
  @derive Membrane.EventProtocol
end

defmodule Membrane.Event.RTCP.Metadata do
  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
          extended_s_l: non_neg_integer(),
          fraction_lost: float(),
          interarrival_jitter: non_neg_integer(),
          packets_lost_total: non_neg_integer()
        }

  defstruct [
    :extended_s_l,
    :fraction_lost,
    :interarrival_jitter,
    :packets_lost_total
  ]
end

defmodule Membrane.Event.RTCP.AdjustDelay do
  @derive Membrane.EventProtocol

  defstruct new_delay: 0
end
