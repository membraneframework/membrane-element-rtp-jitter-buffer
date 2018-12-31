defmodule Membrane.Element.RTP.JitterBuffer.CacheHelper do
  @moduledoc false
  alias Membrane.Element.RTP.JitterBuffer.Cache

  @spec has_buffer(Cache.t(), Membrane.Buffer.t()) :: boolean()
  def has_buffer(%Cache{heap: heap}, buffer) do
    %Membrane.Buffer{metadata: %{rtp: %{sequence_number: seq_num, timestamp: timestamp}}} = buffer
    record = Cache.CacheRecord.new(buffer, seq_num, timestamp)
    Heap.member?(heap, record)
  end
end
