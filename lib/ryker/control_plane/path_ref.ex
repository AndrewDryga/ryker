defmodule Ryker.ControlPlane.PathRef do
  @moduledoc """
  One path segment read as a durable reference.

  A segment is percent-decoded exactly once and must come out non-empty, valid
  UTF-8 and no longer than any reference the stores accept, so a routed
  identifier is what the browser put in the URL and a hostile path cannot
  reach a projection with something the projection would never have produced.
  """
  alias Ryker.ControlPlane.Paths

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

  @doc """
  The reference a record of `kind` is kept under, from the id segment its
  address carries (`Ryker.ControlPlane.Paths.id/2`, read back). A request's
  kinds are addressed by the request's id, which `request_key` resolves.
  """
  @spec reference(String.t(), term(), (String.t() -> {:ok, String.t()} | :not_found) | nil) ::
          {:ok, String.t()} | {:error, :path_ref} | :not_found
  def reference(kind, segment, request_key \\ nil) do
    with {:ok, id} <- decode(segment) do
      case Paths.reference(kind, id) do
        {:ok, reference} -> {:ok, reference}
        :request when is_function(request_key, 1) -> request_key.(id)
        :request -> :not_found
        :error -> :not_found
      end
    end
  end

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
