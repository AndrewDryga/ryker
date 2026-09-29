defmodule Ryker.ControlPlane.ImprovementProjection do
  @moduledoc """
  Feedback › What to fix (`/feedback/fix`) and the What to
  fix counts on the Feedback page: requests people were unhappy with
  (`Ryker.Improvement`), each with Ryker's own diagnosis.

  The list shows one decision at a time, open by default, or what was
  accepted or dismissed. It reads newest first by day, and within a day the
  surest diagnoses first, so the ones worth deciding on are on top. Each row
  names its request as Activity names it and opens its Timeline; an open one
  can be accepted as an eval case or dismissed.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{FeedbackProjection, PagedRelation, PathRef}
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate
  alias Ryker.InspectionRedactor
  alias Ryker.Repo

  @page_size 50
  @statuses [:open, :accepted, :dismissed]
  @week_seconds 7 * 86_400

  @doc "The query keys the page reads."
  def query_keys, do: ["status", "category", "page"]

  @doc """
  One read of the page for `params`: the counts of each decision and of each
  category in the view, what the last seven days brought, and one page of
  candidates.
  """
  @spec page(map()) :: map()
  def page(params) when is_map(params) do
    status = pick(params["status"], @statuses) || :open
    category = pick(params["category"], Candidate.categories())
    visible = from(candidate in Candidate, as: :candidate, where: is_nil(candidate.forgotten_at))
    in_status = from([candidate: candidate] in visible, where: candidate.status == ^status)

    listed =
      if category,
        do: from([candidate: candidate] in in_status, where: candidate.category == ^category),
        else: in_status

    paged = PagedRelation.read(listed, order(), "page", params, page_size: @page_size)

    %{
      status: status,
      category: category,
      counts: status_counts(visible),
      categories: category_counts(in_status),
      week: week(),
      exportable: exportable(),
      items: present(paged.items),
      listed: paged.total,
      page: paged.page,
      pages: paged.pages
    }
  end

  @doc """
  The What to fix counts on the Feedback page: how many are open, accepted
  and dismissed, and how the open ones split by category.
  """
  @spec summary() :: map()
  def summary do
    visible = from(candidate in Candidate, as: :candidate, where: is_nil(candidate.forgotten_at))

    %{
      counts: status_counts(visible),
      categories:
        category_counts(from([candidate: candidate] in visible, where: candidate.status == :open))
    }
  end

  @doc "One candidate that can still be decided, for its confirmation, or `:error`."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(id) do
    with {:ok, id} <- PathRef.uuid(id),
         %Candidate{forgotten_at: nil} = candidate <- Repo.get(Candidate, id) do
      [item] = present([candidate])
      {:ok, item}
    else
      _missing -> :error
    end
  end

  # Newest day first, and within a day the surest diagnosis first, then the
  # newest; the id breaks ties so no row repeats or goes missing between pages.
  defp order do
    [
      desc: dynamic([candidate], fragment("date(?)", candidate.last_signal_at)),
      desc:
        dynamic(
          [candidate],
          fragment(
            "CASE ? WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END",
            candidate.confidence
          )
        ),
      desc: dynamic([candidate], candidate.last_signal_at),
      desc: dynamic([candidate], candidate.id)
    ]
  end

  defp pick(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp pick(_value, _allowed), do: nil

  defp status_counts(query) do
    counts =
      from([candidate: candidate] in query,
        group_by: candidate.status,
        select: {candidate.status, count()}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(@statuses, &{&1, Map.get(counts, &1, 0)})
  end

  defp category_counts(query) do
    from([candidate: candidate] in query,
      where: not is_nil(candidate.category),
      group_by: candidate.category,
      select: {candidate.category, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  # What the last seven days brought, by the database clock that stamps a
  # candidate and its decision: the candidates found, by what Ryker made of
  # them (a category, still to analyze, or not analyzed), and the ones
  # accepted or dismissed (`Ryker.Improvement.week/2`).
  defp week do
    now = Repo.now!()
    Improvement.week(DateTime.add(now, -@week_seconds, :second), DateTime.add(now, 1, :second))
  end

  defp exportable do
    Repo.aggregate(
      from(candidate in Candidate,
        where:
          candidate.status == :accepted and is_nil(candidate.forgotten_at) and
            not is_nil(candidate.case_evidence)
      ),
      :count
    )
  end

  # Each candidate with the request it is about, named as Activity names it.
  defp present([]), do: []

  defp present(candidates) do
    requests = FeedbackProjection.requests(candidates)

    Enum.map(candidates, fn %Candidate{} = candidate ->
      %{
        id: candidate.id,
        at: candidate.last_signal_at,
        status: candidate.status,
        reasons: candidate.reasons,
        signal_count: candidate.signal_count,
        request: FeedbackProjection.request(requests, candidate),
        transport: candidate.transport,
        analysis: candidate.analysis,
        error_code: candidate.error_code,
        category: candidate.category,
        step: candidate.step,
        confidence: candidate.confidence,
        what_went_wrong: redacted(candidate.what_went_wrong),
        expected: redacted(candidate.expected),
        analyzed_at: candidate.analyzed_at,
        analysis_target: candidate.analysis_target,
        decided_at: candidate.decided_at,
        case: is_map(candidate.case_evidence)
      }
    end)
  end

  defp redacted(nil), do: nil

  defp redacted(text) do
    artifact = InspectionRedactor.artifact(text, max_bytes: 8_192)
    if artifact.text, do: String.trim(artifact.text)
  end
end
