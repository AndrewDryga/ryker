defmodule Responder.Webhooks.Router do
  @moduledoc """
  Minimal asynchronous HTTP admission for arbitrary JSON webhooks.

  A successful response means the exact event is durably queued. It does not
  wait for or imply a model decision.
  """

  @behaviour Plug

  import Plug.Conn

  alias Responder.Ingress.Inbox
  alias Responder.Webhooks.{Auth, Input, Route}

  @impl Plug
  def init(options) do
    routes = Keyword.fetch!(options, :routes)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)

    unless is_map(routes) and Enum.all?(routes, &valid_route_entry?/1),
      do: raise(ArgumentError, "webhook routes must map names to matching validated routes")

    unless is_function(now, 0),
      do: raise(ArgumentError, "webhook clock must be a zero-arity function")

    %{now: now, routes: routes}
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["v1", "hooks", route_name]} = conn, options) do
    case Map.fetch(options.routes, route_name) do
      {:ok, route} -> admit(conn, route, options.now.())
      :error -> respond(conn, 404, %{"error" => "not_found"})
    end
  end

  def call(conn, _options), do: respond(conn, 404, %{"error" => "not_found"})

  defp admit(conn, route, now) do
    with :ok <- json_content_type(conn),
         {:ok, body, conn} <- read_bounded_body(conn, route.max_body_bytes),
         :ok <- Auth.authorize(conn, route, body, now),
         {:ok, metadata} <- metadata(conn, now),
         {:ok, payload} <- decode(body),
         {:ok, input} <- Input.new(route, payload, metadata),
         {:ok, receipt} <- Inbox.record(input) do
      respond(conn, 202, %{
        "input_ref" => Inbox.ref(receipt.entry),
        "status" => Atom.to_string(receipt.status)
      })
    else
      {:error, :unsupported_media_type} ->
        respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :unauthorized} ->
        respond(conn, 401, %{"error" => "unauthorized"})

      {:error, :event_id} ->
        respond(conn, 400, %{"error" => "missing_event_id"})

      {:error, :metadata} ->
        respond(conn, 400, %{"error" => "invalid_metadata"})

      {:error, :json} ->
        respond(conn, 400, %{"error" => "invalid_json"})

      {:error, {:invalid_webhook_input, _field}} ->
        respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field}} ->
        respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field, _reason}} ->
        respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:input_conflict, _details}} ->
        respond(conn, 409, %{"error" => "event_conflict"})

      {:error, _reason} ->
        respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> if json_media_type?(value), do: :ok, else: {:error, :unsupported_media_type}
      _other -> {:error, :unsupported_media_type}
    end
  end

  defp json_media_type?(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    media_type == "application/json" or String.ends_with?(media_type, "+json")
  end

  defp read_bounded_body(conn, maximum), do: read_bounded_body(conn, maximum, [])

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

  defp metadata(conn, now) do
    with {:ok, event_id} <- required_header(conn, "x-responder-event-id", :event_id),
         {:ok, item_id} <- item_id(conn, event_id),
         {:ok, event_type} <- optional_header(conn, "x-responder-event-type"),
         {:ok, occurred_at, occurred_at_source} <- occurred_at(conn, now),
         {:ok, revision} <- revision(conn) do
      {:ok,
       [
         event_id: event_id,
         event_type: event_type,
         item_id: item_id,
         occurred_at: occurred_at,
         occurred_at_source: occurred_at_source,
         revision: revision
       ]}
    else
      {:error, :event_id} -> {:error, :event_id}
      _error -> {:error, :metadata}
    end
  end

  defp required_header(conn, name, error) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp optional_header(conn, name) do
    case get_req_header(conn, name) do
      [] -> {:ok, nil}
      [value] when value != "" -> {:ok, value}
      _other -> {:error, name}
    end
  end

  defp item_id(conn, event_id) do
    case optional_header(conn, "x-responder-item-id") do
      {:ok, nil} -> {:ok, event_id}
      {:ok, item_id} -> {:ok, item_id}
      {:error, _reason} -> {:error, :item_id}
    end
  end

  defp occurred_at(conn, now) do
    case get_req_header(conn, "x-responder-occurred-at") do
      [] -> {:ok, now, :ingress}
      [value] -> with {:ok, datetime} <- parse_datetime(value), do: {:ok, datetime, :source}
      _other -> {:error, :occurred_at}
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :occurred_at}
    end
  end

  defp revision(conn) do
    case get_req_header(conn, "x-responder-revision") do
      [] -> {:ok, 1}
      [value] -> parse_positive_integer(value)
      _other -> {:error, :revision}
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :revision}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :json}
    end
  end

  defp respond(conn, status, document) do
    body = Jason.encode!(document)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp valid_route_entry?({name, %Route{name: name}}) when is_binary(name), do: true
  defp valid_route_entry?(_entry), do: false
end
