defmodule Ryker.ControlPlane.BehaviorLibrary do
  @moduledoc """
  Bounded operator views of confirmed rules, preferences, and guidance.

  Rules are listed on /rules. Preferences and guidance are listed together on
  /instructions, under "Saved from conversations". Both lists show Current
  (on or paused) or Past (expired, deleted or replaced) entries.
  """
  import Ecto.Query
  alias Ryker.ControlPlane.{InspectionRedactor, PagedRelation, Search}
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.{Behavior, StandingAssignmentRun}

  @payload_fields ~w(title task trigger source_kind source_filter filter action repository key value subject summary text visibility context_channel delivery_channel)
  @shown %{"preferences" => :preference, "guidance" => :guidance}

  @doc "The page that lists entries of `kind`; its rows are anchored `#behavior-<ref>`."
  def path(:standing_assignment), do: "/rules"
  def path(kind) when kind in [:preference, :guidance], do: "/instructions"

  @doc "Where a confirmed Pause, Resume or Delete returns: the list the entry is in."
  def return_path(:standing_assignment), do: "/rules"
  def return_path(kind) when kind in [:preference, :guidance], do: "/instructions#saved"

  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(b in instruction_query(), where: b.ref == ^ref)) do
      nil -> :not_found
      item -> {:ok, sanitize(item)}
    end
  end

  def fetch(_ref), do: :not_found

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

  @doc """
  One page of confirmed entries of `kinds` (one kind or several) for a page's
  query `params`: "status" is current (the default) or past, "q" searches
  their stored text, "show" narrows several kinds to one of them
  ("preferences" or "guidance"), and "page" pages. `counts` holds every
  status of the shown kinds before search, so an empty page can tell "nothing
  here yet" from "nothing current".
  """
  def list(kind, params) when is_atom(kind), do: list([kind], params)

  def list(kinds, params) when is_list(kinds) do
    show = show(kinds, params["show"])
    shown = if show == "all", do: kinds, else: [@shown[show]]
    base = from(b in instruction_query(), where: b.kind in ^shown)

    counts =
      Repo.all(from(b in subquery(base), group_by: b.status, select: {b.status, count(b.id)}))
      |> Map.new()

    status = if params["status"] == "past", do: "past", else: "current"
    q = params |> scalar("q") |> String.trim() |> String.slice(0, 160)

    filtered =
      from(b in subquery(base))
      |> filter_status(status)
      |> filter_search(q)

    page = PagedRelation.read(filtered, [desc: :updated_at, desc: :id], "page", params)

    %{
      kinds: kinds,
      items: Enum.map(page.items, &sanitize/1),
      counts: counts,
      total: page.total,
      page: page.page,
      pages: page.pages,
      runs: if(kinds == [:standing_assignment], do: runs(page.items), else: []),
      params: %{"status" => status, "q" => q, "show" => show}
    }
  end

  defp show(kinds, value) do
    if length(kinds) > 1 and Map.get(@shown, value) in kinds, do: value, else: "all"
  end

  defp runs(items) do
    ids = Enum.map(items, & &1.id)

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
  end

  defp filter_status(query, "past"),
    do: from(b in query, where: b.status in ["expired", "deleted", "superseded"])

  defp filter_status(query, _current),
    do: from(b in query, where: b.status in ["active", "disabled"])

  defp scalar(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp filter_search(query, ""), do: query

  defp filter_search(query, value) do
    pattern = Search.contains(value)

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
