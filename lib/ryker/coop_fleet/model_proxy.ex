defmodule Ryker.CoopFleet.ModelProxy do
  @moduledoc false
  import Plug.Conn
  alias Ryker.CoopFleet.{ModelContracts, ModelGrants, ModelPermits, ModelRequest}
  alias Ryker.Delivery
  alias Ryker.Secret

  @maximum_body 32 * 1_024 * 1_024
  @maximum_response 256 * 1_024 * 1_024
  @refused "model_proxy_refused"

  def call(conn, certificate, job, provider, host, path, options) do
    with [token] <- get_req_header(conn, "x-coop-model-grant"),
         {:ok, binding} <- ModelGrants.authorize(certificate, job, provider, token),
         {:ok, route} <-
           ModelContracts.route(
             provider,
             binding.account["selection"],
             conn.method,
             host,
             path,
             conn.query_string
           ),
         {:ok, body, conn} <- read_body(conn, length: @maximum_body, read_length: 64 * 1_024),
         :ok <- validate_request(conn, binding, provider, path, body) do
      headers = ModelContracts.headers(route, binding.account, conn.req_headers)

      dispatch(
        conn,
        %{
          job: job,
          provider: provider,
          host: host,
          path: path,
          binding: binding,
          headers: headers,
          body: body,
          token: token
        },
        options
      )
    else
      _refused -> send_resp(conn, 403, @refused)
    end
  end

  defp dispatch(
         conn,
         %{
           job: job,
           host: host,
           path: path,
           headers: headers,
           body: body,
           token: token,
           binding: binding
         } = context,
         options
       ) do
    if websocket?(conn) do
      forward_socket(conn, context, options)
    else
      authorize = fn -> ModelGrants.reauthorize(binding, job, token) end

      permit =
        if ModelRequest.inference?(conn.method, path),
          do: ModelPermits.reserve(binding, authorize),
          else: {:ok, nil}

      case permit do
        {:ok, lease} ->
          try do
            request =
              Delivery.HTTPClient.build(
                method(conn.method),
                "https://" <> host <> path <> query(conn.query_string),
                headers,
                body
              )

            stream(conn, request, authorize, options, lease, binding)
          after
            ModelPermits.cancel(lease)
          end

        {:error, {:model_limited, reason, until}} ->
          limited(conn, reason, until)

        {:error, :model_grant_refused} ->
          refused(conn)

        _unavailable ->
          send_resp(conn, 503, "model_capacity_unavailable")
      end
    end
  end

  defp forward_socket(
         conn,
         %{
           job: job,
           provider: provider,
           host: host,
           path: path,
           binding: binding,
           headers: headers,
           token: token
         },
         options
       ) do
    connector =
      Keyword.get(options, :model_socket, &Ryker.CoopFleet.ModelSocketUpstream.connect/1)

    case connector.(%{
           host: host,
           path: path <> query(conn.query_string),
           headers: Secret.new(headers)
         }) do
      {:ok, upstream} ->
        WebSockAdapter.upgrade(
          conn,
          Ryker.CoopFleet.ModelSocket,
          %{
            upstream: upstream,
            authorize: fn -> ModelGrants.reauthorize(binding, job, token) end,
            job: binding.job,
            provider: provider,
            account: binding.run.account,
            binding: binding
          },
          timeout: 300_000,
          max_frame_size: @maximum_body
        )

      {:error, {:provider_response, status, headers, body}} when status in 400..599 ->
        if status == 429, do: ModelPermits.observe_limit(binding, headers)

        send_provider_refusal(conn, status, headers, body)

      _unavailable ->
        send_resp(conn, 502, "model_upstream_unavailable")
    end
  end

  # Preserve the native provider error bytes and retry hints. A refusal can
  # contain an HTML error page, so always serve these bytes as plain text.
  # sobelow_skip ["XSS.SendResp"]
  defp send_provider_refusal(conn, status, headers, body) do
    headers
    |> safe_headers()
    |> Enum.reduce(conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
  end

  defp validate_request(conn, binding, provider, path, body) do
    if websocket?(conn) and conn.method == "GET",
      do: :ok,
      else: ModelRequest.validate(binding.job, provider, binding.run.account, path, body)
  end

  defp websocket?(conn), do: get_req_header(conn, "upgrade") == ["websocket"]

  defp stream(conn, request, authorize, options, lease, binding) do
    # Bandit's HTTP/1 connection traps exits between requests. While streaming,
    # a failed authorization watchdog must also stop a blocked socket write.
    trapped = Process.flag(:trap_exit, false)

    try do
      stream_response(conn, request, authorize, options, lease, binding)
    after
      Process.flag(:trap_exit, trapped)
    end
  end

  defp stream_response(conn, request, authorize, options, lease, binding) do
    owner = self()
    ref = make_ref()
    client = Keyword.get(options, :model_stream, &Delivery.HTTPClient.stream_events/5)

    task =
      Task.async(fn ->
        try do
          {:ok, timeout} = ModelPermits.activate(lease, self())

          result =
            client.(request, Ryker.CoopFinch, timeout, :streaming, fn event, state ->
              send(owner, {ref, :event, event})

              receive do
                {^ref, :continue} -> {:cont, state}
                {^ref, :stop} -> {:halt, :cancelled}
              after
                30_000 -> {:halt, :backpressure_timeout}
              end
            end)

          send(owner, {ref, :done, result})
        rescue
          _error -> send(owner, {ref, :done, {:error, :model_upstream_unavailable}})
        end
      end)

    {:ok, watcher} = Task.start_link(fn -> watch_authority(owner, ref, authorize) end)

    try do
      receive_stream(
        conn,
        task,
        ref,
        authorize,
        nil,
        [],
        0,
        &ModelPermits.observe_limit(binding, &1)
      )
    after
      send(watcher, {ref, :stop})
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp receive_stream(conn, task, ref, authorize, status, headers, bytes, observe) do
    receive do
      {^ref, :event, {:status, code}} ->
        if code in 300..399 and code != 304 do
          send(task.pid, {ref, :stop})
          send_resp(conn, 502, "model_upstream_redirect_refused")
        else
          send(task.pid, {ref, :continue})
          receive_stream(conn, task, ref, authorize, code, headers, bytes, observe)
        end

      {^ref, :event, {:headers, received}} ->
        headers = safe_headers(received)
        if status == 429, do: observe.(headers)

        send(task.pid, {ref, :continue})
        receive_stream(conn, task, ref, authorize, status, headers, bytes, observe)

      {^ref, :event, {:data, data}} when is_binary(data) ->
        forward_data(conn, task, ref, authorize, {status, headers, bytes}, data, observe)

      {^ref, :event, {:trailers, _trailers}} ->
        send(task.pid, {ref, :continue})
        receive_stream(conn, task, ref, authorize, status, headers, bytes, observe)

      {^ref, :done, {:ok, :streaming}} ->
        start_response(conn, status || 502, headers)

      {^ref, :done, _error} ->
        if conn.state == :chunked,
          do: exit(:shutdown),
          else: send_resp(conn, 502, "model_upstream_unavailable")
    after
      1_000 ->
        case authorize.() do
          {:ok, _current} ->
            receive_stream(conn, task, ref, authorize, status, headers, bytes, observe)

          _revoked ->
            refused(conn)
        end
    end
  end

  defp forward_data(conn, task, ref, authorize, {status, headers, bytes}, data, observe) do
    case {authorize.(), bytes + byte_size(data) <= @maximum_response} do
      {{:ok, _current}, true} ->
        conn = start_response(conn, status, headers)

        case chunk(conn, data) do
          {:ok, conn} ->
            send(task.pid, {ref, :continue})

            receive_stream(
              conn,
              task,
              ref,
              authorize,
              status,
              headers,
              bytes + byte_size(data),
              observe
            )

          {:error, _closed} ->
            conn
        end

      _revoked ->
        refused(conn)
    end
  end

  defp watch_authority(owner, ref, authorize) do
    monitor = Process.monitor(owner)
    watch_authority(owner, ref, monitor, authorize)
  end

  defp watch_authority(owner, ref, monitor, authorize) do
    receive do
      {^ref, :stop} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok
    after
      1_000 ->
        case authorize.() do
          {:ok, _current} -> watch_authority(owner, ref, monitor, authorize)
          _revoked -> Process.exit(owner, :shutdown)
        end
    end
  end

  defp limited(conn, reason, until) do
    retry = if until, do: max(1, DateTime.diff(until, Ryker.Repo.now!(), :second)), else: 1
    status = if reason == :unresolved_requests, do: 503, else: 429

    body =
      Jason.encode!(%{
        error: %{
          type: "rate_limit_error",
          code: "coop_model_#{reason}",
          message: "This model account cannot accept another inference request yet."
        }
      })

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry))
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp safe_headers(headers) do
    Enum.reject(headers, fn {key, _} ->
      String.downcase(key) in ~w(set-cookie connection transfer-encoding content-length upgrade sec-websocket-accept)
    end)
  end

  defp start_response(%{state: :chunked} = conn, _status, _headers), do: conn

  defp start_response(conn, status, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
    |> put_resp_header("cache-control", "no-store")
    |> send_chunked(status || 502)
  end

  defp refused(%{state: :chunked}), do: exit(:shutdown)
  defp refused(conn), do: send_resp(conn, 403, @refused)
  defp query(""), do: ""
  defp query(value), do: "?" <> value
  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method("DELETE"), do: :delete
end
