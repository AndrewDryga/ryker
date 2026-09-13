defmodule Ryker.Slack.UploadClient do
  @moduledoc """
  Bounded raw transport for Slack's external file upload URLs.

  Upload URLs are provider-issued capabilities. This client deliberately sends
  no bot token and accepts only Slack's exact HTTPS file host, preventing a
  malformed API response from turning the token-bearing adapter into an SSRF
  primitive.
  """

  @fields [:base_origin, :finch, :receive_timeout]
  @maximum_body_bytes 8 * 1_024 * 1_024
  @maximum_response_bytes 64 * 1_024
  @media_types ~w(image/gif image/jpeg image/png image/webp)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          base_origin: String.t(),
          finch: atom(),
          receive_timeout: pos_integer()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize(attributes),
         client <- struct!(__MODULE__, attributes),
         :ok <- validate(client) do
      {:ok, %{client | base_origin: String.trim_trailing(client.base_origin, "/")}}
    end
  end

  @spec upload(t(), String.t(), binary(), String.t()) :: :ok | {:error, term()}
  def upload(%__MODULE__{} = client, url, data, media_type) do
    with :ok <- upload_url(client, url),
         :ok <- data(data),
         :ok <- media_type(media_type) do
      request =
        Finch.build(
          :post,
          url,
          [
            {"content-length", Integer.to_string(byte_size(data))},
            {"content-type", media_type}
          ],
          data
        )

      stream(request, client)
    end
  end

  def upload(_client, _url, _data, _media_type),
    do: {:error, {:invalid_slack_upload, :client}}

  defp stream(request, client) do
    initial = %{body: [], bytes: 0, error: nil, status: nil}

    result =
      Finch.stream_while(
        request,
        client.finch,
        initial,
        &stream_entry/2,
        receive_timeout: client.receive_timeout
      )

    case result do
      {:ok, %{error: nil, status: status} = response} when status in 200..299 ->
        _body = response.body |> Enum.reverse() |> IO.iodata_to_binary()
        :ok

      {:ok, %{error: :response_too_large}} ->
        {:error, {:delivery_protocol_error, :response_too_large}}

      {:ok, %{error: nil, status: status} = response} when is_integer(status) ->
        body = response.body |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:slack_http_error, status, body}}

      {:error, _reason, %{error: :response_too_large}} ->
        {:error, {:delivery_protocol_error, :response_too_large}}

      {:error, reason, _response} ->
        {:error, {:delivery_transport_unavailable, reason}}

      _invalid ->
        {:error, {:delivery_protocol_error, :response}}
    end
  end

  defp stream_entry({:status, status}, response) when is_integer(status),
    do: {:cont, %{response | status: status}}

  defp stream_entry({:headers, _headers}, response), do: {:cont, response}

  defp stream_entry({:data, chunk}, response) when is_binary(chunk) do
    bytes = response.bytes + byte_size(chunk)

    if bytes <= @maximum_response_bytes,
      do: {:cont, %{response | body: [chunk | response.body], bytes: bytes}},
      else: {:halt, %{response | error: :response_too_large}}
  end

  defp stream_entry({:trailers, _trailers}, response), do: {:cont, response}
  defp stream_entry(_entry, response), do: {:halt, %{response | error: :response}}

  defp normalize(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> normalize(),
       else: {:error, {:invalid_slack_upload_client, :fields}}
  end

  defp normalize(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_slack_upload_client, :fields}}
  end

  defp normalize(_attributes), do: {:error, {:invalid_slack_upload_client, :fields}}

  defp validate(client) do
    cond do
      not base_origin?(client.base_origin) ->
        {:error, {:invalid_slack_upload_client, :base_origin}}

      not is_atom(client.finch) ->
        {:error, {:invalid_slack_upload_client, :finch}}

      not is_integer(client.receive_timeout) or client.receive_timeout < 100 or
          client.receive_timeout > 60_000 ->
        {:error, {:invalid_slack_upload_client, :receive_timeout}}

      true ->
        :ok
    end
  end

  defp upload_url(client, value) when is_binary(value) and byte_size(value) <= 4_096 do
    requested = URI.parse(value)
    expected = URI.parse(client.base_origin)

    if valid_upload_uri?(requested) and origin(requested) == origin(expected),
      do: :ok,
      else: {:error, {:invalid_slack_upload, :url}}
  end

  defp upload_url(_client, _value), do: {:error, {:invalid_slack_upload, :url}}

  defp base_origin?(value) when is_binary(value) do
    case URI.parse(String.trim_trailing(value, "/")) do
      %URI{fragment: nil, path: path, query: nil, userinfo: nil} = uri
      when path in [nil, ""] ->
        allowed_origin?(uri)

      _invalid ->
        false
    end
  end

  defp base_origin?(_value), do: false

  defp allowed_origin?(%URI{host: "files.slack.com", scheme: "https"}), do: true

  defp allowed_origin?(%URI{host: host, scheme: "http"}),
    do: host in ["127.0.0.1", "localhost", "::1"]

  defp allowed_origin?(_uri), do: false

  defp valid_upload_uri?(%URI{fragment: nil, path: path, userinfo: nil} = uri)
       when is_binary(path) and path != "",
       do: allowed_origin?(uri)

  defp valid_upload_uri?(_uri), do: false

  defp origin(%URI{} = uri), do: {uri.scheme, uri.host, uri.port}

  defp data(value) do
    if is_binary(value) and byte_size(value) in 1..@maximum_body_bytes,
      do: :ok,
      else: {:error, {:invalid_slack_upload, :data}}
  end

  defp media_type(value) do
    if value in @media_types,
      do: :ok,
      else: {:error, {:invalid_slack_upload, :media_type}}
  end
end
