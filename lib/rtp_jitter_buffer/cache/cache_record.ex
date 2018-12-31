defmodule Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord do
  @moduledoc """
  Describes a structure that is stored in Cache.
  """
  alias Membrane.Element.RTP.JitterBuffer.Types
  @enforce_keys [:seq_num, :timestamp, :buffer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          seq_num: Types.sequence_number(),
          timestamp: Types.timestamp(),
          buffer: Membrane.Buffer.t()
        }

  @spec new(Membrane.Buffer.t(), Types.sequence_number(), Types.timestamp()) ::
          Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord.t()
  def new(buffer, seq_num, timestamp),
    do: %__MODULE__{
      seq_num: seq_num,
      timestamp: timestamp,
      buffer: buffer
    }

  @spec rtp_comparator(t(), t()) :: boolean()
  def rtp_comparator(%__MODULE__{seq_num: l_seq_num}, %__MODULE__{seq_num: r_seq_num}),
    do: l_seq_num < r_seq_num
end
