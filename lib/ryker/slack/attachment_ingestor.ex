defmodule Ryker.Slack.AttachmentIngestor do
  @moduledoc """
  Converts authenticated Slack file shares into immutable generic artifacts.

  Raw private URLs exist only during this adapter call. The returned generic
  input contains safe metadata and an opaque artifact ref for the Work runtime.
  """

  alias Ryker.Artifacts
  alias Ryker.Ingress.Input

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

  defp ingest_file(_input, _file, index, total, _options) when index >= @maximum_files,
    do: {:ok, unavailable("file_limit_exceeded"), total}

  defp ingest_file(input, %{} = file, _index, total, options) do
    with {:ok, source_ref} <- source_ref(input, file),
         {:miss, source_ref} <- existing(options.store, source_ref),
         :ok <- supported(file),
         :ok <- available_capacity(file, total),
         {:ok, resolved, data} <-
           options.downloader.download(options.client, file, @maximum_bytes - total),
         {:ok, artifact} <-
           options.store.put(%{
             data: data,
             media_type: resolved["mimetype"],
             name: resolved["name"],
             source_kind: "slack",
             source_ref: source_ref
           }) do
      {:ok, available(artifact), total + artifact.byte_size}
    else
      {:ok, artifact} ->
        {:ok, available(artifact), total + artifact.byte_size}

      {:error, {:invalid_input_artifact, field}}
      when field in [:data, :media_type, :name] ->
        {:ok, unavailable(reason(field)), total}

      {:error, {:slack_file_rejected, field}}
      when field in [:metadata, :url, :maximum_bytes] ->
        {:ok, unavailable(reason(field)), total}

      {:error, :unsupported_media_type} ->
        {:ok, unavailable("unsupported_media_type"), total}

      {:error, :attachment_capacity_exceeded} ->
        {:ok, unavailable("attachment_bytes_exceeded"), total}

      {:error, _reason} = error ->
        error
    end
  end

  defp ingest_file(_input, _file, _index, total, _options),
    do: {:ok, unavailable("invalid_metadata"), total}

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

  defp supported(%{"mimetype" => media_type}) do
    if Artifacts.supported_media_type?(media_type),
      do: :ok,
      else: {:error, :unsupported_media_type}
  end

  defp supported(_file), do: {:error, {:slack_file_rejected, :metadata}}

  defp available_capacity(%{"size" => size}, total)
       when is_integer(size) and size > 0 and total <= @maximum_bytes - size,
       do: :ok

  defp available_capacity(%{"size" => size}, _total) when is_integer(size) and size > 0,
    do: {:error, :attachment_capacity_exceeded}

  defp available_capacity(_file, _total), do: {:error, {:slack_file_rejected, :metadata}}

  defp available(artifact) do
    %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }
  end

  defp unavailable(reason), do: %{"reason" => reason, "status" => "unavailable"}

  defp reason(:data), do: "content_mismatch"
  defp reason(:media_type), do: "unsupported_media_type"
  defp reason(:name), do: "invalid_name"
  defp reason(:metadata), do: "invalid_metadata"
  defp reason(:url), do: "invalid_url"
  defp reason(:maximum_bytes), do: "attachment_bytes_exceeded"

  defp options(%{client: client, downloader: downloader, store: store})
       when is_atom(downloader) and is_atom(store) do
    if Code.ensure_loaded?(downloader) and Code.ensure_loaded?(store) and
         function_exported?(downloader, :download, 3) and
         function_exported?(store, :fetch_source, 2) and function_exported?(store, :put, 1),
       do: {:ok, %{client: client, downloader: downloader, store: store}},
       else: {:error, {:invalid_slack_attachment_ingestor, :settings}}
  end

  defp options(_settings), do: {:error, {:invalid_slack_attachment_ingestor, :settings}}

  defp bounded(value, maximum),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum
end
