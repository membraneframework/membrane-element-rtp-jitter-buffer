defmodule Membrane.Element.RTP.JitterBuffer.CacheHelper do
  @moduledoc false
  alias Membrane.Element.RTP.JitterBuffer.Cache

  @spec has_buffer(Cache.t(), Membrane.Buffer.t()) :: boolean()
  def has_buffer(%Cache{heap: heap}, buffer) do
    %Membrane.Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer
    record = Cache.CacheRecord.new(buffer, seq_num)
    Heap.member?(heap, record)
  end

  @spec has_buffer_with_seq_num(Cache.t(), pos_integer()) :: boolean()
  def has_buffer_with_seq_num(cache, seq_num) when is_number(seq_num),
    do: has_buffer(cache, Membrane.Test.BufferFactory.sample_buffer(seq_num))
end
