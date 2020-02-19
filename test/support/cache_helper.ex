defmodule Membrane.Element.RTP.JitterBuffer.BufferStoreHelper do
  @moduledoc false
  alias Membrane.Element.RTP.JitterBuffer.BufferStore

  @spec has_buffer(BufferStore.t(), Membrane.Buffer.t()) :: boolean()
  def has_buffer(
        %BufferStore{} = store,
        %Membrane.Buffer{metadata: %{rtp: %{sequence_number: seq_num}}}
      ),
      do: has_buffer_with_index(store, seq_num)

  @spec has_buffer_with_index(BufferStore.t(), Membrane.Buffer.t()) :: boolean()
  def has_buffer_with_index(%BufferStore{heap: heap}, index) when is_integer(index) do
    heap
    |> Enum.to_list()
    |> Enum.map(& &1.buffer.metadata.rtp.sequence_number)
    |> Enum.member?(index)
  end
end
