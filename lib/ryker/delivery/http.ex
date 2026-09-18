defmodule Ryker.Delivery.HTTP do
  @moduledoc """
  The two steps the JSON and binary delivery transports share: asking the
  host for a bearer token, and streaming one response under a hard byte limit.

  The token provider belongs to host configuration and runs for each request,
  so short-lived installation credentials are never persisted in an ingress
  row or delivery intent. A provider that fails, answers nonsense or raises is
  a retryable credential error. The body is collected chunk by chunk and the
  stream stops at the first chunk past the limit, so an endpoint cannot
  exhaust the node while its response is being read.
  """

  @maximum_token_bytes 4_096

  @type response :: %{
          body: binary(),
          headers: [{String.t(), String.t()}],
          status: pos_integer()
        }

  @spec bearer_token((-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, {:delivery_credentials_unavailable, term()}}
  def bearer_token(provider) do
    case provider.() do
      {:ok, value} -> valid_token(value)
      {:error, reason} -> {:error, {:delivery_credentials_unavailable, reason}}
      _invalid -> {:error, {:delivery_credentials_unavailable, :invalid_token}}
    end
  rescue
    error -> {:error, {:delivery_credentials_unavailable, error}}
  end

  @spec stream(Finch.Request.t(), atom(), pos_integer(), pos_integer()) ::
          {:ok, response()} | {:error, term()}
  def stream(request, finch, receive_timeout, maximum_bytes) do
    initial = %{body: [], body_bytes: 0, error: nil, headers: [], status: nil}

    request
    |> Finch.stream_while(finch, initial, &stream_entry(&1, &2, maximum_bytes),
      receive_timeout: receive_timeout
    )
    |> stream_result()
  end

  defp stream_result({:ok, %{error: :response_too_large}}),
    do: {:error, {:delivery_protocol_error, :response_too_large}}

  defp stream_result({:ok, %{error: nil, status: status} = response}) when is_integer(status) do
    body = response.body |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, %{body: body, headers: response.headers, status: status}}
  end

  defp stream_result({:ok, _invalid}), do: {:error, {:delivery_protocol_error, :response}}

  defp stream_result({:error, _reason, %{error: :response_too_large}}),
    do: {:error, {:delivery_protocol_error, :response_too_large}}

  defp stream_result({:error, reason, _response}),
    do: {:error, {:delivery_transport_unavailable, reason}}

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

  defp valid_token(value) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= @maximum_token_bytes,
       do: {:ok, value},
       else: {:error, {:delivery_credentials_unavailable, :invalid_token}}
  end
end
