defmodule Ryker.ControlPlane.MemoryProjection do
  @moduledoc """
  The Facts page's read model: the operational memory people confirmed and the
  pending reviews of it. Expiry is applied at read time; every retained text is
  redacted the way the rest of the control plane redacts it.

  The page lists the facts a page at a time, newest first, and the oldest
  hundred reviews with how many are pending; an action finds its fact or
  review by reference (`fact/1`, `review/1`), wherever it falls. The newest
  hundred facts used to be all the page showed, with nothing saying more
  existed (2026-10-04 review).
  """
  alias Ryker.ControlPlane.{PagedRelation, RepositoryNames}
  alias Ryker.InspectionRedactor
  alias Ryker.Memories
  alias Ryker.Repo

  @reviews_shown 100

  @doc "The query keys the Facts page reads."
  def query_keys, do: ["q", "page"]

  @doc "Every collection the Facts page shows, expiry applied at read time."
  def fetch(params \\ %{}) do
    secrets = InspectionRedactor.configured_secrets()
    search = search_text(params["q"])

    facts =
      fact_rows()
      |> search(search)
      |> PagedRelation.read([desc: :updated_at, desc: :id], "page", params)

    reviews = Memories.pending_reviews(@reviews_shown)
    names = names(facts.items, reviews)

    %{
      q: search,
      memory_total: Repo.aggregate(active(), :count),
      memories: Enum.map(facts.items, &(&1 |> redact(secrets) |> named(names))),
      facts_page: Map.take(facts, [:page, :pages, :total]),
      reviews: Enum.map(reviews, &named_review(&1, names)),
      review_total: Memories.pending_review_count()
    }
  end

  @doc "One active fact as the page shows it, by reference, or nil."
  def fact(ref) when is_binary(ref) do
    fact = fact_rows() |> Memories.MemoryEntry.Query.by_ref(ref) |> Repo.one()

    if fact,
      do: fact |> redact(InspectionRedactor.configured_secrets()) |> named(names([fact], []))
  end

  @doc "One pending review as the page shows it, by reference, or nil."
  def review(review_ref) when is_binary(review_ref) do
    case Memories.pending_review(review_ref) do
      nil -> nil
      review -> named_review(review, names([], [review]))
    end
  end

  # A fact for one repository names it the way GitHub does; the page named the
  # repository by its ref, where every other page used the name (2026-10-04
  # review).
  defp names(facts, reviews) do
    repository? =
      Enum.any?(facts, &(&1.scope == :repository)) or
        Enum.any?(reviews, fn review ->
          Enum.any?(review["entries"] || [], &(&1["scope"] == "repository"))
        end)

    if repository?, do: RepositoryNames.all(), else: %{}
  end

  defp named(%{scope: :repository, scope_ref: ref} = fact, names),
    do: Map.put(fact, :scope_name, RepositoryNames.name(names, ref))

  defp named(fact, _names), do: fact

  defp named_review(review, names) do
    Map.update(review, "entries", [], fn entries ->
      Enum.map(entries, fn
        %{"scope" => "repository", "scope_ref" => ref} = entry ->
          Map.put(entry, "scope_name", RepositoryNames.name(names, ref))

        entry ->
          entry
      end)
    end)
  end

  defp active,
    do: Memories.MemoryEntry.Query.active() |> Memories.MemoryEntry.Query.unexpired_now()

  defp fact_rows, do: Memories.MemoryEntry.Query.select_facts(active())

  # A memory is a person's own words, confirmed as a fact; they are redacted
  # here exactly as the channel page and the behavior library redact them.
  defp redact(fact, secrets), do: redact_fields(fact, [:applicability, :subject, :value], secrets)

  defp search(query, ""), do: query

  defp search(query, text), do: Memories.MemoryEntry.Query.saying(query, text)

  defp search_text(value) when is_binary(value), do: String.slice(String.trim(value), 0, 200)
  defp search_text(_value), do: ""

  defp redact_fields(row, keys, secrets) do
    Enum.reduce(keys, row, fn key, row ->
      case Map.fetch!(row, key) do
        text when is_binary(text) ->
          Map.put(row, key, InspectionRedactor.artifact(text, secrets: secrets).text)

        _absent ->
          row
      end
    end)
  end
end
