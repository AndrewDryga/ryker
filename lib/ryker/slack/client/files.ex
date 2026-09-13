defmodule Ryker.Slack.Client.Files do
  @moduledoc """
  Image attachments on a Slack message: the bounded set the client accepts,
  the two-step external upload Slack requires, and the file-share message a
  retry recognises by its filenames.
  """

  alias Ryker.Slack.Client
  alias Ryker.Slack.Client.{Fields, Transport}

  @maximum_files 5
  @maximum_file_bytes 8 * 1_024 * 1_024
  @media_types ~w(image/gif image/jpeg image/png image/webp)

  @spec filenames(term()) :: :ok | {:error, {:invalid_slack_api_request, :files}}
  def filenames(values) when is_list(values) and length(values) in 1..@maximum_files do
    if Enum.uniq(values) == values and Enum.all?(values, &Fields.filename?/1),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :files}}
  end

  def filenames(_values), do: {:error, {:invalid_slack_api_request, :files}}

  @spec uploads(term()) :: :ok | {:error, {:invalid_slack_api_request, :files}}
  def uploads(values) when is_list(values) and length(values) in 1..@maximum_files do
    total = Enum.reduce(values, 0, fn file, acc -> acc + upload_bytes(file) end)

    if total <= @maximum_file_bytes and Enum.all?(values, &upload?/1) and
         Enum.uniq(Enum.map(values, & &1.filename)) == Enum.map(values, & &1.filename) do
      :ok
    else
      {:error, {:invalid_slack_api_request, :files}}
    end
  end

  def uploads(_values), do: {:error, {:invalid_slack_api_request, :files}}

  defp upload?(
         %{
           alt_text: alt_text,
           data: data,
           filename: filename,
           media_type: media_type,
           title: title
         } = file
       )
       when map_size(file) == 5 do
    Fields.filename?(filename) and Fields.bounded_string?(title, 200) and
      Fields.bounded_string?(alt_text, 1_000) and
      media_type in @media_types and is_binary(data) and byte_size(data) in 1..@maximum_file_bytes
  end

  defp upload?(_file), do: false

  defp upload_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp upload_bytes(_file), do: @maximum_file_bytes + 1

  @doc "Uploads each file's bytes to the URL Slack hands out for it, in order."
  @spec upload_external(Client.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def upload_external(client, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, uploaded} ->
      case upload_external_file(client, file) do
        {:ok, result} -> {:cont, {:ok, uploaded ++ [result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upload_external_file(client, file) do
    request_document = %{
      "alt_txt" => file.alt_text,
      "filename" => file.filename,
      "length" => byte_size(file.data)
    }

    with {:ok, response} <-
           Transport.request(client, :post, "/files.getUploadURLExternal", request_document),
         {:ok, body} <- Transport.response(response),
         {:ok, upload_url, file_id} <- upload_target(body),
         :ok <- client.uploader.upload(client.upload_http, upload_url, file.data, file.media_type) do
      {:ok, %{"id" => file_id, "title" => file.title}}
    end
  end

  defp upload_target(%{"file_id" => file_id, "upload_url" => upload_url}) do
    with :ok <- Fields.text(file_id),
         :ok <- Fields.text(upload_url) do
      {:ok, upload_url, file_id}
    else
      {:error, _reason} -> {:error, {:slack_protocol_error, :upload_target}}
    end
  end

  defp upload_target(_body), do: {:error, {:slack_protocol_error, :upload_target}}

  @doc "The files.completeUploadExternal document that shares the uploads as one message."
  @spec completion_document(String.t(), map(), [map()]) :: map()
  def completion_document(channel, rendered, files) do
    %{
      "blocks" => Jason.encode!(rendered["blocks"]),
      "channel_id" => channel,
      "files" => files,
      "initial_comment" => rendered["text"]
    }
  end

  @doc "The message on a history page that shares every one of the expected filenames."
  @spec find_delivery([map()], [String.t()]) :: {:ok, String.t()} | :not_found | {:error, term()}
  def find_delivery(messages, filenames) do
    expected = MapSet.new(filenames)

    Enum.reduce_while(messages, :not_found, fn
      %{"files" => files, "ts" => message_ref}, :not_found
      when is_list(files) and is_binary(message_ref) and message_ref != "" ->
        file_delivery_result(file_names(files), expected, message_ref)

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :message}}}
    end)
  end

  defp file_delivery_result({:ok, names}, expected, message_ref) do
    if MapSet.subset?(expected, MapSet.new(names)),
      do: {:halt, {:ok, message_ref}},
      else: {:cont, :not_found}
  end

  defp file_delivery_result({:error, _reason} = error, _expected, _message_ref),
    do: {:halt, error}

  defp file_names(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"name" => name}, {:ok, names} when is_binary(name) and name != "" ->
        {:cont, {:ok, [name | names]}}

      %{}, {:ok, names} ->
        {:cont, {:ok, names}}

      _invalid, {:ok, _names} ->
        {:halt, {:error, {:slack_protocol_error, :file}}}
    end)
  end
end
