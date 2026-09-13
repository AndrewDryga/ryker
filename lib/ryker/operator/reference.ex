defmodule Ryker.Operator.Reference do
  @moduledoc """
  The one shape every operator-supplied identifier has.

  A reference is bounded, valid UTF-8 with no NUL byte and something other
  than whitespace in it. A refusal names the field and the boundary that
  refused it, never the value. Five modules carried their own copy of this
  check and had drifted: one accepted a whitespace-only episode key, another
  reported every malformed field as `:reference`.
  """

  @spec check(term(), atom(), atom(), pos_integer()) :: :ok | {:error, {atom(), atom()}}
  def check(value, field, boundary, maximum \\ 1_024)

  def check(value, field, boundary, maximum)
      when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {boundary, field}}
  end

  def check(_value, field, boundary, _maximum), do: {:error, {boundary, field}}
end
