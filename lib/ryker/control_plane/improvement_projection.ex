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
  alias Ryker.ControlPlane.{FeedbackProjection, PagedRelation, PathRef}
  alias Ryker.Improvement
  alias Ryker.InspectionRedactor
  alias Ryker.Repo

  @page_size 50
  @statuses [:open, :accepted, :dismissed]
  @week_seconds 7 * 86_400

  @doc "The query keys the page reads."
  def query_keys, do: ["status", "category", "page", "candidate"]

  @doc """
  One read of the page for `params`: the counts of each decision and of each
  category in the view, what the last seven days brought, and one page of
  candidates.
  """
  @spec page(map()) :: map()
  def page(params) when is_map(params) do
    visible = Improvement.Candidate.Query.kept()

    {status, category, in_status, listed} =
      case linked(visible, params["candidate"]) do
        {id, status} ->
          {status, nil, Improvement.Candidate.Query.by_status(visible, status),
           Improvement.Candidate.Query.by_id(visible, id)}

        nil ->
          status = pick(params["status"], @statuses) || :open
          category = pick(params["category"], Improvement.Candidate.categories())
          in_status = Improvement.Candidate.Query.by_status(visible, status)

          listed =
            if category,
              do: Improvement.Candidate.Query.by_category(in_status, category),
              else: in_status

          {status, category, in_status, listed}
      end

    paged =
      PagedRelation.read(listed, Improvement.Candidate.Query.review_order(), "page", params,
        page_size: @page_size
      )

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
    visible = Improvement.Candidate.Query.kept()

    %{
      counts: status_counts(visible),
      categories: category_counts(Improvement.Candidate.Query.by_status(visible, :open))
    }
  end

  @doc "One candidate that can still be decided, for its confirmation, or `:error`."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(id) do
    with {:ok, id} <- PathRef.uuid(id),
         %Improvement.Candidate{forgotten_at: nil} = candidate <-
           Repo.one(Improvement.Candidate.Query.by_id(id)) do
      [item] = present([candidate])
      {:ok, item}
    else
      _missing -> :error
    end
  end

  # One finding's own link (`?candidate=`) lists just it, under its own decision: an anchor into
  # the first page of To decide missed one on a later page or already decided (2026-10-04
  # review).
  defp linked(visible, value) do
    with {:ok, id} <- PathRef.uuid(value),
         status when not is_nil(status) <- candidate_status(visible, id) do
      {id, status}
    else
      _unlinked -> nil
    end
  end

  defp candidate_status(visible, id) do
    visible
    |> Improvement.Candidate.Query.by_id(id)
    |> Improvement.Candidate.Query.select_statuses()
    |> Repo.one()
  end

  defp pick(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp pick(_value, _allowed), do: nil

  defp status_counts(query) do
    counts = query |> Improvement.Candidate.Query.count_by_status() |> Repo.all() |> Map.new()

    Map.new(@statuses, &{&1, Map.get(counts, &1, 0)})
  end

  defp category_counts(query),
    do: query |> Improvement.Candidate.Query.count_by_category() |> Repo.all() |> Map.new()

  # What the last seven days brought, by the database clock that stamps a
  # candidate and its decision: the candidates found, by what Ryker made of
  # them (a category, still to analyze, or not analyzed), and the ones
  # accepted or dismissed (`Ryker.Improvement.week/2`).
  defp week do
    now = Repo.now!()
    Improvement.week(DateTime.add(now, -@week_seconds, :second), DateTime.add(now, 1, :second))
  end

  defp exportable, do: Repo.aggregate(Improvement.Candidate.Query.exportable_cases(), :count)

  # Each candidate with the request it is about, named as Activity names it.
  defp present([]), do: []

  defp present(candidates) do
    requests = FeedbackProjection.requests(candidates)

    Enum.map(candidates, fn %Improvement.Candidate{} = candidate ->
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
