defmodule Responder.Artifacts.Outputs do
  @moduledoc """
  Verified output images retained for one accepted Work turn.

  Coop exposes metadata on the turn and bytes through a separate owner-only
  endpoint. This module requires both views to agree before durable delivery
  can reference the artifact.
  """

  import Ecto.Query

  alias Responder.Artifacts.{OutputArtifact, OutputArtifactChangeset}
  alias Responder.Repo

  @maximum_artifacts 5
  @maximum_bytes 8 * 1_024 * 1_024
  @media_types ~w(image/png image/jpeg image/webp image/gif)
  @fields ~w(bytes id media_type name sha256)
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @spec delivery_supported?(map()) :: boolean()
  def delivery_supported?(episode) do
    episode.execution_mode == :live and
      episode.destination_transport in ["slack", "control_plane"]
  end

  @spec prepare_metadata(term()) :: {:ok, [map()]} | {:error, term()}
  def prepare_metadata(values) when is_list(values) and length(values) <= @maximum_artifacts do
    with {:ok, prepared} <- prepare_metadata_items(values),
         true <- unique?(prepared, "id"),
         true <- unique?(prepared, "sha256"),
         true <- Enum.sum(Enum.map(prepared, & &1["bytes"])) <= @maximum_bytes do
      {:ok, prepared}
    else
      false -> {:error, {:invalid_work_output_artifacts, :metadata}}
      {:error, _reason} = error -> error
    end
  end

  def prepare_metadata(_values),
    do: {:error, {:invalid_work_output_artifacts, :metadata}}

  @spec refs([map()]) :: [String.t()]
  def refs(metadata), do: Enum.map(metadata, & &1["id"])

  @spec put_many(Ecto.UUID.t(), [map()]) :: {:ok, [OutputArtifact.t()]} | {:error, term()}
  def put_many(turn_id, values) when is_binary(turn_id) and is_list(values) do
    with true <- Ecto.UUID.cast(turn_id) != :error,
         true <- length(values) <= @maximum_artifacts,
         {:ok, prepared} <- prepare_bodies(turn_id, values),
         true <- Enum.sum(Enum.map(prepared, & &1.byte_size)) <= @maximum_bytes do
      Repo.transaction(fn -> Enum.map(prepared, &put_one!/1) end)
      |> transaction_result()
    else
      false -> {:error, {:invalid_work_output_artifacts, :bodies}}
      {:error, _reason} = error -> error
    end
  end

  def put_many(_turn_id, _values),
    do: {:error, {:invalid_work_output_artifacts, :bodies}}

  @spec fetch_many(Ecto.UUID.t(), [String.t()]) ::
          {:ok, [OutputArtifact.t()]} | {:error, term()}
  def fetch_many(turn_id, refs) when is_binary(turn_id) and is_list(refs) do
    unique = Enum.uniq(refs)

    if Ecto.UUID.cast(turn_id) == :error or unique != refs or length(refs) > @maximum_artifacts or
         not Enum.all?(refs, &reference?/1) do
      {:error, :work_output_artifact_not_found}
    else
      artifacts =
        if refs == [] do
          []
        else
          Repo.all(
            from(artifact in OutputArtifact,
              where: artifact.turn_id == ^turn_id and artifact.ref in ^refs
            )
          )
        end

      by_ref = Map.new(artifacts, &{&1.ref, &1})

      if map_size(by_ref) == length(refs),
        do: {:ok, Enum.map(refs, &Map.fetch!(by_ref, &1))},
        else: {:error, :work_output_artifact_not_found}
    end
  end

  def fetch_many(_turn_id, _refs), do: {:error, :work_output_artifact_not_found}

  defp prepare_metadata_items(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, prepared} ->
      case prepare_metadata_item(value) do
        {:ok, item} -> {:cont, {:ok, [item | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_metadata_item(%{} = value) do
    if Map.keys(value) |> Enum.sort() == @fields and reference?(value["id"]) and
         valid_name?(value["name"]) and value["media_type"] in @media_types and
         digest?(value["sha256"]) and is_integer(value["bytes"]) and
         value["bytes"] in 1..@maximum_bytes do
      {:ok, value}
    else
      {:error, {:invalid_work_output_artifacts, :metadata}}
    end
  end

  defp prepare_metadata_item(_value),
    do: {:error, {:invalid_work_output_artifacts, :metadata}}

  defp prepare_bodies(turn_id, values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, prepared} ->
      case prepare_body(turn_id, value) do
        {:ok, item} -> {:cont, {:ok, [item | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_body(turn_id, %{"data" => data} = value) when is_binary(data) do
    metadata = Map.drop(value, ["data"])

    with {:ok, metadata} <- prepare_metadata_item(metadata),
         true <- byte_size(data) == metadata["bytes"],
         true <- digest(data) == metadata["sha256"],
         true <- media_matches?(metadata["media_type"], data) do
      {:ok,
       %{
         byte_size: metadata["bytes"],
         data: data,
         id: Ecto.UUID.generate(),
         media_type: metadata["media_type"],
         name: metadata["name"],
         ref: metadata["id"],
         sha256: metadata["sha256"],
         turn_id: turn_id
       }}
    else
      false -> {:error, {:invalid_work_output_artifacts, :bodies}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_body(_turn_id, _value),
    do: {:error, {:invalid_work_output_artifacts, :bodies}}

  defp put_one!(attributes) do
    changeset = OutputArtifactChangeset.insert(attributes)

    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _artifact_or_ignored_conflict} ->
        reconcile_existing!(attributes, changeset)

      {:error, %Ecto.Changeset{} = failed} ->
        Repo.rollback({:work_output_artifact_conflict, failed})
    end
  end

  defp reconcile_existing!(attributes, changeset) do
    artifact =
      Repo.one(
        from(artifact in OutputArtifact,
          where: artifact.turn_id == ^attributes.turn_id and artifact.ref == ^attributes.ref
        )
      )

    if artifact && identity(artifact) == identity(attributes),
      do: artifact,
      else: Repo.rollback({:work_output_artifact_conflict, changeset})
  end

  defp identity(value),
    do: {value.ref, value.name, value.media_type, value.sha256, value.byte_size, value.data}

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp unique?(values, field),
    do: values |> Enum.map(& &1[field]) |> Enum.uniq() == Enum.map(values, & &1[field])

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_name?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 == 127))
  end

  defp valid_name?(_value), do: false

  defp media_matches?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: true
  defp media_matches?("image/jpeg", <<255, 216, 255, _::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF87a", _::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF89a", _::binary>>), do: true
  defp media_matches?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  defp media_matches?(_media_type, _data), do: false

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
