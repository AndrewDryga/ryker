defmodule Ryker.Delivery.HTTPClient do
  @moduledoc """
  Ryker's one way out to HTTP: nothing else in `lib/` calls Finch. Delivery's
  JSON and binary transports, embeddings, transcription, local routing,
  Cloudflare Access's keys and the live acceptance check all build, send and
  read their requests here, so there is one seam to stub and bound.

  It asks the host for a bearer token, and streams one response under a hard
  byte limit.

  The token provider belongs to host configuration and runs for each request,
  so short-lived installation credentials are never persisted in an ingress
  row or delivery intent. A provider that fails, answers nonsense or raises is
  a retryable credential error. The body is collected chunk by chunk and the
  stream stops at the first chunk past the limit, so an endpoint cannot
  exhaust the node while its response is being read.
  """

  require Logger

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
    # The message can carry the vault the provider failed against, and this
    # reason is stored with the delivery, so it names the class and only the
    # log keeps the message.
    error ->
      Logger.warning(
        "delivery credentials unavailable: " <> Exception.format_banner(:error, error)
      )

      {:error, {:delivery_credentials_unavailable, {:raised, error.__struct__}}}
  end

  @pool Ryker.CoopFinch

  @doc "A request for `stream/4`."
  @spec build(atom(), String.t(), [{String.t(), String.t()}], iodata() | nil) ::
          Finch.Request.t()
  def build(method, url, headers \\ [], body \\ nil), do: Finch.build(method, url, headers, body)

  @doc """
  Runs `function` with the HTTP pool started, for a process that runs outside
  the application, such as the live acceptance check started from a release
  command. The application's own pool serves when it is running.
  """
  @spec with_pool((-> result)) :: result | {:error, {:http_pool_unavailable, term()}}
        when result: term()
  def with_pool(function) do
    case Finch.start_link(name: @pool) do
      {:ok, pid} ->
        try do
          function.()
        after
          GenServer.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        function.()

      {:error, reason} ->
        {:error, {:http_pool_unavailable, reason}}
    end
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
