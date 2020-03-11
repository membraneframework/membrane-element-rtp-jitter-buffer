defmodule Membrane.Element.RTP.JitterBuffer.PipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer
  alias Membrane.Testing
  alias Membrane.Test.BufferFactory

  defmodule PushTestingSrc do
    use Membrane.Source
    alias Membrane.Test.BufferFactory

    def_output_pad :output, caps: :any, mode: :push

    def_options buffer_num: [type: :number],
                buffer_delay_ms: [type: :number],
                max_latency: [type: :number]

    @impl true
    def handle_prepared_to_playing(
          _ctx,
          %{
            buffer_delay_ms: delay_ms,
            buffer_num: buffer_num,
            max_latency: max_latency
          } = state
        ) do
      now = System.monotonic_time(:millisecond)

      1..buffer_num
      |> Enum.each(fn n ->
        time =
          cond do
            # Delay less than max latency
            rem(n, 15) == 0 -> n * delay_ms + div(max_latency, 2)
            # Delay more than max latency
            rem(n, 19) == 0 -> n * delay_ms + max_latency * 2
            true -> n * delay_ms
          end

        if rem(n, 50) < 30 or rem(n, 50) > 32 do
          Process.send_after(self(), {:push_buffer, n}, now + time, abs: true)
        end
      end)

      {:ok, state}
    end

    @impl true
    def handle_other({:push_buffer, n}, _ctx, state) do
      actions = [action_from_number(n)]

      {{:ok, actions}, state}
    end

    defp action_from_number(element),
      do: {:buffer, {:output, BufferFactory.sample_buffer(element)}}
  end

  test "Jitter Buffer works in a Pipeline with large latency" do
    test_pipeline(200, 20 |> Membrane.Time.millisecond())
  end

  test "Jitter Buffer works in a Pipeline with small latency" do
    test_pipeline(500, 200 |> Membrane.Time.millisecond())
  end

  defp test_pipeline(buffers, latency) do
    latency_ms = latency |> Membrane.Time.to_milliseconds()

    {:ok, pipeline} =
      Testing.Pipeline.start_link(%Testing.Pipeline.Options{
        elements: [
          source: %PushTestingSrc{
            buffer_num: buffers,
            buffer_delay_ms: 10,
            max_latency: latency_ms
          },
          buffer: %RTPJitterBuffer{latency: latency},
          sink: %Testing.Sink{}
        ]
      })

    Membrane.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :prepared)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_start_of_stream(pipeline, :buffer, :input, 5000)
    assert_start_of_stream(pipeline, :sink, :input, latency_ms + 50)

    Enum.each(1..buffers, fn n ->
      cond do
        rem(n, 50) >= 30 and rem(n, 50) <= 32 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{}, 5000)

        rem(n, 19) == 0 and rem(n, 15) != 0 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{})

        true ->
          assert_sink_buffer(
            pipeline,
            :sink,
            %Membrane.Buffer{
              metadata: %{rtp: %{sequence_number: ^n, timestamp: _}},
              payload: _
            },
            5000
          )
      end
    end)
  end
end
