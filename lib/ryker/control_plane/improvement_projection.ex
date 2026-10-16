defmodule Ryker.ControlPlane.ImprovementProjection do
  @moduledoc """
  Feedback › What to fix (`/feedback/fix`) and the What to
  fix counts on the Feedback page: requests people were unhappy with
  (`Ryker.Improvement`), each with Ryker's own diagnosis.

  The list shows one decision at a time, open by default, or what was
  accepted or dismissed. It reads newest first by day, and within a day the
  surest diagnoses first, so the ones worth deciding on are on top. Each
  finding names its request as Activity names it and opens its Timeline, says
  how the analysis ran, and an open one can be accepted as an eval case or
  dismissed.
  """
  alias Ryker.Accounting
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, FeedbackProjection, PagedRelation, PathRef}
  alias Ryker.Improvement
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  @page_size 50
  @statuses [:open, :accepted, :dismissed]
  @response_bytes 2 * 1_024 * 1_024

  @doc "The query keys the page reads."
  def query_keys, do: ["status", "category", "page", "candidate"]

  @doc """
  One read of the page for `params`: the counts of each decision, and one
  page of candidates.
  """
  @spec page(map()) :: map()
  def page(params) when is_map(params) do
    visible = Improvement.Candidate.Query.kept()

    {status, category, listed} =
      case linked(visible, params["candidate"]) do
        {id, status} ->
          {status, nil, Improvement.Candidate.Query.by_id(visible, id)}

        nil ->
          status = pick(params["status"], @statuses) || :open
          category = pick(params["category"], Improvement.Candidate.categories())
          in_status = Improvement.Candidate.Query.by_status(visible, status)

          listed =
            if category,
              do: Improvement.Candidate.Query.by_category(in_status, category),
              else: in_status

          {status, category, listed}
      end

    paged =
      PagedRelation.read(listed, Improvement.Candidate.Query.review_order(), "page", params,
        page_size: @page_size
      )

    %{
      status: status,
      category: category,
      counts: status_counts(visible),
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
         {:ok, %Improvement.Candidate{forgotten_at: nil} = candidate} <-
           Repo.fetch(Improvement.Candidate.Query.by_id(id)) do
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

  defp exportable, do: Repo.aggregate(Improvement.Candidate.Query.exportable_cases(), :count)

  # Each candidate with the request it is about, named as Activity names it,
  # and how its analysis ran.
  defp present([]), do: []

  defp present(candidates) do
    requests = FeedbackProjection.requests(candidates)
    runs = analysis_runs(candidates)

    Enum.map(candidates, fn %Improvement.Candidate{} = candidate ->
      request = FeedbackProjection.request(requests, candidate)

      %{
        id: candidate.id,
        at: candidate.last_signal_at,
        status: candidate.status,
        reasons: candidate.reasons,
        signal_count: candidate.signal_count,
        request: request,
        analysis_run: analysis_run(Map.get(runs.by_candidate, candidate.id, []), runs, request),
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

  defp analysis_runs(candidates) do
    runs =
      candidates
      |> Enum.map(& &1.id)
      |> Improvement.AnalysisRun.Query.by_candidate_ids()
      |> Improvement.AnalysisRun.Query.without_prompt()
      |> Repo.all()

    %{
      by_candidate: Enum.group_by(runs, & &1.candidate_id),
      executions:
        "improvement"
        |> Accounting.Execution.Query.by_sources(Enum.map(runs, & &1.id))
        |> Repo.all()
        |> Map.new(&{&1.source_id, &1})
    }
  end

  # The attempt the finding came from, the newest that applied its diagnosis,
  # or else the newest that ended; how many attempts there were, counted by
  # their generations; and where the request's timeline shows them all.
  defp analysis_run(runs, %{executions: executions}, request) do
    ended = Enum.filter(runs, &BackgroundCards.result?/1)
    applied = Enum.filter(ended, &(&1.status == :applied))

    case Enum.max_by(if(applied != [], do: applied, else: ended), & &1.generation, fn -> nil end) do
      nil ->
        nil

      run ->
        first = Enum.min_by(runs, & &1.generation)

        artifact =
          InspectionRedactor.artifact(run.result,
            secrets: InspectionRedactor.configured_secrets(),
            max_bytes: @response_bytes,
            expired: not is_nil(run.pruned_at)
          )

        %{
          id: run.id,
          run: CallRun.from_background(run, executions[run.id]),
          attempts: %{
            count: runs |> Enum.map(& &1.generation) |> Enum.max(),
            href: request[:href] && request.href <> "#self-analysis-" <> first.id
          },
          response:
            if(artifact.state == :retained,
              do: %{text: artifact.text, note: if(artifact.truncated, do: "Partial display")}
            ),
          response_note: pruned_note(run.pruned_at)
        }
    end
  end

  defp pruned_note(nil), do: nil

  defp pruned_note(at),
    do: "Retention removed the model's response on #{UTCDateTime.readable(at)}."

  defp redacted(nil), do: nil

  defp redacted(text) do
    artifact = InspectionRedactor.artifact(text, max_bytes: 8_192)
    if artifact.text, do: String.trim(artifact.text)
  end
end
