defmodule Ryker.JSONSchema do
  @moduledoc """
  The fragments Ryker's model contracts repeat: text that is not blank and
  holds no NUL, within a bound, and a value that may also be null. A bound
  counts code points, as JSON Schema's `maxLength` does.
  """

  @nonblank "^[^\\x00]*[^\\s\\x00][^\\x00]*$"

  @doc "Text with a character that is not white space, no NUL, and at most `maximum` characters."
  @spec text(pos_integer()) :: map()
  def text(maximum),
    do: %{"maxLength" => maximum, "minLength" => 1, "pattern" => @nonblank, "type" => "string"}

  @doc "`schema`, or null."
  @spec nullable(map()) :: map()
  def nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}
end
