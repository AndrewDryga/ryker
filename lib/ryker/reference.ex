defmodule Ryker.Reference do
  @moduledoc """
  The one rule for a reference string: valid UTF-8 with no NUL byte, not blank,
  and within a byte bound. Every module keeps its own error tuple; the rule is
  shared so a reference that one boundary accepts is one every boundary accepts.
  """

  @default_maximum_bytes 1_024

  @spec valid?(term(), pos_integer()) :: boolean()
  def valid?(value, maximum_bytes \\ @default_maximum_bytes)

  def valid?(value, maximum_bytes) when is_binary(value) do
    byte_size(value) <= maximum_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  def valid?(_value, _maximum_bytes), do: false

  @doc """
  The rule for text a person or model wrote: valid UTF-8 with no NUL byte, not
  blank, and at most `maximum` characters, counted as the tool schemas count
  them (code points). Counting bytes refused text in any language but English
  that the schema had allowed (2026-10-04 review).
  """
  @spec text?(term(), pos_integer()) :: boolean()
  def text?(value, maximum) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and length(String.codepoints(value)) <= maximum
  end

  def text?(_value, _maximum), do: false
end
