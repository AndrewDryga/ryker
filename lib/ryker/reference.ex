defmodule Ryker.Reference do
  @moduledoc """
  The one rule for a reference string: valid UTF-8 with no NUL byte, not blank,
  and within a byte bound. Every module keeps its own error tuple; the rule is
  shared so a reference that one boundary accepts is one every boundary accepts.
  """
  alias Ryker.Text

  @default_maximum_bytes 1_024

  @spec valid?(term(), pos_integer()) :: boolean()
  def valid?(value, maximum_bytes \\ @default_maximum_bytes)

  def valid?(value, maximum_bytes) when is_binary(value) do
    byte_size(value) <= maximum_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  def valid?(_value, _maximum_bytes), do: false

  @doc """
  `valid?/2` as a boundary's answer: `:ok`, or `{:error, {boundary, field}}`
  naming the field and the boundary that refused it, never the value.
  """
  @spec check(term(), atom(), atom(), pos_integer()) :: :ok | {:error, {atom(), atom()}}
  def check(value, field, boundary, maximum_bytes \\ @default_maximum_bytes) do
    if valid?(value, maximum_bytes), do: :ok, else: {:error, {boundary, field}}
  end

  @doc """
  The rule for text a person or model wrote: valid UTF-8 with no NUL byte, not
  blank, and at most `maximum` characters, counted as the tool schemas count
  them (code points). Counting bytes refused text in any language but English
  that the schema had allowed (2026-10-04 review).
  """
  @spec text?(term(), pos_integer()) :: boolean()
  def text?(value, maximum) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and Text.char_length(value) <= maximum
  end

  def text?(_value, _maximum), do: false
end
