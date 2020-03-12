defmodule Membrane.Element.RTP.JitterBuffer.PipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer
  alias Membrane.Testing
  alias Membrane.Test.BufferFactory

  @seq_number_limit 65_536

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

  test "Jitter Buffer works in a Pipeline with small latency" do
    test_pipeline(300, 10, 200 |> Membrane.Time.millisecond())
  end

  test "Jitter Buffer works in a Pipeline with large latency" do
    test_pipeline(100, 30, 1000 |> Membrane.Time.millisecond())
  end

  @tag :long_running
  @tag timeout: 70_000 * 20 + 10000
  test "Jitter Buffer works in a long-running Pipeline with small latency" do
    test_pipeline(70_000, 20, 100 |> Membrane.Time.millisecond())
  end

  defp test_pipeline(buffers, buffer_delay_ms, latency) do
    latency_ms = latency |> Membrane.Time.to_milliseconds()

    {:ok, pipeline} =
      Testing.Pipeline.start_link(%Testing.Pipeline.Options{
        elements: [
          source: %PushTestingSrc{
            buffer_num: buffers,
            buffer_delay_ms: buffer_delay_ms,
            max_latency: latency_ms
          },
          buffer: %RTPJitterBuffer{latency: latency},
          sink: %Testing.Sink{}
        ]
      })

    Membrane.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :prepared)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    timeout = latency_ms + 500
    assert_start_of_stream(pipeline, :buffer, :input, 5000)
    assert_start_of_stream(pipeline, :sink, :input, timeout)

    Enum.each(1..buffers, fn index ->
      n = rem(index, @seq_number_limit)

      cond do
        rem(n, 50) >= 30 and rem(n, 50) <= 32 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{}, timeout)

        rem(n, 19) == 0 and rem(n, 15) != 0 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{}, timeout)

        true ->
          assert_sink_buffer(
            pipeline,
            :sink,
            %Membrane.Buffer{
              metadata: %{rtp: %{sequence_number: ^n, timestamp: _}},
              payload: _
            },
            timeout
          )
      end
    end)
  end
end
