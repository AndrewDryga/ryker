defmodule Ryker.Secret do
  @moduledoc """
  A value Ryker must never print: a key, or the values of saved credentials.

  Options carry these values from the runtime assembly to the few places that
  use them, through child specs and process state. A failed child start prints
  its child spec and a crash report prints the state, and both printed the
  checkpoint key and every saved credential's value (2026-10-04 review).
  Sealed, a value prints only as `#Ryker.Secret<redacted>`; the code that uses
  it calls `reveal/1` at the point of use.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  @spec new(term()) :: t()
  def new(value), do: %__MODULE__{value: value}

  @spec reveal(t()) :: term()
  def reveal(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(_secret, _options), do: "#Ryker.Secret<redacted>"
  end
end
