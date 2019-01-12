defmodule Membrane.Element.RTP.JitterBuffer.PipelineTest do
  use ExUnit.Case

  alias Membrane.Testing
  alias Membrane.Test.BufferFactory
  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer

  @last_number 100

  test "Jitter Buffer works in a Pipeline" do
    buffer_size = 10

    {:ok, pipeline} =
      Testing.Pipeline.start_link(%Testing.Pipeline.Options{
        elements: [
          source: %Testing.Source{actions_generator: generate_buffer(buffer_size)},
          buffer: %RTPJitterBuffer{slot_count: buffer_size},
          sink: %Testing.Sink{target: self()}
        ]
      })

    Membrane.Pipeline.play(pipeline)

    Enum.each(1..(@last_number - 1), fn elem ->
      assert_receive %Membrane.Buffer{
                       metadata: %{rtp: %{sequence_number: ^elem, timestamp: _}},
                       payload: _
                     },
                     5000
    end)
  end

  def generate_buffer(buffer_size) do
    fn
      0, size ->
        {actions, cnt} = generate_buffer(buffer_size).(2, size - 1)
        {[action_from_number(1) | actions], cnt}

      cnt, _ when cnt > @last_number ->
        {[], cnt}

      @last_number, _ ->
        {[event: {:output, %Membrane.Event.EndOfStream{}}], @last_number + 1}

      cnt, size ->
        range = cnt..(cnt + size) |> trunc_range()
        _..last_element = range

        actions =
          range
          # Introduces slight variation in buffer order
          |> Enum.chunk_every(round(buffer_size / 2))
          |> Enum.flat_map(&Enum.shuffle/1)
          |> Enum.map(&action_from_number/1)

        {actions, last_element}
    end
  end

  defp action_from_number(element), do: {:buffer, {:output, BufferFactory.sample_buffer(element)}}

  defp trunc_range(start.._) when start >= @last_number, do: []
  defp trunc_range(start..range_end) when range_end >= @last_number, do: start..@last_number
  defp trunc_range(range), do: range
end
