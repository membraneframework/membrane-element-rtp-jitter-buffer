defmodule Membrane.Element.RTP.JitterBuffer.Types do
  @moduledoc false
  @type sequence_number :: 0..65_535
  @type timestamp :: pos_integer()
end
