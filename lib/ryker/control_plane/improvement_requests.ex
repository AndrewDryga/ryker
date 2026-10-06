defmodule Ryker.ControlPlane.ImprovementRequests do
  @moduledoc """
  The self-analysis of a request a person was unhappy with, as the Timeline's
  model-request cards in its Feedback chapter (Andrew, 2026-09-28: every kind
  of model call shows the exact prompt it was sent, as routing, work and
  learning do; the analysis had no card anywhere).

  Each attempt is a briefing card, with the instructions, the evidence it was
  given, the output contract and the exact prompt, and, once it ended, a
  result card: the model's response, what it found and how sure it was, what
  it cost and where its time went. Everything is read from the attempt's own
  frozen record and the execution ledger its worker's report was metered
  into; nothing is rebuilt from today's evidence, and retention says what it
  removed.
  """
  import Ecto.Query

  import Ryker.ControlPlane.BackgroundCards,
    only: [
      artifact_options: 2,
      decode: 1,
      identifier: 2,
      present: 1,
      record_text: 2,
      submitted: 5,
      target: 2,
      time: 2,
      timestamp: 1
    ]

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, ImprovementPage, Paths}
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Candidate}
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Repo
  alias Ryker.Work.Session

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
    do: runs(dynamic([candidate: c], c.episode_id == ^id))

  defp runs_for(input_id: id) when is_binary(id),
    do: runs(dynamic([candidate: c], c.input_id == ^id and is_nil(c.episode_id)))

  defp runs_for(_owner), do: []

  defp runs(owned) do
    Repo.all(
      from(run in AnalysisRun,
        join: candidate in Candidate,
        as: :candidate,
        on: candidate.id == run.candidate_id,
        where: ^owned,
        order_by: [desc: run.inserted_at, desc: run.id],
        limit: @limit
      )
    )
    |> Enum.reverse()
  end

  defp cards(runs, options) do
    ids = Enum.map(runs, & &1.id)

    context = %{
      secrets: Keyword.get(options, :secrets, []),
      disclosed: Keyword.get(options, :disclosed),
      totals: Enum.frequencies_by(runs, & &1.candidate_id),
      executions:
        Repo.all(from(e in Execution, where: e.kind == "improvement" and e.source_id in ^ids))
        |> Map.new(&{&1.source_id, &1}),
      sessions:
        Repo.all(
          from(s in Session,
            where: s.execution_kind == :improvement and s.improvement_run_id in ^ids
          )
        )
        |> Map.new(&{&1.improvement_run_id, &1})
    }

    Enum.flat_map(runs, fn run -> [briefing(run, context) | result(run, context)] end)
  end

  defp briefing(run, context) do
    prompt = decode(run.prompt)
    options = artifact_options(run, context)
    request_id = "self-analysis-#{run.id}-request"

    run
    |> base(context)
    |> Map.merge(%{
      id: "self-analysis-#{run.id}",
      phase: :submission,
      at: run.inserted_at,
      sort_at: run.inserted_at,
      identity: if(not result_card?(run), do: identity(run, context)),
      retention_note:
        if run.pruned_at do
          "Retention removed the evidence and prompt this attempt was sent on " <>
            timestamp(run.pruned_at) <> ". Nothing is rebuilt from today's records."
        end,
      sections: [
        section("instructions", "Self-analysis instructions", prompt["instructions"], options),
        section("context", "The evidence it was given", prompt["context"], options),
        section("contract", "Required output contract", run.output_schema, options),
        submitted(run.prompt, request_id, :improvement, context, options)
      ]
    })
  end

  defp result(run, context) do
    if result_card?(run) do
      options = artifact_options(run, context)
      document = run.result |> decode() |> Redactor.document(context.secrets)
      ended = run.remote_stopped_at || run.updated_at

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
              "Retention removed the model's response on #{timestamp(run.pruned_at)}. " <>
                "What it cost and how long it took stay recorded."
            end,
          sections: [section("response", "Model response", run.result, options)],
          background: %{
            headline: headline(run, document),
            reason: present(document["what_went_wrong"]),
            facts: facts(run, document)
          },
          identity: identity(run, context)
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

  # An attempt still waiting on its model has only its briefing.
  defp result_card?(%{status: :prepared, remote_stopped_at: nil}), do: false
  defp result_card?(_run), do: true

  defp headline(%AnalysisRun{status: :applied}, document) do
    case category(document) do
      nil -> "Self-analysis"
      category -> Improvement.category_label(category)
    end
  end

  defp headline(%AnalysisRun{status: :responded}, _document), do: "Ryker is checking the answer"
  defp headline(_run, _document), do: "No usable answer"

  # What the analysis found, in the words the What to fix page uses, and how
  # sure it was; an attempt Ryker could not use says why instead.
  defp facts(%AnalysisRun{status: status} = run, document)
       when status in [:applied, :responded] do
    [
      category_fact(category(document)),
      step_fact(document["step"]),
      present(document["expected"]) && %{label: "Should have", value: document["expected"]},
      confidence_fact(document["confidence"]),
      status == :applied &&
        %{label: "What to fix", value: "Open the finding", href: finding_path(run)}
    ]
    |> Enum.filter(&is_map/1)
  end

  defp facts(%AnalysisRun{status: :rejected, result_sha256: digest}, _document)
       when is_binary(digest),
       do: [
         %{
           label: "Outcome",
           value: "Not used",
           note: "the answer did not match the format asked for"
         }
       ]

  defp facts(%AnalysisRun{status: :rejected}, _document),
    do: [
      %{label: "Outcome", value: "No answer", note: "the attempt ended before the model answered"}
    ]

  defp facts(%AnalysisRun{status: :stale}, _document),
    do: [%{label: "Outcome", value: "Never started"}]

  defp facts(_run, _document), do: []

  defp finding_path(run) do
    Paths.query(ImprovementPage.path(), %{"candidate" => run.candidate_id}) <>
      "#improvement-" <> run.candidate_id
  end

  defp category(%{"category" => value}) when is_binary(value),
    do: Enum.find(Candidate.categories(), &(Atom.to_string(&1) == value))

  defp category(_document), do: nil

  defp category_fact(nil), do: nil

  defp category_fact(category),
    do: %{
      label: "Finding",
      value: Improvement.category_label(category),
      note: ImprovementPage.category_hint(category)
    }

  defp step_fact(step) when step in ["routing", "work", "delivery"],
    do: %{label: "Went wrong at", value: String.capitalize(step)}

  defp step_fact(_step), do: nil

  defp confidence_fact(confidence) when confidence in ["high", "medium", "low"],
    do: %{label: "Confidence", value: String.capitalize(confidence)}

  defp confidence_fact(_confidence), do: nil

  # The exact identities behind the card, for a reader checking the record.
  defp identity(run, context) do
    session = context.sessions[run.id]

    record =
      %{
        "validation_receipt" => run.validation_receipt,
        "stop_receipt" => run.stop_receipt,
        "error_code" => run.error_code
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      facts:
        Enum.reject(
          [
            identifier("Attempt", run.id),
            identifier("Worker session", session && session.coop_session_id),
            identifier("Worker run", run.coop_turn_id),
            identifier("Prompt fingerprint", run.prompt_sha256),
            identifier("Response fingerprint", run.result_sha256),
            identifier("Diagnostic code", run.error_code),
            time("Prepared", run.inserted_at),
            time("Started", run.started_at),
            time("Worker's run confirmed stopped", run.remote_stopped_at),
            time("Prompt and response removed", run.pruned_at)
          ],
          &is_nil/1
        ),
      link: %{href: finding_path(run), label: "The finding on What to fix"},
      record: if(record != %{}, do: record_text(record, context.secrets)),
      record_label: "Validation and stop receipts (JSON)"
    }
  end

  defp section(id, title, value, options),
    do: BackgroundCards.section(id, title, value, :improvement, options)
end
