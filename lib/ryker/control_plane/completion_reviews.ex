defmodule Ryker.ControlPlane.CompletionReviews do
  @moduledoc "Frozen completion judgments alongside the Work calls they reviewed."
  alias Ryker.Accounting
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, Paths}
  alias Ryker.PromptDocument
  alias Ryker.Repo
  alias Ryker.Work

  @doc "Review prompts, decisions and metered cost for the displayed Work turns."
  def entries(turns, options) do
    runs =
      turns |> Enum.map(& &1.id) |> Work.CompletionReview.Run.Query.by_turn_ids() |> Repo.all()

    executions =
      "completion_review"
      |> Accounting.Execution.Query.by_sources(Enum.map(runs, & &1.id))
      |> Repo.all()
      |> Map.new(&{&1.source_id, &1})

    turns = Map.new(turns, &{&1.id, &1})

    context = %{
      secrets: Keyword.get(options, :secrets, []),
      disclosed: Keyword.get(options, :disclosed)
    }

    Enum.flat_map(runs, fn run ->
      previous =
        Enum.find(runs, &(&1.turn_id == run.turn_id && &1.generation == run.generation - 1))

      cards(run, turns[run.turn_id], executions[run.id], Map.put(context, :previous, previous))
    end)
  end

  defp cards(run, turn, execution, context) do
    options = BackgroundCards.artifact_options(run, context)
    prompt = PromptDocument.decode(run.prompt)

    base = %{
      kind: :request,
      source_kind: :completion_review,
      band: :work,
      owner: {:turn, turn.id},
      title: "Completion review",
      target: BackgroundCards.target(run, execution),
      status: run.status,
      policy: run.policy,
      policy_digest: run.policy_digest,
      generation: run.generation,
      generations: run.generation,
      counts: %{},
      href: Paths.request(turn.episode_id) <> "#request-#{turn.id}",
      retention_note:
        if(run.pruned_at,
          do: "Retention removed this review's prompt and response. Its receipts and cost remain."
        )
    }

    submitted =
      Map.merge(base, %{
        id: "completion-review-#{run.id}",
        phase: :submission,
        at: run.inserted_at,
        sort_at: run.inserted_at,
        retried_after: previous_attempt(context.previous, options),
        sections: [
          BackgroundCards.section(
            "instructions",
            "Review instructions",
            prompt["instructions"],
            :completion_review,
            options
          ),
          BackgroundCards.section(
            "context",
            "Frozen review evidence",
            prompt["snapshot"],
            :completion_review,
            options
          ),
          BackgroundCards.submitted(
            run.prompt,
            "completion-review-#{run.id}-request",
            :completion_review,
            context,
            options
          ),
          BackgroundCards.section(
            "contract",
            "Required output contract",
            run.output_schema,
            :completion_review,
            options
          )
        ]
      })

    if BackgroundCards.result?(run) do
      section =
        BackgroundCards.section(
          "response",
          "Completion decision and next actions",
          run.result,
          :completion_review,
          options
        )

      result =
        Map.merge(base, %{
          id: "completion-review-#{run.id}-result",
          phase: :result,
          at: run.remote_stopped_at || run.updated_at,
          sort_at: run.remote_stopped_at || run.updated_at,
          run: Map.put(CallRun.from_background(run, execution), :checks, nil),
          background: outcome(run, section.artifact),
          sections: [section]
        })

      [submitted, result]
    else
      [submitted]
    end
  end

  defp previous_attempt(nil, _options), do: nil

  defp previous_attempt(run, options) do
    section =
      BackgroundCards.section(
        "response",
        "Earlier judgment",
        run.result,
        :completion_review,
        options
      )

    previous = outcome(run, section.artifact)
    failed? = run.status == :rejected and not previous[:model_reason?]

    %{
      generation: run.generation,
      href: "#completion-review-#{run.id}-result",
      lead: if(failed?, do: "Retried after", else: "Reviewed again after"),
      transition: previous_transition(run, previous),
      summary: previous[:reason] || "No usable decision or reason was retained."
    }
  end

  defp previous_transition(%{error_code: "completion_review_stale"}, _previous),
    do: "was superseded"

  defp previous_transition(%{error_code: "completion_review_parent_stopped"}, _previous),
    do: "was cancelled"

  defp previous_transition(%{status: :rejected}, _previous), do: "failed"
  defp previous_transition(%{status: :stale}, _previous), do: "was superseded"
  defp previous_transition(_run, %{headline: "Keep working"}), do: "requested more work"
  defp previous_transition(_run, %{headline: "A person is needed"}), do: "required human input"

  defp previous_transition(_run, %{headline: "Wait for the required event"}),
    do: "required an event wait"

  defp previous_transition(_run, _previous),
    do: "reviewed an earlier candidate or evidence snapshot"

  defp outcome(%{error_code: "completion_review_stale"}, _artifact),
    do: %{
      headline: "Completion review superseded",
      reason: stale_reason(),
      facts: [],
      model_reason?: false
    }

  defp outcome(%{error_code: "completion_review_parent_stopped"} = run, _artifact),
    do: %{
      headline: "Completion review cancelled",
      reason: failure_reason(run),
      facts: [],
      model_reason?: false
    }

  defp outcome(%{status: :rejected, error_code: nil}, _artifact),
    do: %{
      headline: "Completion review failed",
      reason: "No usable completion decision was produced. Its failure reason was not recorded.",
      facts: [],
      model_reason?: false
    }

  defp outcome(%{error_code: code} = run, _artifact) when is_binary(code),
    do: %{
      headline:
        if(run.status == :stale,
          do: "Completion review superseded",
          else: "Completion review failed"
        ),
      reason: failure_reason(run),
      facts: [],
      model_reason?: false
    }

  defp outcome(_run, artifact), do: decision(artifact)

  defp failure_reason(%{status: :stale}), do: stale_reason()

  defp failure_reason(%{error_code: "completion_review_parent_stopped"}) do
    "The parent work stopped or moved to another turn before this review could be used. No completion decision was applied."
  end

  defp failure_reason(%{error_code: "invalid_completion_review"}) do
    "The reviewer returned an unusable answer. No completion decision was produced, so this review could not authorize a reply."
  end

  defp failure_reason(%{error_code: "completion_review_execution_timeout"}) do
    "The completion review exceeded its time limit. No completion decision was produced, so this review could not authorize a reply."
  end

  defp failure_reason(run) do
    receipt =
      if is_map(run.stop_receipt),
        do: run.stop_receipt,
        else: PromptDocument.decode(run.stop_receipt)

    cause =
      case receipt["error_code"] do
        "acp_protocol_error" ->
          "The worker reported a protocol error before the reviewer could finish."

        "output_contract_failed" ->
          "The reviewer's answer did not pass its response-format checks."

        _ ->
          "The completion reviewer stopped without a usable answer."
      end

    cause <> " No completion decision was produced, so this review could not authorize a reply."
  end

  defp stale_reason do
    "The candidate or its evidence changed before this review could be used. No completion decision was applied."
  end

  # Read the redacted artifact, never unredacted model text into visible facts.
  defp decision(%{state: :retained, text: text}) do
    case Work.CompletionReview.Prompt.parse(text) do
      {:ok,
       %{
         "decision" => choice,
         "reason" => reason,
         "actions" => actions,
         "requirements" => requirements
       }} ->
        %{
          headline: decision_label(choice),
          reason: reason,
          model_reason?: true,
          facts: [],
          requirements:
            Enum.map(
              requirements,
              &%{title: &1["requirement"], text: &1["evidence"], status: &1["status"]}
            ),
          actions:
            Enum.map(actions, &%{title: &1["requirement"], text: &1["action"], note: &1["basis"]})
        }

      _invalid ->
        %{headline: "Completion review unavailable", reason: nil, facts: []}
    end
  end

  defp decision(_artifact), do: %{headline: "Completion review", reason: nil, facts: []}
  defp decision_label("complete"), do: "Completion confirmed"
  defp decision_label("continue"), do: "Keep working"
  defp decision_label("wait_for_event"), do: "Wait for the required event"
  defp decision_label("request_input"), do: "A person is needed"
  defp decision_label(_choice), do: "Completion review unavailable"
end
