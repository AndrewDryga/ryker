defmodule Ryker.Webhooks.Auth do
  @moduledoc false

  alias Plug.Conn
  alias Ryker.Webhooks.Route

  @spec authorize(Conn.t(), Route.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def authorize(conn, %Route{auth: {:bearer, expected}}, _body, _now) do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> submitted] -> secure_equal(submitted, expected)
      _other -> {:error, :unauthorized}
    end
  end

  def authorize(conn, %Route{auth: {:hmac_sha256, secret}} = route, body, now) do
    with {:ok, timestamp} <- timestamp(conn),
         :ok <- fresh(timestamp, now, route.max_clock_skew_seconds),
         {:ok, submitted} <- signature(conn),
         {:ok, signed} <- signed_message(conn, timestamp.raw, body),
         expected <- :crypto.mac(:hmac, :sha256, secret, signed) do
      secure_equal(submitted, expected)
    else
      _error -> {:error, :unauthorized}
    end
  end

  defp signed_message(conn, timestamp, body) do
    with {:ok, event_id} <- optional_header(conn, "x-responder-event-id"),
         {:ok, item_id} <- optional_header(conn, "x-responder-item-id"),
         {:ok, event_type} <- optional_header(conn, "x-responder-event-type"),
         {:ok, occurred_at} <- optional_header(conn, "x-responder-occurred-at"),
         {:ok, revision} <- optional_header(conn, "x-responder-revision") do
      {:ok,
       [
         timestamp,
         conn.request_path,
         event_id,
         item_id,
         event_type,
         occurred_at,
         revision,
         body
       ]
       |> Enum.join("\n")}
    end
  end

  defp optional_header(conn, name) do
    case Conn.get_req_header(conn, name) do
      [] -> {:ok, ""}
      [value] when value != "" -> {:ok, value}
      _other -> {:error, :header}
    end
  end

  defp timestamp(conn) do
    case Conn.get_req_header(conn, "x-responder-timestamp") do
      [raw] ->
        case Integer.parse(raw) do
          {seconds, ""} -> {:ok, %{raw: raw, seconds: seconds}}
          _other -> {:error, :timestamp}
        end

      _other ->
        {:error, :timestamp}
    end
  end

  defp fresh(timestamp, now, maximum_skew) do
    if abs(DateTime.to_unix(now) - timestamp.seconds) <= maximum_skew,
      do: :ok,
      else: {:error, :stale}
  end

  defp signature(conn) do
    case Conn.get_req_header(conn, "x-responder-signature") do
      ["v1=" <> encoded] -> Base.decode16(encoded, case: :mixed)
      _other -> {:error, :signature}
    end
  end

  defp secure_equal(submitted, expected) when byte_size(submitted) == byte_size(expected) do
    if Plug.Crypto.secure_compare(submitted, expected), do: :ok, else: {:error, :unauthorized}
  end

  defp secure_equal(_submitted, _expected), do: {:error, :unauthorized}
end
