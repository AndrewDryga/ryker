defmodule Ryker.ControlPlane.Paths do
  @moduledoc """
  The console's paths to the records its pages link to, built in one place.

  A page path is a `~p` path (`Phoenix.VerifiedRoutes`), checked against the
  route map when this module compiles: the forward that serves everything
  else warns on a verified path (`Ryker.ControlPlane.WebRouter`), so a link
  to a page that does not exist fails the build instead of answering 404
  later.

  A record is addressed by its plain id or slug, never by the reference
  Ryker keeps for it. The route already names the kind of record, so the
  kind's prefix in the reference would only repeat it, percent-encoded: a
  request is `/timeline/<id>`, not `/timeline/ingress-input%3A<id>`, an
  incident room `/incident-rooms/<slug>`, not
  `/incident-rooms/incident-room%3A<slug>`. A request is addressed by its
  id; a request a message started has the message's id, so a message not
  yet routed and the request it starts share one address. Query values keep
  `:` and `@` as written (`query/2`), which a URL allows there.

  Andrew, 2026-10-03, of `/incident-rooms/incident-room%3Ademo-checkout-readiness`:
  "fuckin ugly, make the code more clean and idiomatic". The console had built
  its links in forty places, five different ways.
  """
  use Phoenix.VerifiedRoutes, router: Ryker.ControlPlane.WebRouter, endpoint: __MODULE__.Root

  defmodule Root do
    @moduledoc false
    # The console is served at "/" with no prefix, so a verified path is its
    # own address. `~p` asks its endpoint for that prefix; this answers
    # without the endpoint running, as pages render in tests and in the
    # weekly report.
    def path(path), do: path
  end

  # -- Pages ------------------------------------------------------------------

  @doc """
  A request's page: its timeline. `id` is the request's id, or the id of the
  message that started it, which is the same id once routing started the
  request (`request_id/1` reads it from the reference Ryker keeps).
  """
  @spec request(String.t()) :: String.t()
  def request(id) when is_binary(id), do: ~p"/timeline/#{uuid!(id)}"

  @doc "A request's page, opened at one of its attempts."
  @spec request_attempt(String.t(), String.t()) :: String.t()
  def request_attempt(id, turn_id) when is_binary(turn_id),
    do: query(request(id), %{"attempt" => turn_id}) <> "#request-" <> turn_id

  @doc """
  The id a request page is addressed by, from the reference a message's
  request is kept under (`ingress-input:<id>`), or nil for any other.
  """
  @spec request_id(String.t() | nil) :: String.t() | nil
  def request_id("ingress-input:" <> id), do: uuid(id)
  def request_id(_reference), do: nil

  @spec incident_room(String.t()) :: String.t()
  def incident_room(ref) when is_binary(ref),
    do: ~p"/incident-rooms/#{id("slack_incident", ref)}"

  @spec schedule(String.t()) :: String.t()
  def schedule(ref) when is_binary(ref), do: ~p"/schedules/#{id("schedule", ref)}"

  @spec channel(String.t(), String.t()) :: String.t()
  def channel(workspace_ref, channel_ref)
      when is_binary(workspace_ref) and is_binary(channel_ref),
      do: ~p"/channels/#{workspace_ref}/#{channel_ref}"

  @spec conversation(String.t()) :: String.t()
  def conversation(id) when is_binary(id), do: ~p"/conversations/#{id}"

  @spec repository(String.t()) :: String.t()
  def repository(ref) when is_binary(ref), do: ~p"/repositories/#{ref}"

  @spec edit_environment(String.t()) :: String.t()
  def edit_environment(ref) when is_binary(ref), do: ~p"/environments/#{ref}/edit"

  @spec edit_emisar_account(String.t()) :: String.t()
  def edit_emisar_account(ref) when is_binary(ref), do: ~p"/integrations/emisar/#{ref}/edit"

  @doc """
  Where one row of a settings list is edited, on its own page:
  `<items>/<key>/edit` (`Ryker.ControlPlane.SettingsEditor`). The list's path
  is data there, so this one is not a verified route.
  """
  @spec edit_item(String.t(), String.t()) :: String.t()
  def edit_item(items, key) when is_binary(items) and is_binary(key),
    do: items <> "/" <> segment(key) <> "/edit"

  @doc """
  One failure's page, by its kind and the reference Ryker keeps for the
  failing record, addressed as `id/2` says. Its id can keep a colon its own
  reference needs, which `~p` would percent-encode, so the path is built from
  readable segments (`PathsTest` holds the route it names).
  """
  @spec failure(String.t(), String.t()) :: String.t()
  def failure(kind, reference) when is_binary(kind) and is_binary(reference),
    do: "/" <> Enum.map_join(["failures", kind, id(kind, reference)], "/", &segment/1)

  # -- Actions ----------------------------------------------------------------

  @doc """
  The confirmation and the form target of one action on one record,
  `/actions/<kind>/<id>/<action>`, the record addressed as `id/2` says. The
  HTTP plug serves these, so they are not verified routes.
  """
  @spec action(String.t(), String.t(), String.t()) :: String.t()
  def action(kind, reference, action)
      when is_binary(kind) and is_binary(reference) and is_binary(action),
      do: "/" <> Enum.map_join(["actions", kind, id(kind, reference), action], "/", &segment/1)

  @doc "A file a Chat turn produced, downloaded from the turn that made it."
  @spec artifact(String.t(), String.t(), String.t()) :: String.t()
  def artifact(conversation_id, turn_id, ref) do
    "/" <>
      Enum.map_join(
        ["conversations", conversation_id, "turns", turn_id, "artifacts", ref],
        "/",
        &segment/1
      )
  end

  @doc "Where a Chat record card's action posts, or its read-only view opens."
  @spec conversation_record(String.t(), String.t(), String.t()) :: String.t()
  def conversation_record(conversation_id, record_ref, action) do
    "/" <>
      Enum.map_join(
        ["conversations", conversation_id, "records", record_ref, action],
        "/",
        &segment/1
      )
  end

  # -- Addresses ----------------------------------------------------------------

  # The prefix each kind's references carry, which its address leaves off. The
  # kinds a request's reference names are addressed by the request's id
  # instead (`request_id/1`).
  @prefixes %{
    "admission" => "ingress-input:",
    "behavior" => "behavior:",
    "case" => "case:",
    "delivery" => "delivery:",
    "memory" => "memory:",
    "publication" => "publication:",
    "schedule" => "schedule:",
    "slack_incident" => "incident-room:",
    "slack_task_card" => "task-card:"
  }
  @request_kinds ~w(episode stopping work)

  @doc """
  The id a record of `kind` is addressed by: its reference without the
  kind's prefix, the request's id for a request's kinds (`episode`, `work`,
  `stopping`), or the reference as it is for every other kind. A reference of
  another shape keeps its own prefix: a delivery failure can be a platform
  action's (`platform-action:<id>`), not only a reply's (`delivery:<id>`).
  """
  @spec id(String.t(), String.t()) :: String.t()
  def id(kind, reference) when kind in @request_kinds, do: uuid!(reference)

  def id(kind, reference) do
    with {:ok, prefix} <- Map.fetch(@prefixes, kind),
         "" <> id <- String.replace_prefix(reference, prefix, ""),
         true <- id != reference and id != "" and not String.contains?(id, ":") do
      id
    else
      _other_shape -> reference
    end
  end

  @doc """
  The reference a record of `kind` is kept under, from the id its address
  carries: `id/2` read back. An id that still holds a colon is a whole
  reference of another shape; one that repeats the kind's own prefix is no
  address (`:error`), as `id/2` never builds it. A request's kinds need the
  request's own key, which only its store knows, so they are left to the
  caller (`:request`).
  """
  @spec reference(String.t(), String.t()) :: {:ok, String.t()} | :request | :error
  def reference(kind, _id) when kind in @request_kinds, do: :request

  def reference(kind, id) do
    case Map.fetch(@prefixes, kind) do
      {:ok, prefix} -> prefixed(prefix, id)
      :error -> {:ok, id}
    end
  end

  defp prefixed(prefix, id) do
    cond do
      String.starts_with?(id, prefix) -> :error
      String.contains?(id, ":") -> {:ok, id}
      true -> {:ok, prefix <> id}
    end
  end

  # -- Parts ------------------------------------------------------------------

  @doc """
  `path` with `params` as its query, keeping `:`, `@` and `/` readable in
  each value. nil and "" values are left out, and no params give the path
  alone.
  """
  @spec query(String.t(), map() | keyword()) :: String.t()
  def query(path, params) when is_binary(path) do
    query = params |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> encode_query()
    if query == "", do: path, else: path <> "?" <> query
  end

  @doc """
  Params as a query string, every pair as given and nil as an empty value,
  readable as `query/2`'s. An empty value can mean something: a usage
  drilldown's `usage_effort=` asks for the calls that named no effort.
  """
  @spec encode_query(map() | keyword()) :: String.t()
  def encode_query(params) do
    Enum.map_join(params, "&", fn {key, value} ->
      encode_query_part(to_string(key)) <> "=" <> encode_query_part(to_string(value))
    end)
  end

  # A path segment keeps the characters a URL allows there unescaped, `:`
  # and `@` among them; everything else is percent-encoded. A query part also
  # keeps `/`, and writes a space as `+`, as a form would.
  defp segment(value), do: URI.encode(value, &(URI.char_unreserved?(&1) or &1 in ~c":@"))

  defp encode_query_part(value) do
    value
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 in ~c":@/ "))
    |> String.replace(" ", "+")
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid!(value) do
    uuid(value) ||
      request_id(value) ||
      raise ArgumentError, "a request is addressed by its id, got #{inspect(value)}"
  end
end
