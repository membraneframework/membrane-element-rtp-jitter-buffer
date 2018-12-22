defmodule Membrane.Element.RTP.JitterBuffer.Cache do
  @type cache_record :: {0..65536, Membrane.Buffer.t()}

  @spec new() :: Heap.t()
  def new() do
    Heap.new(&rtp_comparator/2)
  end

  @spec insert(Heap.t(), any()) :: Heap.t()
  def insert(heap, element) do
    Heap.push(heap, element)
  end

  @spec first(Heap.t()) :: {cache_record(), Heap.t()} | {nil, nil}
  def first(heap) do
    Heap.split(heap)
  end

  @spec rtp_comparator(cache_record(), cache_record()) :: boolean()
  defp rtp_comparator({left, _}, {right, _}) do
    left < right
  end
end
