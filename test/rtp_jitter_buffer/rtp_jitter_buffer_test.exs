defmodule Membrane.Element.RTP.JitterBufferTest do
  use ExUnit.Case

  alias Membrane.Element.RTP.JitterBuffer.Filter, as: RTPJitterBuffer
  alias Membrane.Element.RTP.JitterBuffer.Cache
  alias Membrane.Buffer

  @base_seq_number 50
  @next_seq_number @base_seq_number + 1

  setup_all do
    [state: sample_state(@base_seq_number)]
  end

  describe "When new packet comes Jitter Buffer" do
    test "adds that packet to buffer when it comes on time", %{state: state} do
      buffer = sample_buffer(@next_seq_number)

      assert {:ok, %RTPJitterBuffer.State{cache: cache}} =
               RTPJitterBuffer.handle_process(:input, buffer, nil, state)

      assert {{seq_num, _}, _} = Cache.first(cache)
      assert seq_num == @next_seq_number
    end

    test "refuses to add that packet when it comes late", %{state: state} do
      buffer = sample_buffer(@base_seq_number - 1)

      assert {:ok, state} == RTPJitterBuffer.handle_process(:input, buffer, nil, state)
    end
  end

  describe "When clock ticks Jitter Buffer" do
    test "if possible returns next packet", %{state: state} do
      buffer = sample_buffer(@next_seq_number)
      cache = Cache.insert(Cache.new(), {@next_seq_number, buffer})
      state = %RTPJitterBuffer.State{state | cache: cache}

      assert {{:ok, commands}, state} = RTPJitterBuffer.handle_other(:tick, nil, state)

      assert Keyword.fetch!(commands, :buffer) == {:output, buffer}

      assert state == %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: Cache.new(),
               next_deadline: nil,
               last_served_seq_num: @next_seq_number
             }
    end

    test "if supposed next packet has no deadline it starts with default value", %{state: state} do
      assert {:ok, state} = RTPJitterBuffer.handle_other(:tick, nil, state)

      assert state == %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: Cache.new(),
               next_deadline: 100,
               last_served_seq_num: 50
             }
    end

    test "reduces TTL if packet is already on a deadline", %{state: state} do
      new_state = %RTPJitterBuffer.State{state | next_deadline: 500}

      assert {:ok, state} = RTPJitterBuffer.handle_other(:tick, nil, new_state)

      assert state == %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: Cache.new(),
               next_deadline: 480,
               last_served_seq_num: @base_seq_number
             }
    end

    test "if TTL drops to 0 it just returns next packet", %{state: state} do
      new_state = %RTPJitterBuffer.State{state | next_deadline: 0}

      assert {:ok, result_state} = RTPJitterBuffer.handle_other(:tick, nil, new_state)

      assert result_state == %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: Cache.new(),
               next_deadline: nil,
               last_served_seq_num: @next_seq_number
             }
    end

    test "if packet comes late it returns it and clears it's deadline", %{state: state} do
      buffer = sample_buffer(@next_seq_number)
      cache = Cache.insert(Cache.new(), {@next_seq_number, buffer})
      new_state = %RTPJitterBuffer.State{state | next_deadline: 50, cache: cache}

      assert {{:ok, commands}, state} = RTPJitterBuffer.handle_other(:tick, nil, new_state)

      assert Keyword.fetch!(commands, :buffer) == {:output, buffer}

      assert %Membrane.Element.RTP.JitterBuffer.Filter.State{
               cache: Cache.new(),
               last_served_seq_num: @next_seq_number,
               next_deadline: nil
             } == state
    end
  end

  defp sample_buffer(seq_num) do
    %Buffer{
      metadata: %{rtp: %{sequence_number: seq_num}},
      payload: <<0, 255>>
    }
  end

  defp sample_state(seq_num) do
    %RTPJitterBuffer.State{
      last_served_seq_num: seq_num,
      cache: Cache.new(),
      next_deadline: nil
    }
  end
end
