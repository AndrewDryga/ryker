defmodule Ryker.ControlPlane.BehaviorLibrary do
  @moduledoc """
  Bounded operator views of confirmed rules, preferences, and guidance.

  Rules are listed on /rules. Preferences and guidance are listed together on
  /instructions, under "Saved from conversations". Both lists show Current
  (on or paused) or Past (expired, deleted or replaced) entries.
  """
  alias Ryker.ControlPlane.{BehaviorLibraryQuery, PagedRelation, RepositoryNames, Search}
  alias Ryker.InspectionRedactor
  alias Ryker.Repo

  @payload_fields ~w(title task source_kind filter repository key value subject summary text visibility context_channel delivery_channel applicability)
  @shown %{"preferences" => :preference, "guidance" => :guidance}

  @doc "The page that lists entries of `kind`; its rows are anchored `#behavior-<ref>`."
  def path(:standing_assignment), do: "/rules"
  def path(kind) when kind in [:preference, :guidance], do: "/instructions"

  @doc "Where a confirmed Pause, Resume or Delete returns: the list the entry is in."
  def return_path(:standing_assignment), do: "/rules"
  def return_path(kind) when kind in [:preference, :guidance], do: "/instructions#saved"

  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    item = instruction_query() |> BehaviorLibraryQuery.by_ref(ref) |> Repo.one()
    if item, do: {:ok, item |> sanitize() |> List.wrap() |> named() |> hd()}, else: :not_found
  end

  def fetch(_ref), do: :not_found

  defp instruction_query, do: BehaviorLibraryQuery.entries(DateTime.utc_now())

  @doc """
  One page of confirmed entries of `kinds` (one kind or several) for a page's
  query `params`: "view" is current (the default) or past, as on Schedules
  and Follow-ups, "q" searches
  their stored text, "show" narrows several kinds to one of them
  ("preferences" or "guidance"), and "page" pages. `counts` holds every
  status of the shown kinds before search, so an empty page can tell "nothing
  here yet" from "nothing current".
  """
  def list(kind, params) when is_atom(kind), do: list([kind], params)

  def list(kinds, params) when is_list(kinds) do
    show = show(kinds, params["show"])
    shown = if show == "all", do: kinds, else: [@shown[show]]
    base = BehaviorLibraryQuery.of_kinds(instruction_query(), shown)
    counts = base |> BehaviorLibraryQuery.status_counts() |> Repo.all() |> Map.new()

    view = if params["view"] == "past", do: "past", else: "current"
    search = params |> scalar("q") |> String.trim() |> String.slice(0, 160)

    filtered =
      base
      |> BehaviorLibraryQuery.listed()
      |> BehaviorLibraryQuery.in_view(view)
      |> filter_search(search)

    page = PagedRelation.read(filtered, [desc: :updated_at, desc: :id], "page", params)

    %{
      kinds: kinds,
      items: page.items |> Enum.map(&sanitize/1) |> named(),
      counts: counts,
      total: page.total,
      page: page.page,
      pages: page.pages,
      runs: if(kinds == [:standing_assignment], do: runs(page.items), else: []),
      params: %{"view" => view, "q" => search, "show" => show}
    }
  end

  defp show(kinds, value) do
    if length(kinds) > 1 and Map.get(@shown, value) in kinds, do: value, else: "all"
  end

  defp runs(items) do
    ids = Enum.map(items, & &1.id)

    ids |> BehaviorLibraryQuery.rule_runs(25) |> Repo.all()
  end

  defp scalar(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp filter_search(query, ""), do: query

  defp filter_search(query, value),
    do: BehaviorLibraryQuery.matching(query, Search.contains(value))

  @doc false
  # An entry for one repository names it the way GitHub does; it named the
  # repository by its ref, where every other page used the name (2026-10-04
  # review).
  defp named(items) do
    names =
      if Enum.any?(items, &(&1.scope_kind == :repository)),
        do: RepositoryNames.all(),
        else: %{}

    Enum.map(items, fn
      %{scope_kind: :repository, scope_ref: ref} = item ->
        Map.put(item, :scope_name, RepositoryNames.name(names, ref))

      item ->
        item
    end)
  end

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
