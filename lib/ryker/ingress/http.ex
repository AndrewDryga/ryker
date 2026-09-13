defmodule Ryker.Ingress.HTTP do
  @moduledoc false

  import Plug.Conn

  @spec json_content_type(Plug.Conn.t()) :: :ok | {:error, :unsupported_media_type}
  def json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> if json_media_type?(value), do: :ok, else: {:error, :unsupported_media_type}
      _other -> {:error, :unsupported_media_type}
    end
  end

  @spec read_bounded_body(Plug.Conn.t(), non_neg_integer()) ::
          {:ok, binary(), Plug.Conn.t()} | {:error, :body | :too_large}
  def read_bounded_body(conn, maximum), do: read_bounded_body(conn, maximum, [])

  @spec required_header(Plug.Conn.t(), String.t(), atom()) ::
          {:ok, String.t()} | {:error, atom()}
  def required_header(conn, name, error) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  @spec decode_json(binary(), :any | :object) :: {:ok, term()} | {:error, :json}
  def decode_json(body, shape \\ :any) do
    case Jason.decode(body) do
      {:ok, payload} when shape == :any -> {:ok, payload}
      {:ok, payload} when shape == :object and is_map(payload) -> {:ok, payload}
      _other -> {:error, :json}
    end
  end

  @spec respond(Plug.Conn.t(), Plug.Conn.status(), map()) :: Plug.Conn.t()
  def respond(conn, status, document) do
    body = Jason.encode!(document)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp json_media_type?(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    media_type == "application/json" or String.ends_with?(media_type, "+json")
  end

  defp read_bounded_body(conn, remaining, chunks) when remaining >= 0 do
    case Plug.Conn.read_body(conn, length: remaining + 1, read_length: remaining + 1) do
      {:ok, chunk, conn} ->
        if byte_size(chunk) <= remaining,
          do: {:ok, chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary(), conn},
          else: {:error, :too_large}

      {:more, chunk, conn} ->
        if byte_size(chunk) <= remaining,
          do: read_bounded_body(conn, remaining - byte_size(chunk), [chunk | chunks]),
          else: {:error, :too_large}

      {:error, _reason} ->
        {:error, :body}
    end
  end
end
