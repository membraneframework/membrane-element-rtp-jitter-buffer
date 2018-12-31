defmodule Membrane.Element.RTP.JitterBufferTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer.Filter, as: RTPJitterBuffer
  alias Membrane.Element.RTP.JitterBuffer.Cache
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Test.BufferFactory

  @initial_deadline 100
  @base_seq_number 50

  setup_all do
    [state: sample_state(), buffer: BufferFactory.sample_buffer(@base_seq_number)]
  end

  describe "When initializing" do
    test "calls clock setup with clock interval" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      interval = 20
      clock_setup = fn a -> Agent.update(agent, fn _ -> a end) end

      options = %RTPJitterBuffer{
        setup_clock: clock_setup,
        clock_interval: interval
      }

      assert {:ok, %RTPJitterBuffer.State{cache: Cache.new(), next_deadline: nil}} ==
               RTPJitterBuffer.handle_init(options)

      assert Agent.get(agent, fn a -> a end) == interval
    end
  end

  describe "When new packet comes Jitter Buffer" do
    test "adds that packet to buffer when it comes on time", %{state: state, buffer: buffer} do
      assert {:ok, state} = RTPJitterBuffer.handle_process(:input, buffer, nil, state)

      assert %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: cache,
               next_deadline: nil
             } = state

      assert {:ok, {%CacheRecord{buffer: ^buffer}, _}} = Cache.get_next_buffer(cache)
    end

    test "refuses to add that packet when it comes late", %{state: state, buffer: buffer} do
      late_buffer = BufferFactory.sample_buffer(@base_seq_number - 2)
      {:ok, state} = RTPJitterBuffer.handle_process(:input, buffer, nil, state)
      assert {:ok, ^state} = RTPJitterBuffer.handle_process(:input, late_buffer, nil, state)
    end
  end

  describe "When clock ticks Jitter Buffer" do
    setup %{state: state, buffer: buffer} do
      {:ok, updated_cache} = Cache.insert_buffer(state.cache, buffer)

      [
        state_with_buffer: %RTPJitterBuffer.State{state | cache: updated_cache}
      ]
    end

    test "if possible returns next packet", %{state_with_buffer: state, buffer: buffer} do
      assert {{:ok, commands}, updated_state} = RTPJitterBuffer.handle_other(:tick, nil, state)

      assert Keyword.fetch!(commands, :buffer) == {:output, buffer}
      assert Enum.count(updated_state.cache.heap) == Enum.count(state.cache.heap) - 1
    end

    test "starts packet deadline with default value if packet is missing", %{state: state} do
      assert {:ok, state} = RTPJitterBuffer.handle_other(:tick, nil, state)
      assert state.next_deadline == @initial_deadline
    end

    test "reduces TTL if packet is already on a deadline", %{state: state} do
      state_with_deadline = %RTPJitterBuffer.State{state | next_deadline: @initial_deadline}
      assert {:ok, state} = RTPJitterBuffer.handle_other(:tick, nil, state_with_deadline)
      assert state.next_deadline < @initial_deadline
    end

    test "if TTL drops to 0 it just returns next packet", %{state: state} do
      state_with_deadline = %RTPJitterBuffer.State{state | next_deadline: 1}
      assert {:ok, state} = RTPJitterBuffer.handle_other(:tick, nil, state_with_deadline)
      assert state.next_deadline == nil
    end

    test "if packet comes late it returns it and clears it's deadline", context do
      %{state_with_buffer: state, buffer: buffer} = context
      state_deadline = %RTPJitterBuffer.State{state | next_deadline: 1}

      assert {{:ok, commands}, state} = RTPJitterBuffer.handle_other(:tick, nil, state_deadline)
      assert state.next_deadline == nil
      assert Keyword.fetch!(commands, :buffer) == {:output, buffer}
    end
  end

  defp sample_state() do
    %RTPJitterBuffer.State{
      cache: Cache.new(),
      next_deadline: nil
    }
  end
end
