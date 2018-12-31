defmodule Membrane.Element.RTP.JitterBuffer.SampleClock do
  @moduledoc false
  use GenServer
  @timer_delay 30

  @impl true
  def init(pid) do
    schedule_work()

    {:ok,
     %{
       target: pid
     }}
  end

  @impl true
  def handle_info(:tick, %{target: pid} = state) do
    schedule_work()
    Process.send_after(pid, :tick, @timer_delay)
    {:noreply, state}
  end

  defp schedule_work() do
    Process.send_after(self(), :tick, @timer_delay)
  end
end
