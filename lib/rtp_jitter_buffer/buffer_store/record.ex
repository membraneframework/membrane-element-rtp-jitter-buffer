defmodule Membrane.Element.RTP.JitterBuffer.BufferStore.Record do
  @moduledoc """
  Describes a structure that is stored in the BufferStore.
  """
  alias Membrane.Element.RTP.JitterBuffer
  @enforce_keys [:seq_num, :buffer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          seq_num: JitterBuffer.sequence_number(),
          buffer: Membrane.Buffer.t()
        }

  @spec new(Membrane.Buffer.t(), JitterBuffer.sequence_number()) :: t()
  def new(buffer, seq_num), do: %__MODULE__{seq_num: seq_num, buffer: buffer}

  @doc """
  Compares two records.

  Returns true if the first record is older than the second one.
  """
  # Designed to use with Heap: https://gitlab.com/jimsy/heap/blob/master/lib/heap.ex#L71
  @spec rtp_comparator(t(), t()) :: boolean()
  def rtp_comparator(%__MODULE__{seq_num: l_seq_num}, %__MODULE__{seq_num: r_seq_num}),
    do: l_seq_num < r_seq_num
end
