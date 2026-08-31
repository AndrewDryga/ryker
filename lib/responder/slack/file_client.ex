defmodule Responder.Slack.FileClient do
  @moduledoc """
  Resolves and downloads authenticated Slack file shares without persisting a
  private Slack URL or bot credential.
  """

  @fields [:binary_http, :binary_requester, :json_http, :json_requester]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          binary_http: term(),
          binary_requester: module(),
          json_http: term(),
          json_requester: module()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize(attributes),
         client <- struct!(__MODULE__, attributes),
         true <- requester?(client.json_requester, :request, 5),
         true <- requester?(client.binary_requester, :get, 3) do
      {:ok, client}
    else
      false -> {:error, {:invalid_slack_file_client, :requester}}
      {:error, _reason} = error -> error
    end
  end

  @spec download(t(), map(), pos_integer()) :: {:ok, map(), binary()} | {:error, term()}
  def download(%__MODULE__{} = client, %{} = file, maximum_bytes) do
    with :ok <- maximum(maximum_bytes),
         {:ok, resolved} <- resolve(client, file),
         :ok <- metadata(resolved, maximum_bytes),
         {:ok, url} <- private_url(resolved),
         {:ok, response} <- client.binary_requester.get(client.binary_http, url, maximum_bytes),
         {:ok, body} <- binary_response(response, maximum_bytes) do
      {:ok, resolved, body}
    end
  end

  def download(_client, _file, _maximum_bytes),
    do: {:error, {:slack_file_rejected, :metadata}}

  defp resolve(_client, %{"url_private_download" => url} = file) when is_binary(url),
    do: {:ok, file}

  defp resolve(_client, %{"url_private" => url} = file) when is_binary(url),
    do: {:ok, file}

  defp resolve(client, %{"id" => id}) do
    with :ok <- slack_ref(id),
         path <- "/files.info?" <> URI.encode_query(file: id),
         {:ok, response} <- client.json_requester.request(client.json_http, :get, path, nil, []) do
      file_response(response)
    end
  end

  defp resolve(_client, _file), do: {:error, {:slack_file_rejected, :metadata}}

  defp file_response(%{body: %{"file" => file, "ok" => true}, status: 200}) when is_map(file),
    do: {:ok, file}

  defp file_response(%{body: %{"error" => error, "ok" => false}, status: 200}),
    do: {:error, {:slack_file_unavailable, error}}

  defp file_response(%{body: body, status: status}) when is_integer(status),
    do: {:error, {:slack_file_unavailable, {status, body}}}

  defp file_response(_response), do: {:error, {:slack_file_unavailable, :response}}

  defp binary_response(%{body: body, status: 200}, maximum) when is_binary(body) do
    if byte_size(body) > 0 and byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:error, {:slack_file_unavailable, :response}}
  end

  defp binary_response(%{body: body, status: status}, _maximum) when is_integer(status),
    do: {:error, {:slack_file_unavailable, {status, body}}}

  defp binary_response(_response, _maximum),
    do: {:error, {:slack_file_unavailable, :response}}

  defp metadata(file, maximum) do
    with :ok <- slack_ref(file["id"]),
         :ok <- text(file["name"], 255),
         :ok <- text(file["mimetype"], 128),
         true <- is_integer(file["size"]) and file["size"] in 1..maximum do
      :ok
    else
      _invalid -> {:error, {:slack_file_rejected, :metadata}}
    end
  end

  defp private_url(file) do
    url = file["url_private_download"] || file["url_private"]

    case URI.parse(url || "") do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and is_binary(path) and path != "" ->
        if slack_file_host?(String.downcase(host)),
          do: {:ok, url},
          else: {:error, {:slack_file_rejected, :url}}

      _invalid ->
        {:error, {:slack_file_rejected, :url}}
    end
  end

  defp slack_file_host?("files.slack.com"), do: true
  defp slack_file_host?(host), do: String.ends_with?(host, ".files.slack.com")

  defp normalize(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> normalize(),
       else: {:error, {:invalid_slack_file_client, :fields}}
  end

  defp normalize(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_slack_file_client, :fields}}
  end

  defp normalize(_attributes), do: {:error, {:invalid_slack_file_client, :fields}}

  defp requester?(module, function, arity),
    do: is_atom(module) and function_exported?(module, function, arity)

  defp slack_ref(value) do
    if is_binary(value) and byte_size(value) in 1..256 and
         Regex.match?(~r/\A[A-Z0-9]+\z/, value),
       do: :ok,
       else: {:error, {:slack_file_rejected, :metadata}}
  end

  defp text(value, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:slack_file_rejected, :metadata}}
  end

  defp maximum(value) when is_integer(value) and value > 0 and value <= 8 * 1_024 * 1_024,
    do: :ok

  defp maximum(_value), do: {:error, {:slack_file_rejected, :maximum_bytes}}
end
