defmodule Responder.Cutover.Manifest do
  @moduledoc """
  Writes one sealed legacy-state inventory without starting the product runtime.

  The destination is created exclusively with owner-only permissions. Existing
  files are never replaced: review decisions and later apply/rollback steps
  must remain bound to the exact manifest bytes an operator inspected.
  """

  alias Responder.{CanonicalJSON, Cutover.LegacySnapshot}

  @maximum_path_bytes 4_096

  @spec create(Path.t(), Path.t(), keyword()) ::
          {:ok, %{bytes: pos_integer(), path: Path.t(), sha256: String.t()}}
          | {:error, term()}
  def create(source, destination, options) do
    with :ok <- destination(destination),
         {:ok, envelope} <- LegacySnapshot.inventory(source, options),
         encoded <- CanonicalJSON.encode!(envelope) <> "\n",
         :ok <- write_exclusive(destination, encoded) do
      {:ok,
       %{
         bytes: byte_size(encoded),
         path: destination,
         sha256: sha256(encoded)
       }}
    end
  rescue
    error -> {:error, {:cutover_manifest_write_failed, Exception.message(error)}}
  end

  defp destination(value) when is_binary(value) and byte_size(value) in 1..@maximum_path_bytes do
    parent = Path.dirname(value)

    cond do
      Path.type(value) != :absolute ->
        {:error, {:invalid_cutover_manifest, :path}}

      value == "/" ->
        {:error, {:invalid_cutover_manifest, :path}}

      not File.dir?(parent) ->
        {:error, {:invalid_cutover_manifest, :parent}}

      File.exists?(value) or File.exists?(value <> "/") ->
        {:error, {:cutover_manifest_exists, value}}

      true ->
        :ok
    end
  end

  defp destination(_value), do: {:error, {:invalid_cutover_manifest, :path}}

  defp write_exclusive(path, encoded) do
    case File.open(path, [:write, :exclusive, :binary], &persist(&1, path, encoded)) do
      {:ok, :ok} -> :ok
      {:error, :eexist} -> {:error, {:cutover_manifest_exists, path}}
      {:ok, {:error, reason}} -> {:error, {:cutover_manifest_write_failed, reason}}
      {:error, reason} -> {:error, {:cutover_manifest_write_failed, reason}}
    end
  end

  defp persist(device, path, encoded) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(device, encoded) do
      :file.sync(device)
    end
  end

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
