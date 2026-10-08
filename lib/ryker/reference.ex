defmodule Ryker.Reference do
  @moduledoc """
  The one rule for a reference string: valid UTF-8 with no NUL byte, not blank,
  and within a byte bound. Every module keeps its own error tuple; the rule is
  shared so a reference that one boundary accepts is one every boundary accepts.
  """
  alias Ryker.Text

  @default_maximum_bytes 1_024
  @token ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @doc """
  Whether `value` is a reference: a string of valid UTF-8, not blank, with no
  NUL byte, at most `maximum_bytes` long (1,024 unless given).
  """
  @spec valid?(term(), pos_integer()) :: boolean()
  def valid?(value, maximum_bytes \\ @default_maximum_bytes)

  def valid?(value, maximum_bytes) when is_binary(value) do
    byte_size(value) <= maximum_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  def valid?(_value, _maximum_bytes), do: false

  @doc """
  Whether `value` is an identifier-shaped reference: 1 to 256 ASCII letters,
  digits, `_`, `.`, `:` or `-`, as record, artifact and envelope refs are.
  """
  @spec token?(term()) :: boolean()
  def token?(value), do: is_binary(value) and Regex.match?(@token, value)

  @doc "The pattern `token?/1` matches, for a changeset's format check."
  @spec token_pattern() :: Regex.t()
  def token_pattern, do: @token

  @doc "Whether `value` is a UUID, as `Ecto.UUID` casts one."
  @spec uuid?(term()) :: boolean()
  def uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

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
  def text?(value, maximum) when is_binary(value),
    do: text?(value) and Text.char_length(value) <= maximum

  def text?(_value, _maximum), do: false

  @doc """
  `text?/2` under a byte bound too, for text a column or a wire format limits
  in bytes beside the characters a schema allows.
  """
  @spec text?(term(), pos_integer(), pos_integer()) :: boolean()
  def text?(value, maximum, maximum_bytes) when is_binary(value),
    do: text?(value, maximum) and byte_size(value) <= maximum_bytes

  def text?(_value, _maximum, _maximum_bytes), do: false

  @doc "Text of any length: valid UTF-8 with no NUL byte, not blank."
  @spec text?(term()) :: boolean()
  def text?(value) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != ""
  end

  def text?(_value), do: false
end
