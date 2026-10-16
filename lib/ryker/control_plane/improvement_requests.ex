defmodule Ryker.ControlPlane.ImprovementRequests do
  @moduledoc """
  The self-analysis of a request a person was unhappy with, as the Timeline's
  model-request cards in its Feedback chapter (Andrew, 2026-09-28: every kind
  of model call shows the exact prompt it was sent, as routing, work and
  learning do; the analysis had no card anywhere).

  Each attempt is a briefing card, with the instructions, the evidence it was
  given, the output contract and the exact prompt, and, once it ended, a
  review card (`Ryker.ControlPlane.FindingCard.review/1`): what went wrong and
  what Ryker should have done, the suspected cause and how sure it was, and
  how the attempt ran, with the model's raw response. Everything is read from
  the attempt's own frozen record and the execution ledger its worker's
  report was metered into; nothing is rebuilt from today's evidence, and
  retention says what it removed.
  """
  import Ryker.ControlPlane.BackgroundCards,
    only: [artifact_options: 2, present: 1, submitted: 5, target: 2]

  alias Ryker.Accounting
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, FindingCard, ImprovementPage, Paths}
  alias Ryker.ControlPlane.SentPrompts
  alias Ryker.Improvement
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.PromptDocument
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @limit 20

  @doc """
  The briefing and result cards of the analyses of the request `episode_id`,
  or of the message `input_id` that has no request, oldest first.

  Options: `:secrets` to redact and `:disclosed` with the artifact ids a
  reader opened (an attempt's prompt text is prepared only then).
  """
  @spec entries(keyword(), keyword()) :: [map()]
  def entries(owner, options \\ []) do
    case runs_for(owner) do
      [] -> []
      runs -> cards(runs, options)
    end
  end

  defp runs_for(episode_id: id) when is_binary(id),
    do: runs(Improvement.AnalysisRun.Query.by_episode_id(id))

  defp runs_for(input_id: id) when is_binary(id),
    do: runs(Improvement.AnalysisRun.Query.by_input_id(id))

  defp runs_for(_owner), do: []

  defp runs(query) do
    query
    |> Improvement.AnalysisRun.Query.ordered_by_recent()
    |> Improvement.AnalysisRun.Query.limit_to(@limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp cards(runs, options) do
    ids = Enum.map(runs, & &1.id)

    sessions =
      ids
      |> Work.Session.Query.by_improvement_run_ids()
      |> Repo.all()
      |> Map.new(&{&1.improvement_run_id, &1})

    context = %{
      secrets: Keyword.get(options, :secrets, []),
      sessions: sessions,
      sent:
        Work.Activity.prompts_sent(
          Enum.map(Map.values(sessions), & &1.id),
          Enum.map(runs, & &1.coop_turn_id)
        ),
      disclosed: Keyword.get(options, :disclosed),
      totals: Enum.frequencies_by(runs, & &1.candidate_id),
      # Generations count up from one, so the newest says how many attempts
      # there were, and the oldest shown is where their history starts.
      attempts:
        runs
        |> Enum.group_by(& &1.candidate_id)
        |> Map.new(fn {id, runs} ->
          {id,
           %{
             count: runs |> Enum.map(& &1.generation) |> Enum.max(),
             href: "#self-analysis-" <> Enum.min_by(runs, & &1.generation).id
           }}
        end),
      executions:
        "improvement"
        |> Accounting.Execution.Query.by_sources(ids)
        |> Repo.all()
        |> Map.new(&{&1.source_id, &1})
    }

    Enum.flat_map(runs, fn run -> [briefing(run, context) | result(run, context)] end)
  end

  defp briefing(run, context) do
    prompt = PromptDocument.decode(run.prompt)
    options = artifact_options(run, context)
    request_id = "self-analysis-#{run.id}-request"

    run
    |> base(context)
    |> Map.merge(%{
      id: "self-analysis-#{run.id}",
      phase: :submission,
      at: run.inserted_at,
      sort_at: run.inserted_at,
      retention_note:
        if run.pruned_at do
          "Retention removed the evidence and prompt this attempt was sent on " <>
            UTCDateTime.readable(run.pruned_at) <> ". Nothing is rebuilt from today's records."
        end,
      sections: [
        section("instructions", "Self-analysis instructions", prompt["instructions"], options),
        section("context", "The evidence it was given", prompt["context"], options),
        section("contract", "Required output contract", run.output_schema, options),
        submitted(run.prompt, request_id, :improvement, context, options)
      ],
      sent: SentPrompts.of_run(run, context.sessions[run.id], context.sent, context.secrets)
    })
  end

  defp result(run, context) do
    if BackgroundCards.result?(run) do
      options = artifact_options(run, context)
      document = run.result |> PromptDocument.decode() |> Redactor.document(context.secrets)
      ended = run.remote_stopped_at || run.updated_at
      response = section("response", "Model response", run.result, options)

      [
        run
        |> base(context)
        |> Map.merge(%{
          id: "self-analysis-#{run.id}-result",
          phase: :result,
          at: ended,
          sort_at: ended,
          run: CallRun.from_background(run, context.executions[run.id]),
          retention_note:
            if run.pruned_at do
              "Retention removed the model's response on #{UTCDateTime.readable(run.pruned_at)}. " <>
                "What it cost and how long it took stay recorded."
            end,
          sections: [response],
          review: review(run, document, response.artifact, context)
        })
      ]
    else
      []
    end
  end

  defp base(run, context) do
    %{
      kind: :request,
      source_kind: :improvement,
      band: :feedback,
      owner: :episode,
      title: "Self-analysis",
      target: target(run, context.executions[run.id]) || "Execution target not recorded",
      status: run.status,
      policy: run.policy,
      policy_digest: run.policy_digest,
      generation: run.generation,
      generations: context.totals[run.candidate_id],
      counts: %{},
      href: nil
    }
  end

  # An attempt still waiting on its model has only its briefing. One that
  # ended reads as What to fix reads its finding: what went wrong, what Ryker
  # should have done, and the suspected cause, with how many attempts there
  # were. One Ryker could not use says why in words.
  defp review(run, document, artifact, context) do
    category = category(document)
    found? = run.status in [:applied, :responded]

    %{
      title: if(found?, do: "Review", else: "No usable answer"),
      attempt: if(context.attempts[run.candidate_id].count > 1, do: "Attempt #{run.generation}"),
      meta: meta(run, category, document["confidence"]),
      hint: if(run.status == :applied, do: FindingCard.hint(category)),
      what_went_wrong: if(found?, do: present(document["what_went_wrong"])),
      expected: if(found?, do: present(document["expected"])),
      note: outcome(run),
      attempts: context.attempts[run.candidate_id],
      response:
        if(artifact.state == :retained,
          do: %{text: artifact.text, note: if(artifact.truncated, do: "Partial display")}
        ),
      finding_href: if(run.status == :applied, do: finding_path(run))
    }
  end

  defp meta(%Improvement.AnalysisRun{status: :applied}, category, confidence),
    do: FindingCard.cause(category, confidence)

  defp meta(%Improvement.AnalysisRun{status: :responded}, _category, _confidence),
    do: "Ryker is checking the answer"

  defp meta(_run, _category, _confidence), do: nil

  defp outcome(%Improvement.AnalysisRun{status: :rejected, result_sha256: digest})
       when is_binary(digest),
       do: "Ryker did not use this answer: it did not match the format asked for."

  defp outcome(%Improvement.AnalysisRun{status: :rejected}),
    do: "The attempt ended before the model answered."

  defp outcome(%Improvement.AnalysisRun{status: :stale}), do: "The attempt never started."
  defp outcome(_run), do: nil

  defp finding_path(run) do
    Paths.query(ImprovementPage.path(), %{"candidate" => run.candidate_id}) <>
      "#improvement-" <> run.candidate_id
  end

  defp category(%{"category" => value}) when is_binary(value),
    do: Enum.find(Improvement.Candidate.categories(), &(Atom.to_string(&1) == value))

  defp category(_document), do: nil

  defp section(id, title, value, options),
    do: BackgroundCards.section(id, title, value, :improvement, options)
end
