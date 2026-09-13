defmodule Ryker.Webhooks.Auth do
  @moduledoc false

  alias Plug.Conn
  alias Ryker.Webhooks.{Headers, Route}

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

  # The signature covers the timestamp, the path, the five event headers in
  # order and the raw body, newline-joined.
  defp signed_message(conn, timestamp, body) do
    with {:ok, headers} <- Headers.signed_values(conn) do
      {:ok, Enum.join([timestamp, conn.request_path] ++ headers ++ [body], "\n")}
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
