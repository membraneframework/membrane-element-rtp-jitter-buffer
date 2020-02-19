defmodule Membrane.Element.RTP.JitterBuffer.PipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer
  alias Membrane.Testing
  alias Membrane.Test.BufferFactory

  @last_number 1000
  @buffer_size 100

  test "Jitter Buffer works in a Pipeline" do
    test_pipeline(nil, false)
  end

  test "Jitter Buffer outputs the entire store" do
    test_pipeline(1, true)
  end

  defp test_pipeline(delay, simple) do
    {:ok, pipeline} =
      Testing.Pipeline.start_link(%Testing.Pipeline.Options{
        elements: [
          source: %Testing.Source{output: {1, generate_buffer(simple)}},
          buffer: %RTPJitterBuffer{max_delay: delay, slot_count: @buffer_size},
          sink: %Testing.Sink{}
        ]
      })

    Membrane.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    Enum.each(1..(@last_number - 1), fn elem ->
      assert_sink_buffer(
        pipeline,
        :sink,
        %Membrane.Buffer{
          metadata: %{rtp: %{sequence_number: ^elem, timestamp: _}},
          payload: _
        },
        5000
      )
    end)
  end

  defp generate_buffer(simple) do
    fn
      cnt, _ when cnt > @last_number ->
        {[], cnt}

      @last_number, _ ->
        {[event: {:output, %Membrane.Event.EndOfStream{}}], @last_number + 1}

      cnt, size ->
        range = cnt..(cnt + size) |> trunc_range()
        _..last_element = range

        if simple do
          actions =
            range
            |> Enum.map(&action_from_number/1)

          {actions, last_element + 1}
        else
          actions =
            range
            # Introduces slight variation in buffer order
            |> Enum.chunk_every(round(@buffer_size / 2))
            |> Enum.flat_map(&Enum.shuffle/1)
            |> Enum.map(&action_from_number/1)

          {actions, last_element}
        end
    end
  end

  defp action_from_number(element), do: {:buffer, {:output, BufferFactory.sample_buffer(element)}}

  defp trunc_range(start.._) when start >= @last_number, do: []
  defp trunc_range(start..range_end) when range_end >= @last_number, do: start..@last_number
  defp trunc_range(range), do: range
end
