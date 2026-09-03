defmodule Responder.Artifacts do
  @moduledoc """
  Immutable input artifacts shared by platform adapters and the Work runtime.

  Platform credentials and private download URLs never enter this store. An
  adapter authenticates and downloads the source, this module validates the
  exact bytes against Coop's public input-artifact contract, and Work later
  loads them by opaque artifact reference.
  """

  import Ecto.Query

  alias Responder.Artifacts.{Artifact, ArtifactChangeset}
  alias Responder.CanonicalJSON
  alias Responder.Repo

  @maximum_bytes 8 * 1_024 * 1_024
  @media_types ~w(
    image/png image/jpeg image/webp image/gif
    text/plain text/markdown text/csv application/json
    application/yaml application/x-yaml application/pdf
  )
  @text_media_types ~w(text/plain text/markdown text/csv application/json application/yaml application/x-yaml)

  @spec put(map()) :: {:ok, Artifact.t()} | {:error, term()}
  def put(%{} = attributes) do
    with {:ok, prepared} <- prepare(attributes) do
      changeset = ArtifactChangeset.insert(prepared)
      options = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

      case Repo.insert(changeset, options) do
        {:ok, artifact} ->
          {:ok, artifact}

        {:error, %Ecto.Changeset{} = changeset} ->
          reconcile_source(prepared, changeset)
      end
    end
  end

  def put(_attributes), do: {:error, {:invalid_input_artifact, :fields}}

  @spec fetch_source(String.t(), String.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def fetch_source(source_kind, source_ref) do
    case Repo.one(
           from(artifact in Artifact,
             where: artifact.source_kind == ^source_kind and artifact.source_ref == ^source_ref
           )
         ) do
      %Artifact{} = artifact -> {:ok, artifact}
      nil -> {:error, :input_artifact_not_found}
    end
  end

  @spec fetch_many([String.t()]) :: {:ok, [Artifact.t()]} | {:error, term()}
  def fetch_many(refs) when is_list(refs) do
    unique = Enum.uniq(refs)

    if length(unique) != length(refs) or not Enum.all?(unique, &valid_ref?/1) do
      {:error, :input_artifact_not_found}
    else
      artifacts =
        if unique == [] do
          []
        else
          Repo.all(from(artifact in Artifact, where: artifact.ref in ^unique))
        end

      by_ref = Map.new(artifacts, &{&1.ref, &1})

      if map_size(by_ref) == length(unique),
        do: {:ok, Enum.map(unique, &Map.fetch!(by_ref, &1))},
        else: {:error, :input_artifact_not_found}
    end
  end

  def fetch_many(_refs), do: {:error, :input_artifact_not_found}

  @spec coop_inputs([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def coop_inputs(refs) do
    with true <- is_list(refs) and length(refs) <= 5,
         {:ok, artifacts} <- fetch_many(refs),
         true <- Enum.sum(Enum.map(artifacts, & &1.byte_size)) <= @maximum_bytes,
         true <- Enum.all?(artifacts, &stored_artifact_valid?/1) do
      {:ok,
       Enum.map(artifacts, fn artifact ->
         %{
           "data" => artifact.data,
           "media_type" => artifact.media_type,
           "name" => artifact.name,
           "sha256" => artifact.sha256
         }
       end)}
    else
      false -> {:error, :input_artifact_bound_exceeded}
      {:error, _reason} = error -> error
    end
  end

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec supported_media_type?(term()) :: boolean()
  def supported_media_type?(media_type), do: media_type in @media_types

  defp prepare(attributes) do
    expected = [:data, :media_type, :name, :source_kind, :source_ref]

    if Map.keys(attributes) |> Enum.sort() == expected do
      with :ok <- source_kind(attributes.source_kind),
           :ok <- text(attributes.source_ref, 1_024, :source_ref),
           :ok <- name(attributes.name),
           :ok <- media_type(attributes.media_type),
           :ok <- data(attributes.data, attributes.media_type) do
        sha256 = digest(attributes.data)

        {:ok,
         %{
           byte_size: byte_size(attributes.data),
           data: attributes.data,
           id: Ecto.UUID.generate(),
           media_type: attributes.media_type,
           name: attributes.name,
           ref: artifact_ref(attributes.source_kind, attributes.source_ref, sha256),
           sha256: sha256,
           source_kind: attributes.source_kind,
           source_ref: attributes.source_ref
         }}
      end
    else
      {:error, {:invalid_input_artifact, :fields}}
    end
  end

  defp reconcile_source(prepared, changeset) do
    case fetch_source(prepared.source_kind, prepared.source_ref) do
      {:ok, artifact} ->
        if immutable_identity(artifact) == immutable_identity(prepared),
          do: {:ok, artifact},
          else: {:error, :input_artifact_source_conflict}

      {:error, :input_artifact_not_found} ->
        {:error, changeset}
    end
  end

  defp immutable_identity(value),
    do: {value.name, value.media_type, value.sha256, value.byte_size}

  defp stored_artifact_valid?(artifact) do
    byte_size(artifact.data) == artifact.byte_size and digest(artifact.data) == artifact.sha256 and
      valid_name?(artifact.name) and supported_media_type?(artifact.media_type) and
      media_matches?(artifact.media_type, artifact.data)
  end

  defp artifact_ref(source_kind, source_ref, sha256) do
    source_digest = CanonicalJSON.digest(%{"kind" => source_kind, "ref" => source_ref})
    "artifact:input:" <> binary_part(source_digest, 0, 16) <> ":" <> sha256
  end

  defp source_kind(value) do
    if is_binary(value) and byte_size(value) in 1..64 and
         Regex.match?(~r/\A[a-z0-9_.-]+\z/, value),
       do: :ok,
       else: {:error, {:invalid_input_artifact, :source_kind}}
  end

  defp name(value) do
    if valid_name?(value),
      do: :ok,
      else: {:error, {:invalid_input_artifact, :name}}
  end

  defp valid_name?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &control_character?/1)
  end

  defp valid_name?(_value), do: false

  defp control_character?(character), do: character < 32 or character == 127

  defp media_type(value) do
    if supported_media_type?(value),
      do: :ok,
      else: {:error, {:invalid_input_artifact, :media_type}}
  end

  defp data(value, media_type) do
    if is_binary(value) and byte_size(value) in 1..@maximum_bytes and
         media_matches?(media_type, value),
       do: :ok,
       else: {:error, {:invalid_input_artifact, :data}}
  end

  defp media_matches?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>), do: true
  defp media_matches?("image/jpeg", <<255, 216, 255, _rest::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF87a", _rest::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF89a", _rest::binary>>), do: true

  defp media_matches?("image/webp", <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: true

  defp media_matches?("application/pdf", <<"%PDF-", _rest::binary>>), do: true

  defp media_matches?(media_type, data) when media_type in @text_media_types,
    do: String.valid?(data) and :binary.match(data, <<0>>) == :nomatch

  defp media_matches?(_media_type, _data), do: false

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_input_artifact, field}}
  end

  defp valid_ref?(value), do: is_binary(value) and byte_size(value) in 1..128
  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
