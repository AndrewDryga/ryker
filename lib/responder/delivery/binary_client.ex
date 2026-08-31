defmodule Responder.Delivery.BinaryClient do
  @moduledoc """
  Bounded authenticated binary downloader for trusted platform adapters.

  Callers validate the destination host before using this transport. The body
  is streamed with a hard byte limit so an authenticated attachment cannot
  exhaust the gateway while being downloaded.
  """

  @fields [:finch, :receive_timeout, :token_provider]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          finch: atom(),
          receive_timeout: pos_integer(),
          token_provider: (-> {:ok, String.t()} | {:error, term()})
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize(attributes),
         client <- struct!(__MODULE__, attributes),
         :ok <- validate(client) do
      {:ok, client}
    end
  end

  @spec get(t(), String.t(), pos_integer()) ::
          {:ok, %{body: binary(), headers: list(), status: pos_integer()}} | {:error, term()}
  def get(%__MODULE__{} = client, url, maximum_bytes) do
    with :ok <- url(url),
         :ok <- maximum(maximum_bytes),
         {:ok, token} <- token(client.token_provider) do
      request = Finch.build(:get, url, [{"authorization", "Bearer " <> token}])
      stream(request, client, maximum_bytes)
    end
  end

  def get(_client, _url, _maximum_bytes),
    do: {:error, {:invalid_delivery_binary_request, :client}}

  defp stream(request, client, maximum_bytes) do
    initial = %{body: [], body_bytes: 0, error: nil, headers: [], status: nil}

    result =
      Finch.stream_while(
        request,
        client.finch,
        initial,
        &stream_entry(&1, &2, maximum_bytes),
        receive_timeout: client.receive_timeout
      )

    case result do
      {:ok, %{error: :response_too_large}} ->
        {:error, {:delivery_protocol_error, :response_too_large}}

      {:ok, %{error: :invalid_response}} ->
        {:error, {:delivery_protocol_error, :response}}

      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, %{response | body: response.body |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:error, _reason, %{error: :response_too_large}} ->
        {:error, {:delivery_protocol_error, :response_too_large}}

      {:error, reason, _response} ->
        {:error, {:delivery_transport_unavailable, reason}}

      _invalid ->
        {:error, {:delivery_protocol_error, :response}}
    end
  end

  defp stream_entry({:status, status}, response, _maximum) when is_integer(status),
    do: {:cont, %{response | status: status}}

  defp stream_entry({:headers, headers}, response, _maximum) when is_list(headers),
    do: {:cont, %{response | headers: response.headers ++ headers}}

  defp stream_entry({:data, chunk}, response, maximum) when is_binary(chunk) do
    body_bytes = response.body_bytes + byte_size(chunk)

    if body_bytes <= maximum,
      do: {:cont, %{response | body: [chunk | response.body], body_bytes: body_bytes}},
      else: {:halt, %{response | error: :response_too_large}}
  end

  defp stream_entry({:trailers, _trailers}, response, _maximum), do: {:cont, response}

  defp stream_entry(_entry, response, _maximum),
    do: {:halt, %{response | error: :invalid_response}}

  defp normalize(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> normalize(),
       else: {:error, {:invalid_delivery_binary_client, :fields}}
  end

  defp normalize(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_delivery_binary_client, :fields}}
  end

  defp normalize(_attributes), do: {:error, {:invalid_delivery_binary_client, :fields}}

  defp validate(client) do
    cond do
      not is_atom(client.finch) ->
        {:error, {:invalid_delivery_binary_client, :finch}}

      not is_integer(client.receive_timeout) or client.receive_timeout < 100 ->
        {:error, {:invalid_delivery_binary_client, :receive_timeout}}

      not is_function(client.token_provider, 0) ->
        {:error, {:invalid_delivery_binary_client, :token_provider}}

      true ->
        :ok
    end
  end

  defp token(provider) do
    case provider.() do
      {:ok, value} ->
        if valid_token?(value),
          do: {:ok, value},
          else: {:error, {:delivery_credentials_unavailable, :invalid_token}}

      {:error, reason} ->
        {:error, {:delivery_credentials_unavailable, reason}}

      _invalid ->
        {:error, {:delivery_credentials_unavailable, :invalid_token}}
    end
  rescue
    error -> {:error, {:delivery_credentials_unavailable, error}}
  end

  defp valid_token?(value) do
    is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp url(value) do
    if is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value),
      do: :ok,
      else: {:error, {:invalid_delivery_binary_request, :url}}
  end

  defp maximum(value) when is_integer(value) and value > 0 and value <= 8 * 1_024 * 1_024,
    do: :ok

  defp maximum(_value), do: {:error, {:invalid_delivery_binary_request, :maximum_bytes}}
end
