defmodule Ryker.Delivery.JSONClient do
  @moduledoc """
  Bounded authenticated JSON transport for trusted platform adapters.

  The bearer token comes from the host's provider on every request; see
  `Ryker.Delivery.HTTP`.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.HTTP

  @fields [:base_url, :finch, :receive_timeout, :token_provider]
  @maximum_body_bytes 2 * 1_024 * 1_024
  @maximum_request_bytes 512 * 1_024

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          base_url: String.t(),
          finch: atom(),
          receive_timeout: pos_integer(),
          token_provider: (-> {:ok, String.t()} | {:error, term()})
        }

  @type response :: %{body: term(), headers: [{String.t(), String.t()}], status: pos_integer()}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         client = struct!(__MODULE__, attributes),
         :ok <- validate(client) do
      {:ok, %{client | base_url: String.trim_trailing(client.base_url, "/")}}
    end
  end

  @spec request(t(), :get | :patch | :post, String.t(), term() | nil, [
          {String.t(), String.t()}
        ]) ::
          {:ok, response()} | {:error, term()}
  def request(%__MODULE__{} = client, method, path, document, headers) do
    with :ok <- method(method),
         :ok <- path(path),
         :ok <- headers(headers),
         {:ok, token} <- HTTP.bearer_token(client.token_provider),
         {:ok, body, headers} <- request_body(document, headers),
         request =
           Finch.build(
             method,
             client.base_url <> path,
             [{"authorization", "Bearer " <> token} | headers],
             body
           ),
         {:ok, response} <-
           HTTP.stream(request, client.finch, client.receive_timeout, @maximum_body_bytes) do
      decode_response(response)
    end
  end

  def request(_client, _method, _path, _document, _headers),
    do: {:error, {:invalid_delivery_json_request, :client}}

  defp request_body(nil, headers), do: {:ok, nil, headers}

  defp request_body(document, headers) do
    case CanonicalJSON.validate(document, max_bytes: @maximum_request_bytes) do
      :ok ->
        {:ok, CanonicalJSON.encode!(document), [{"content-type", "application/json"} | headers]}

      {:error, _reason} ->
        {:error, {:invalid_delivery_json_request, :document}}
    end
  end

  # An error status may carry a non-JSON body, which is returned as text for
  # the caller to report; a success that is not JSON is a protocol error.
  defp decode_response(%{body: ""} = response), do: {:ok, %{response | body: nil}}

  defp decode_response(%{body: body, status: status} = response) do
    case Jason.decode(body) do
      {:ok, document} -> {:ok, %{response | body: document}}
      {:error, _reason} when status >= 400 -> {:ok, response}
      {:error, _reason} -> {:error, {:delivery_protocol_error, :invalid_json}}
    end
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_delivery_json_client, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_delivery_json_client, :fields}}
  end

  defp normalize_attributes(_attributes),
    do: {:error, {:invalid_delivery_json_client, :fields}}

  defp validate(client) do
    validations = [
      {base_url?(client.base_url), :base_url},
      {is_atom(client.finch), :finch},
      {is_integer(client.receive_timeout) and client.receive_timeout >= 100 and
         client.receive_timeout <= 60_000, :receive_timeout},
      {is_function(client.token_provider, 0), :token_provider}
    ]

    Enum.reduce_while(validations, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_delivery_json_client, field}}}
    end)
  end

  defp base_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        scheme == "https" or (scheme == "http" and loopback?(host))

      _invalid ->
        false
    end
  end

  defp base_url?(_value), do: false

  defp loopback?(host), do: host in ["127.0.0.1", "localhost", "::1"]

  defp method(method) when method in [:get, :patch, :post], do: :ok
  defp method(_method), do: {:error, {:invalid_delivery_json_request, :method}}

  defp path(value) do
    if text?(value, 4_096) and String.starts_with?(value, "/") and
         not String.starts_with?(value, "//"),
       do: :ok,
       else: {:error, {:invalid_delivery_json_request, :path}}
  end

  defp headers(headers) when is_list(headers) do
    if Enum.all?(headers, &header?/1),
      do: :ok,
      else: {:error, {:invalid_delivery_json_request, :headers}}
  end

  defp headers(_headers), do: {:error, {:invalid_delivery_json_request, :headers}}

  defp header?({name, value}) do
    text?(name, 256) and text?(value, 4_096) and
      String.downcase(name) not in ["authorization", "content-type"]
  end

  defp header?(_header), do: false

  defp text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end
end
