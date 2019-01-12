defmodule Membrane.Element.RTP.JitterBufferTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer
  alias RTPJitterBuffer.State
  alias Membrane.Element.RTP.JitterBuffer.{Cache, CacheHelper}
  alias Membrane.Element.RTP.JitterBuffer.Cache.CacheRecord
  alias Membrane.Test.BufferFactory

  @base_seq_number 50
  @max_buffer_size 10

  setup_all do
    buffer = BufferFactory.sample_buffer(@base_seq_number)
    {:ok, cache} = Cache.insert_buffer(%Cache{}, buffer)
    state = %State{cache: cache, slot_count: @max_buffer_size}

    [state: state, buffer: buffer]
  end

  describe "When new packet comes Jitter Buffer" do
    test "adds that packet to buffer when it comes on time", %{state: state, buffer: buffer} do
      assert {:ok, state} = RTPJitterBuffer.handle_process(:input, buffer, nil, state)
      assert %RTPJitterBuffer.State{cache: cache} = state
      assert {:ok, {%CacheRecord{buffer: ^buffer}, _}} = Cache.get_next_buffer(cache)
    end

    test "refuses to add that packet when it comes late", %{state: state} do
      late_buffer = BufferFactory.sample_buffer(@base_seq_number - 2)
      assert {:ok, ^state} = RTPJitterBuffer.handle_process(:input, late_buffer, nil, state)
    end

    test "adds it and when buffer is full returns one buffer", %{state: state} do
      last_buffer = BufferFactory.sample_buffer(@base_seq_number + @max_buffer_size)

      assert {{:ok, commands}, %State{cache: result_cache}} =
               RTPJitterBuffer.handle_process(:input, last_buffer, nil, state)

      assert {:output, %Membrane.Buffer{metadata: %{rtp: %{sequence_number: 50}}}} =
               Keyword.fetch!(commands, :buffer)

      refute CacheHelper.has_buffer_with_seq_num(result_cache, @base_seq_number)
    end

    test "when buffer is missing returns an event discontinuity" do
      state = %State{slot_count: @max_buffer_size}
      first_buffer = BufferFactory.sample_buffer(@base_seq_number + @max_buffer_size / 2)
      last_buffer = BufferFactory.sample_buffer(@base_seq_number + @max_buffer_size)
      {:ok, cache} = Cache.insert_buffer(%Cache{}, first_buffer)
      filled_state = %State{state | cache: %Cache{cache | prev_seq_num: @base_seq_number - 1}}

      assert {{:ok, commands}, %State{cache: result_cache}} =
               RTPJitterBuffer.handle_process(:input, last_buffer, nil, filled_state)

      assert Keyword.fetch!(commands, :event) == {:output, %Membrane.Event.Discontinuity{}}
      assert result_cache.prev_seq_num == filled_state.cache.prev_seq_num + 1
    end
  end
end
