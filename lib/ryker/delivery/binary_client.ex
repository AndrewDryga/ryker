defmodule Ryker.Delivery.BinaryClient do
  @moduledoc """
  Bounded authenticated binary downloader for trusted platform adapters.

  Callers validate the destination host before using this transport. The body
  is streamed under the caller's byte limit so an authenticated attachment
  cannot exhaust the gateway while being downloaded; see `Ryker.Delivery.HTTP`.
  """

  alias Ryker.Delivery.HTTP

  @fields [:finch, :receive_timeout, :token_provider]
  @maximum_download_bytes 8 * 1_024 * 1_024

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
         client = struct!(__MODULE__, attributes),
         :ok <- validate(client) do
      {:ok, client}
    end
  end

  @spec get(t(), String.t(), pos_integer()) :: {:ok, HTTP.response()} | {:error, term()}
  def get(%__MODULE__{} = client, url, maximum_bytes) do
    with :ok <- url(url),
         :ok <- maximum(maximum_bytes),
         {:ok, token} <- HTTP.bearer_token(client.token_provider) do
      :get
      |> Finch.build(url, [{"authorization", "Bearer " <> token}])
      |> HTTP.stream(client.finch, client.receive_timeout, maximum_bytes)
    end
  end

  def get(_client, _url, _maximum_bytes),
    do: {:error, {:invalid_delivery_binary_request, :client}}

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

  defp url(value) do
    if is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value),
      do: :ok,
      else: {:error, {:invalid_delivery_binary_request, :url}}
  end

  defp maximum(value) when is_integer(value) and value in 1..@maximum_download_bytes, do: :ok

  defp maximum(_value), do: {:error, {:invalid_delivery_binary_request, :maximum_bytes}}
end
