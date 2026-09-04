defmodule Responder.Webhooks.Router do
  @moduledoc """
  Minimal asynchronous HTTP admission for arbitrary JSON webhooks.

  A successful response means the exact event is durably queued. It does not
  wait for or imply a model decision.
  """

  @behaviour Plug

  import Plug.Conn

  alias Responder.Ingress.{Adapters, HTTP, Inbox}
  alias Responder.Webhooks.{Auth, Route, Transforms}

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
      :error -> HTTP.respond(conn, 404, %{"error" => "not_found"})
    end
  end

  def call(conn, _options), do: HTTP.respond(conn, 404, %{"error" => "not_found"})

  defp admit(conn, route, now) do
    with :ok <- HTTP.json_content_type(conn),
         {:ok, body, conn} <- HTTP.read_bounded_body(conn, route.max_body_bytes),
         :ok <- Auth.authorize(conn, route, body, now),
         {:ok, metadata} <- metadata(conn, now),
         {:ok, payload} <- HTTP.decode_json(body),
         {:ok, transformed} <- normalize(route, payload, metadata),
         {:ok, receipts} <-
           Inbox.record_many(transformed.inputs,
             revision_ties: transformed.revision_ties,
             work_profile: route.work_profile
           ) do
      receipt = hd(receipts)

      HTTP.respond(conn, 202, %{
        "input_ref" => Inbox.ref(receipt.entry),
        "input_refs" => Enum.map(receipts, &Inbox.ref(&1.entry)),
        "count" => length(receipts),
        "status" => batch_status(receipts)
      })
    else
      {:error, :unsupported_media_type} ->
        HTTP.respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        HTTP.respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :unauthorized} ->
        HTTP.respond(conn, 401, %{"error" => "unauthorized"})

      {:error, :event_id} ->
        HTTP.respond(conn, 400, %{"error" => "missing_event_id"})

      {:error, :metadata} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_metadata"})

      {:error, :json} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_json"})

      {:error, {:invalid_webhook_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_webhook_transform, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field, _reason}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:input_conflict, _details}} ->
        HTTP.respond(conn, 409, %{"error" => "event_conflict"})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp normalize(%Route{adapter: %{kind: :universal}} = route, payload, metadata) do
    with event_id when is_binary(event_id) and event_id != "" <- metadata[:event_id],
         {:ok, input} <-
           Adapters.normalize("webhook", %{metadata: metadata, payload: payload}, route) do
      {:ok, %{inputs: [input], revision_ties: :exact}}
    else
      nil -> {:error, :event_id}
      "" -> {:error, :event_id}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(route, payload, metadata), do: Transforms.normalize(route, payload, metadata)

  defp batch_status(receipts) do
    if Enum.all?(receipts, &(&1.status == :duplicate)), do: "duplicate", else: "recorded"
  end

  defp metadata(conn, now) do
    with {:ok, event_id} <- optional_header(conn, "x-responder-event-id"),
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
      _error -> {:error, :metadata}
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

  defp valid_route_entry?({name, %Route{name: name}}) when is_binary(name), do: true
  defp valid_route_entry?(_entry), do: false
end
