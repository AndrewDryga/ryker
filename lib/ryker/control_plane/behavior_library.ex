defmodule Ryker.ControlPlane.BehaviorLibrary do
  @moduledoc "Bounded operator views of confirmed rules, preferences, and guidance."
  import Ecto.Query
  alias Ryker.ControlPlane.InspectionRedactor
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.{Behavior, StandingAssignmentRun}

  @kinds %{"rules" => :standing_assignment, "preferences" => :preference, "guidance" => :guidance}
  @payload_fields ~w(title task trigger source_kind source_filter filter action repository key value subject summary text visibility context_channel delivery_channel)

  def kind(path), do: Map.fetch!(@kinds, path)
  def path(:standing_assignment), do: "/rules"
  def path(:preference), do: "/preferences"
  def path(:guidance), do: "/guidance"

  def fetch(ref) do
    case Repo.one(from(b in instruction_query(), where: b.ref == ^ref)) do
      nil -> :not_found
      item -> {:ok, sanitize(item)}
    end
  end

  defp instruction_query do
    now = DateTime.utc_now()
    # Expiry is effective even before a maintenance pass updates the stored status.
    from(b in Behavior,
      select: %{
        id: b.id,
        ref: b.ref,
        kind: b.kind,
        payload: b.payload,
        status:
          fragment(
            "CASE WHEN ? IN ('active', 'disabled') AND ? <= ? THEN 'expired' ELSE ? END",
            b.status,
            b.expires_at,
            ^now,
            b.status
          ),
        workspace_ref: b.workspace_ref,
        scope_kind: b.scope_kind,
        scope_ref: b.scope_ref,
        use_count: b.use_count,
        last_used_at: b.last_used_at,
        expires_at: b.expires_at,
        confirmed_at: b.confirmed_at,
        source_conversation_ref: b.source_conversation_ref,
        source_message_ref: b.source_message_ref,
        updated_at: b.updated_at
      }
    )
  end

  def list(kind, params) when kind in [:standing_assignment, :preference, :guidance] do
    base = from(b in instruction_query(), where: b.kind == ^kind)

    counts =
      Repo.all(from(b in subquery(base), group_by: b.status, select: {b.status, count(b.id)}))
      |> Map.new()

    status =
      if params["status"] in ~w(all active disabled expired archived),
        do: params["status"],
        else: "current"

    q = params |> scalar("q") |> String.trim() |> String.slice(0, 160)

    scope =
      if params["scope"] in ~w(workspace conversation repository operator),
        do: params["scope"],
        else: ""

    filtered =
      from(b in subquery(base))
      |> filter_status(status)
      |> filter_search(q)
      |> filter_scope(scope)

    total = Repo.aggregate(filtered, :count)
    pages = max(ceil(total / 25), 1)

    page =
      case Integer.parse(scalar(params, "page")) do
        {number, ""} -> min(max(number, 1), pages)
        _ -> 1
      end

    items =
      Repo.all(
        from(b in filtered,
          order_by: [desc: b.updated_at, desc: b.id],
          limit: 25,
          offset: ^((page - 1) * 25)
        )
      )

    ids = Enum.map(items, & &1.id)

    runs =
      if kind == :standing_assignment do
        Repo.all(
          from(r in StandingAssignmentRun,
            left_join: e in Episode,
            on: e.id == r.episode_id,
            join: b in Behavior,
            on: b.id == r.assignment_id,
            where: r.assignment_id in ^ids,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 25,
            select: %{
              rule_ref: b.ref,
              at: r.inserted_at,
              outcome: r.outcome,
              action: r.decision_action,
              episode_ref: e.key
            }
          )
        )
      else
        []
      end

    %{
      kind: kind,
      items: Enum.map(items, &sanitize/1),
      counts: counts,
      total: total,
      page: page,
      pages: pages,
      runs: runs,
      params: %{"status" => status, "q" => q, "scope" => scope}
    }
  end

  defp filter_status(query, "current"),
    do: from(b in query, where: b.status in ["active", "disabled"])

  defp filter_status(query, "all"), do: query

  defp filter_status(query, "archived"),
    do: from(b in query, where: b.status in ["deleted", "superseded"])

  defp filter_status(query, status), do: from(b in query, where: b.status == ^status)

  defp scalar(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp filter_scope(query, ""), do: query

  defp filter_scope(query, scope),
    do: from(b in query, where: fragment("?::text", b.scope_kind) == ^scope)

  defp filter_search(query, ""), do: query

  defp filter_search(query, value) do
    pattern = "%" <> String.replace(value, ["\\", "%", "_"], &"\\#{&1}") <> "%"

    from(b in query,
      where: ilike(fragment("?::text", b.payload), ^pattern) or ilike(b.scope_ref, ^pattern)
    )
  end

  @doc false
  def sanitize(item) do
    payload =
      Map.new(Map.take(item.payload, @payload_fields), fn {key, value} ->
        {key, sanitize_value(value)}
      end)

    Map.put(item, :payload, payload)
  end

  defp sanitize_value(value) do
    artifact = InspectionRedactor.artifact(value)

    cond do
      artifact.truncated ->
        "Too large to display. Open the original conversation to inspect these conditions."

      is_map(value) or is_list(value) ->
        Jason.decode!(artifact.text)

      true ->
        artifact.text
    end
  end
end
