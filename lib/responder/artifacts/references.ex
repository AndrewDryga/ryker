defmodule Responder.Artifacts.References do
  @moduledoc """
  Relational custody for immutable input artifacts.

  An adapter may download bytes before the normalized input is recorded. The
  inbox transaction locks every referenced artifact and inserts its ownership
  rows before acknowledging the source. A frozen Work submission takes its own
  references in the same way, so retention never infers live ownership by
  searching serialized JSON.
  """

  import Ecto.Query

  alias Responder.Artifacts.{Artifact, IngressReference, WorkReference}
  alias Responder.Ingress.Input
  alias Responder.Repo

  @spec attach_input(Input.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def attach_input(%Input{} = input, input_id) when is_binary(input_id) do
    with :ok <- transaction_open(),
         {:ok, descriptors} <- descriptors(input.content),
         {:ok, artifacts} <- lock_artifacts(Map.keys(descriptors)),
         :ok <- validate_input_artifacts(artifacts, descriptors, input.source.kind) do
      now = DateTime.utc_now()

      rows =
        Enum.map(artifacts, fn artifact ->
          %{
            artifact_id: artifact.id,
            input_id: input_id,
            inserted_at: now,
            updated_at: now
          }
        end)

      _ =
        Repo.insert_all(IngressReference, rows,
          on_conflict: :nothing,
          conflict_target: [:input_id, :artifact_id]
        )

      :ok
    end
  end

  def attach_input(_input, _input_id),
    do: {:error, {:invalid_input_artifact_reference, :input}}

  @spec attach_turn(Ecto.UUID.t(), [String.t()]) :: :ok | {:error, term()}
  def attach_turn(turn_id, refs) when is_binary(turn_id) and is_list(refs) do
    with :ok <- transaction_open(),
         true <- Enum.uniq(refs) == refs,
         {:ok, artifacts} <- lock_artifacts(refs) do
      now = DateTime.utc_now()

      rows =
        Enum.map(artifacts, fn artifact ->
          %{
            artifact_id: artifact.id,
            turn_id: turn_id,
            inserted_at: now,
            updated_at: now
          }
        end)

      _ =
        Repo.insert_all(WorkReference, rows,
          on_conflict: :nothing,
          conflict_target: [:turn_id, :artifact_id]
        )

      :ok
    else
      false -> {:error, {:invalid_input_artifact_reference, :refs}}
      {:error, _reason} = error -> error
    end
  end

  def attach_turn(_turn_id, _refs),
    do: {:error, {:invalid_input_artifact_reference, :refs}}

  defp lock_artifacts([]), do: {:ok, []}

  defp lock_artifacts(refs) do
    if Enum.all?(refs, &artifact_ref?/1) do
      artifacts =
        Repo.all(
          from(artifact in Artifact,
            where: artifact.ref in ^refs,
            order_by: artifact.ref,
            lock: "FOR KEY SHARE"
          )
        )

      if length(artifacts) == length(refs),
        do: {:ok, artifacts},
        else: {:error, :input_artifact_not_found}
    else
      {:error, {:invalid_input_artifact_reference, :ref}}
    end
  end

  defp descriptors(content) do
    case collect(content, %{}) do
      {:ok, descriptors} -> {:ok, descriptors}
      {:error, _reason} = error -> error
    end
  end

  defp collect(%{"artifact_ref" => ref, "status" => "available"} = value, accumulated) do
    descriptor =
      Map.take(value, ["artifact_ref", "bytes", "media_type", "name", "sha256", "status"])

    if map_size(descriptor) == 6 and artifact_ref?(ref) do
      case Map.get(accumulated, ref) do
        nil -> {:ok, Map.put(accumulated, ref, descriptor)}
        ^descriptor -> {:ok, accumulated}
        _different -> {:error, {:invalid_input_artifact_reference, :descriptor_conflict}}
      end
    else
      {:error, {:invalid_input_artifact_reference, :descriptor}}
    end
  end

  defp collect(%{} = value, accumulated) do
    Enum.reduce_while(value, {:ok, accumulated}, fn {_key, child}, {:ok, current} ->
      case collect(child, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp collect(value, accumulated) when is_list(value) do
    Enum.reduce_while(value, {:ok, accumulated}, fn child, {:ok, current} ->
      case collect(child, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp collect(_value, accumulated), do: {:ok, accumulated}

  defp validate_input_artifacts(artifacts, descriptors, source_kind) do
    if Enum.all?(artifacts, &valid_input_artifact?(&1, descriptors, source_kind)),
      do: :ok,
      else: {:error, {:invalid_input_artifact_reference, :identity}}
  end

  defp valid_input_artifact?(artifact, descriptors, source_kind) do
    descriptor = Map.fetch!(descriptors, artifact.ref)

    artifact.source_kind == source_kind and
      descriptor == %{
        "artifact_ref" => artifact.ref,
        "bytes" => artifact.byte_size,
        "media_type" => artifact.media_type,
        "name" => artifact.name,
        "sha256" => artifact.sha256,
        "status" => "available"
      }
  end

  defp artifact_ref?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        String.starts_with?(value, "artifact:input:")

  defp transaction_open do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, {:invalid_input_artifact_reference, :transaction}}
  end
end
