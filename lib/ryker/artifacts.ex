defmodule Ryker.Artifacts do
  @moduledoc """
  Immutable input artifacts shared by platform adapters and the Work runtime.

  Platform credentials and private download URLs never enter this store. An
  adapter authenticates and downloads the source, this module validates the
  exact bytes against Coop's public input-artifact contract, and Work later
  loads them by opaque artifact reference.
  """

  import Bitwise
  import Ecto.Query
  alias Ryker.Artifacts.{Artifact, ArtifactChangeset}
  alias Ryker.CanonicalJSON
  alias Ryker.Repo

  @maximum_bytes 8 * 1_024 * 1_024
  # What Coop's input-artifact contract carries to a model.
  @model_media_types ~w(
    image/png image/jpeg image/webp image/gif
    text/plain text/markdown text/csv application/json
    application/yaml application/x-yaml application/pdf
  )
  # Voice messages and videos are kept for the record and reach models as
  # their transcript (`Ryker.Transcription`): Coop takes no audio or video.
  @recording_media_types ~w(
    audio/aac audio/flac audio/mp4 audio/mpeg audio/ogg audio/wav audio/webm
    video/mp4 video/quicktime video/webm
  )
  @media_types @model_media_types ++ @recording_media_types
  # How Slack and browsers label the recordings Ryker keeps.
  @recording_labels %{
    "audio/aac" => "audio/aac",
    "audio/x-aac" => "audio/aac",
    "audio/flac" => "audio/flac",
    "audio/x-flac" => "audio/flac",
    "audio/mp4" => "audio/mp4",
    "audio/m4a" => "audio/mp4",
    "audio/x-m4a" => "audio/mp4",
    "audio/mpeg" => "audio/mpeg",
    "audio/mp3" => "audio/mpeg",
    "audio/ogg" => "audio/ogg",
    "audio/opus" => "audio/ogg",
    "audio/wav" => "audio/wav",
    "audio/wave" => "audio/wav",
    "audio/x-wav" => "audio/wav",
    "audio/vnd.wave" => "audio/wav",
    "audio/webm" => "audio/webm",
    "video/mp4" => "video/mp4",
    "video/quicktime" => "video/quicktime",
    "video/webm" => "video/webm"
  }
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

  @doc "Whether a model can receive an artifact of this type as a file."
  @spec model_media_type?(term()) :: boolean()
  def model_media_type?(media_type), do: media_type in @model_media_types

  @doc "Whether this type is a voice message or a video, which reaches models as its transcript."
  @spec recording?(term()) :: boolean()
  def recording?(media_type), do: media_type in @recording_media_types

  @doc "The media type Ryker keeps a recording under, from its sender's label."
  @spec recording_media_type(term()) :: String.t() | nil
  def recording_media_type(label) when is_binary(label),
    do: Map.get(@recording_labels, String.downcase(label))

  def recording_media_type(_label), do: nil

  @doc """
  The media type to store for an uploaded file its sender labelled `declared`:
  the label when the bytes are that kind, a recording's own type when its
  label names one and the bytes are that container, otherwise text/plain for
  any UTF-8 text, because a browser labels a .log file or a script
  application/octet-stream. Anything else, and an empty file, is unreadable.
  """
  @spec readable_media_type(String.t(), binary()) :: {:ok, String.t()} | :error
  def readable_media_type(declared, data)
      when is_binary(declared) and is_binary(data) and data != "" do
    recording = recording_media_type(declared)

    cond do
      supported_media_type?(declared) and media_matches?(declared, data) -> {:ok, declared}
      recording && media_matches?(recording, data) -> {:ok, recording}
      media_matches?("text/plain", data) -> {:ok, "text/plain"}
      true -> :error
    end
  end

  def readable_media_type(_declared, _data), do: :error

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
      valid_name?(artifact.name) and model_media_type?(artifact.media_type) and
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

  # A recording is checked by its container, which ffmpeg then decodes.
  defp media_matches?(media_type, <<_size::binary-size(4), "ftyp", _rest::binary>>)
       when media_type in ~w(audio/mp4 video/mp4 video/quicktime),
       do: true

  defp media_matches?(
         "video/quicktime",
         <<_size::binary-size(4), atom::binary-size(4), _::binary>>
       )
       when atom in ~w(moov mdat wide free skip),
       do: true

  defp media_matches?(media_type, <<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>)
       when media_type in ~w(audio/webm video/webm),
       do: true

  defp media_matches?("audio/ogg", <<"OggS", _rest::binary>>), do: true
  defp media_matches?("audio/flac", <<"fLaC", _rest::binary>>), do: true
  defp media_matches?("audio/wav", <<"RIFF", _size::binary-size(4), "WAVE", _::binary>>), do: true
  defp media_matches?("audio/mpeg", <<"ID3", _rest::binary>>), do: true

  # An MPEG audio frame: eleven sync bits and a layer other than reserved.
  defp media_matches?("audio/mpeg", <<0xFF, flags, _rest::binary>>)
       when band(flags, 0xE0) == 0xE0 and band(flags, 0x06) != 0,
       do: true

  # An ADTS frame: twelve sync bits and layer zero.
  defp media_matches?("audio/aac", <<0xFF, flags, _rest::binary>>)
       when band(flags, 0xF6) == 0xF0,
       do: true

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
