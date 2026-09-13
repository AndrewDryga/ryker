defmodule Ryker.ControlPlane.PathRef do
  @moduledoc """
  One path segment read as a durable reference.

  A segment is percent-decoded exactly once and must come out non-empty, valid
  UTF-8 and no longer than any reference the stores accept, so a routed
  identifier is what the browser put in the URL and a hostile path cannot
  reach a projection with something the projection would never have produced.
  """

  @maximum_encoded_bytes 3_072
  @maximum_bytes 1_024

  @spec decode(term()) :: {:ok, String.t()} | {:error, :path_ref}
  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= @maximum_encoded_bytes do
    decoded = URI.decode(encoded)

    if String.valid?(decoded) and decoded != "" and byte_size(decoded) <= @maximum_bytes,
      do: {:ok, decoded},
      else: {:error, :path_ref}
  end

  def decode(_encoded), do: {:error, :path_ref}

  @doc "A segment that must be a UUID, returned in its canonical form."
  @spec uuid(term()) :: {:ok, String.t()} | {:error, :path_ref}
  def uuid(encoded) do
    with {:ok, decoded} <- decode(encoded),
         {:ok, normalized} <- Ecto.UUID.cast(decoded) do
      {:ok, normalized}
    else
      _invalid -> {:error, :path_ref}
    end
  end
end
