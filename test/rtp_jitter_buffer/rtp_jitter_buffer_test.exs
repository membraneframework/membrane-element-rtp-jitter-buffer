defmodule Membrane.Element.RTP.JitterBufferTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer, as: RTPJitterBuffer
  alias RTPJitterBuffer.State
  alias Membrane.Element.RTP.JitterBuffer.{BufferStore, BufferStoreHelper}
  alias Membrane.Test.BufferFactory

  @base_seq_number 50
  @max_buffer_size 10

  setup_all do
    buffer = BufferFactory.sample_buffer(@base_seq_number)
    {:ok, store} = BufferStore.insert_buffer(%BufferStore{}, buffer)
    state = %State{store: store, slot_count: @max_buffer_size}

    [state: state, buffer: buffer]
  end

  describe "When new packet comes Jitter Buffer" do
    test "adds that packet to buffer when it comes on time", %{state: state, buffer: buffer} do
      assert {{:ok, redemand: :output}, state} =
               RTPJitterBuffer.handle_process(:input, buffer, nil, state)

      assert %RTPJitterBuffer.State{store: store} = state
      assert {:ok, {%BufferStore.Record{buffer: ^buffer}, _}} = BufferStore.get_next_buffer(store)
    end

    test "refuses to add that packet when it comes late", %{state: state} do
      store = %BufferStore{state.store | prev_index: @base_seq_number}
      state = %RTPJitterBuffer.State{state | store: store}
      late_buffer = BufferFactory.sample_buffer(@base_seq_number - 2)

      assert {{:ok, redemand: :output}, ^state} =
               RTPJitterBuffer.handle_process(:input, late_buffer, nil, state)
    end

    test "adds it and when buffer is full returns one buffer", %{state: state} do
      last_buffer = BufferFactory.sample_buffer(@base_seq_number + @max_buffer_size)

      assert {{:ok, commands}, %State{store: result_store}} =
               RTPJitterBuffer.handle_process(:input, last_buffer, nil, state)

      assert {:output, %Membrane.Buffer{metadata: %{rtp: %{sequence_number: 50}}}} =
               Keyword.fetch!(commands, :buffer)

      refute BufferStoreHelper.has_buffer_with_index(result_store, @base_seq_number)
    end

    test "when buffer is missing returns an event discontinuity" do
      state = %State{slot_count: @max_buffer_size}
      first_buffer = BufferFactory.sample_buffer(@base_seq_number + div(@max_buffer_size, 2))
      last_buffer = BufferFactory.sample_buffer(@base_seq_number + @max_buffer_size)
      {:ok, store} = BufferStore.insert_buffer(%BufferStore{}, first_buffer)
      store = %BufferStore{store | prev_index: @base_seq_number - 1}
      filled_state = %State{state | store: store}

      assert {{:ok, commands}, %State{store: result_store}} =
               RTPJitterBuffer.handle_process(:input, last_buffer, nil, filled_state)

      assert Keyword.fetch!(commands, :event) == {:output, %Membrane.Event.Discontinuity{}}
      assert result_store.prev_index == filled_state.store.prev_index + 1
    end
  end

  describe "When event arrives" do
    test "dumps store if event was end of stream", %{state: state, buffer: buffer} do
      assert {{:ok, actions}, r_state} = RTPJitterBuffer.handle_end_of_stream(:input, nil, state)

      assert Keyword.fetch!(actions, :buffer) == {:output, [buffer]}
    end
  end
end
