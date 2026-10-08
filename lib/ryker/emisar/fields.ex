defmodule Ryker.Emisar.Fields do
  @moduledoc """
  Checks on the fields of what Emisar says about an approval and its review:
  a time, a reference, an optional text. Each answers `:ok` or names the kind
  of field it refused, so a refusal never echoes the value.
  """
  alias Ryker.{Reference, UTCDateTime}

  @doc "`:ok` for an ISO 8601 time with a zero offset; `{:error, :timestamp}` otherwise."
  @spec timestamp(term()) :: :ok | {:error, :timestamp}
  def timestamp(value) do
    case UTCDateTime.parse(value) do
      {:ok, _datetime} -> :ok
      :error -> {:error, :timestamp}
    end
  end

  @doc "`:ok` for nonblank text within `maximum` bytes; `{:error, :reference}` otherwise."
  @spec reference(term(), pos_integer()) :: :ok | {:error, :reference}
  def reference(value, maximum),
    do: if(Reference.valid?(value, maximum), do: :ok, else: {:error, :reference})

  @doc "`reference/2` for a text that is there; `:ok` for one that is not."
  @spec optional_text(term(), pos_integer()) :: :ok | {:error, :reference}
  def optional_text(nil, _maximum), do: :ok
  def optional_text(value, maximum), do: reference(value, maximum)
end
