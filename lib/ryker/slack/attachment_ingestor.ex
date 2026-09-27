defmodule Ryker.Slack.AttachmentIngestor do
  @moduledoc """
  Converts authenticated Slack file shares into immutable generic artifacts.

  Raw private URLs exist only during this adapter call. The returned generic
  input contains safe metadata and an opaque artifact ref for the Work runtime.

  A voice message or video is kept too, and its descriptor carries what was
  said (`Ryker.Transcription`): Slack's own transcript when Slack finished
  one, otherwise the configured transcriber's, taken here, before the input is
  recorded, so routing reads a voice message as words. The transcriber's
  result is kept beside the recording, so Slack's redelivery of the same file
  does not transcribe it again.
  """

  alias Ryker.Artifacts
  alias Ryker.Ingress.Input
  alias Ryker.Transcription

  # The kernel activates at most two input events at once and Coop accepts five
  # artifacts per turn. Two per source event keeps every active attachment
  # model-visible without silently truncating a later correction.
  @maximum_files 2
  @maximum_bytes 8 * 1_024 * 1_024

  @spec ingest(%{audience: atom(), input: Input.t()}, map()) ::
          {:ok, %{audience: atom(), input: Input.t()}} | {:error, term()}
  def ingest(%{audience: audience, input: %Input{} = input} = normalized, settings)
      when is_map(settings) do
    with {:ok, options} <- options(settings),
         {:ok, descriptors} <- ingest_files(input, options) do
      content = Map.put(input.content, "files", descriptors)
      {:ok, %{normalized | audience: audience, input: %{input | content: content}}}
    end
  end

  def ingest(_normalized, _settings), do: {:error, {:invalid_slack_attachment_ingestor, :input}}

  defp ingest_files(%Input{content: %{"files" => files}} = input, options) when is_list(files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {file, index}, {:ok, descriptors, total} ->
      case ingest_file(input, file, index, total, options) do
        {:ok, descriptor, next_total} ->
          {:cont, {:ok, [descriptor | descriptors], next_total}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, descriptors, _total} -> {:ok, Enum.reverse(descriptors)}
      {:error, _reason} = error -> error
    end
  end

  defp ingest_files(_input, _options), do: {:error, {:invalid_slack_attachment_ingestor, :files}}

  defp ingest_file(_input, file, index, total, _options) when index >= @maximum_files,
    do: {:ok, unavailable("file_limit_exceeded", file), total}

  defp ingest_file(input, %{} = file, _index, total, options) do
    case stored(input, file, total, options) do
      {:ok, artifact} ->
        {:ok, available(artifact, file, options), total + artifact.byte_size}

      {:unavailable, reason} ->
        {:ok, unavailable(reason, file), total}

      {:error, _reason} = error ->
        error
    end
  end

  defp ingest_file(_input, file, _index, total, _options),
    do: {:ok, unavailable("invalid_metadata", file), total}

  defp stored(input, file, total, options) do
    with {:ok, source_ref} <- source_ref(input, file),
         {:miss, source_ref} <- existing(options.store, source_ref),
         :ok <- supported(file),
         :ok <- transcribable(file),
         :ok <- available_capacity(file, total),
         {:ok, resolved, data} <-
           options.downloader.download(options.client, file, @maximum_bytes - total),
         {:ok, media_type} <- readable(resolved["mimetype"], data),
         {:ok, artifact} <-
           options.store.put(%{
             data: data,
             media_type: media_type,
             name: resolved["name"],
             source_kind: "slack",
             source_ref: source_ref
           }) do
      {:ok, artifact}
    else
      {:ok, artifact} ->
        {:ok, artifact}

      {:error, {:invalid_input_artifact, field}}
      when field in [:data, :media_type, :name] ->
        {:unavailable, reason(field)}

      {:error, {:slack_file_rejected, field}}
      when field in [:metadata, :url, :maximum_bytes] ->
        {:unavailable, reason(field)}

      {:error, :unsupported_media_type} ->
        {:unavailable, "unsupported_media_type"}

      {:error, :attachment_capacity_exceeded} ->
        {:unavailable, "attachment_bytes_exceeded"}

      {:error, {:recording_refused, failure}} ->
        {:unavailable, reason(failure)}

      {:error, _reason} = error ->
        error
    end
  end

  defp existing(store, source_ref) do
    case store.fetch_source("slack", source_ref) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, :input_artifact_not_found} -> {:miss, source_ref}
      {:error, _reason} = error -> error
    end
  end

  defp source_ref(%Input{source: %{ref: workspace_ref}}, %{"id" => file_ref}) do
    if bounded(workspace_ref, 256) and bounded(file_ref, 256),
      do: {:ok, workspace_ref <> ":" <> file_ref},
      else: {:error, {:slack_file_rejected, :metadata}}
  end

  defp source_ref(_input, _file), do: {:error, {:slack_file_rejected, :metadata}}

  # Slack labels a script or a log by its own kind (text/x-sh,
  # application/octet-stream), so a label need not be a supported type for the
  # file to be readable text: a deploy.sh shared in Slack never reached the
  # model. A label that may hide text is downloaded and its bytes decide, as in
  # Chat; one that plainly is not text is refused without the download.
  defp supported(%{"mimetype" => media_type}) when is_binary(media_type) do
    if Artifacts.supported_media_type?(media_type) or text_label?(media_type) or
         Artifacts.recording_media_type(media_type),
       do: :ok,
       else: {:error, :unsupported_media_type}
  end

  defp supported(_file), do: {:error, {:slack_file_rejected, :metadata}}

  # A voice message or video Slack says is too long or too large to transcribe
  # is refused before it is downloaded, and routing hears why.
  defp transcribable(%{"mimetype" => label} = file) do
    cond do
      is_nil(Artifacts.recording_media_type(label)) ->
        :ok

      is_integer(file["duration_ms"]) and
          file["duration_ms"] > Transcription.maximum_seconds() * 1_000 ->
        {:error, {:recording_refused, :too_long}}

      is_integer(file["size"]) and file["size"] > Transcription.maximum_bytes() ->
        {:error, {:recording_refused, :too_large}}

      true ->
        :ok
    end
  end

  defp text_label?("text/" <> _kind), do: true

  defp text_label?(label),
    do: label in ~w(application/octet-stream application/x-sh application/x-shellscript
                  application/javascript application/xml application/toml application/sql)

  # A file that says it is an image or a PDF must be one: the store checks its
  # bytes against that and refuses a mismatch. Only a text-like or unknown
  # label falls back to reading the bytes as text.
  defp readable("image/" <> _kind = declared, _data), do: {:ok, declared}
  defp readable("application/pdf" = declared, _data), do: {:ok, declared}

  defp readable(declared, data) when is_binary(declared) do
    case Artifacts.readable_media_type(declared, data) do
      {:ok, media_type} -> {:ok, media_type}
      :error -> {:error, :unsupported_media_type}
    end
  end

  defp readable(_declared, _data), do: {:error, :unsupported_media_type}

  defp available_capacity(%{"size" => size}, total)
       when is_integer(size) and size > 0 and total <= @maximum_bytes - size,
       do: :ok

  defp available_capacity(%{"size" => size}, _total) when is_integer(size) and size > 0,
    do: {:error, :attachment_capacity_exceeded}

  defp available_capacity(_file, _total), do: {:error, {:slack_file_rejected, :metadata}}

  defp available(artifact, file, options) do
    descriptor = %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }

    if Artifacts.recording?(artifact.media_type),
      do: Map.merge(descriptor, transcript(artifact, file, options)),
      else: descriptor
  end

  # A recording Ryker could not keep still tells routing a voice message was
  # sent, and why it has no words.
  defp unavailable(reason, file) do
    descriptor = %{"reason" => reason, "status" => "unavailable"}

    case file |> label() |> Artifacts.recording_media_type() do
      nil ->
        descriptor

      media_type ->
        Map.merge(descriptor, Transcription.outcome(media_type, {:error, failure(reason)}))
    end
  end

  defp label(%{"mimetype" => label}), do: label
  defp label(_file), do: nil

  defp transcript(artifact, file, options) do
    words =
      case slack_words(file) do
        {:ok, words} -> {:ok, words}
        :none -> transcribed(artifact, options)
      end

    Transcription.outcome(artifact.media_type, words)
  end

  # Slack's finished transcript is the whole of what was said unless Slack
  # says there is more than its preview.
  defp slack_words(%{
         "transcription" => %{
           "status" => "complete",
           "preview" => %{"content" => words} = preview
         }
       })
       when is_binary(words) do
    if preview["has_more"] == true, do: :none, else: {:ok, words}
  end

  defp slack_words(_file), do: :none

  defp transcribed(artifact, options) do
    kept = artifact.source_ref <> ":transcript"

    case options.store.fetch_source("slack", kept) do
      {:ok, %{data: words}} ->
        {:ok, words}

      {:error, :input_artifact_not_found} ->
        result = options.transcriber.transcribe(artifact.data, [])
        _kept = keep(options.store, kept, result)
        result
    end
  end

  defp keep(store, source_ref, {:ok, text}) do
    with {:ok, words} <- Transcription.words(text) do
      store.put(%{
        data: words,
        media_type: "text/plain",
        name: "transcript.txt",
        source_kind: "slack",
        source_ref: source_ref
      })
    end
  end

  defp keep(_store, _source_ref, {:error, _failure}), do: :ok

  defp reason(:data), do: "content_mismatch"
  defp reason(:media_type), do: "unsupported_media_type"
  defp reason(:name), do: "invalid_name"
  defp reason(:metadata), do: "invalid_metadata"
  defp reason(:url), do: "invalid_url"
  defp reason(:maximum_bytes), do: "attachment_bytes_exceeded"
  defp reason(:too_long), do: "recording_too_long"
  defp reason(:too_large), do: "recording_too_large"

  defp failure("recording_too_long"), do: :too_long
  defp failure("recording_too_large"), do: :too_large
  defp failure(_reason), do: :failed

  defp options(
         %{client: _client, downloader: downloader, store: store, transcriber: transcriber} =
           settings
       ) do
    if implements?(downloader, download: 3) and implements?(store, fetch_source: 2, put: 1) and
         implements?(transcriber, transcribe: 2),
       do: {:ok, Map.take(settings, [:client, :downloader, :store, :transcriber])},
       else: {:error, {:invalid_slack_attachment_ingestor, :settings}}
  end

  defp options(_settings), do: {:error, {:invalid_slack_attachment_ingestor, :settings}}

  defp implements?(module, functions) do
    is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp bounded(value, maximum),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum
end
