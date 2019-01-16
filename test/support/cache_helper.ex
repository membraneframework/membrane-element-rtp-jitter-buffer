defmodule Membrane.Element.RTP.JitterBuffer.BufferStoreHelper do
  @moduledoc false
  alias Membrane.Element.RTP.JitterBuffer.BufferStore

  @spec has_buffer(BufferStore.t(), Membrane.Buffer.t()) :: boolean()
  def has_buffer(%BufferStore{heap: heap}, buffer) do
    %Membrane.Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer
    record = BufferStore.Record.new(buffer, seq_num)
    Heap.member?(heap, record)
  end

  @spec has_buffer_with_seq_num(BufferStore.t(), pos_integer()) :: boolean()
  def has_buffer_with_seq_num(store, seq_num) when is_number(seq_num),
    do: has_buffer(store, Membrane.Test.BufferFactory.sample_buffer(seq_num))
end
