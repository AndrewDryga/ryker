defmodule Ryker.ControlPlane.CompletionReviews do
  @moduledoc "Frozen completion judgments alongside the Work calls they reviewed."
  alias Ryker.Accounting
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, Paths}
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

    Enum.flat_map(runs, &cards(&1, turns[&1.turn_id], executions[&1.id], context))
  end

  defp cards(run, turn, execution, context) do
    options = BackgroundCards.artifact_options(run, context)

    base = %{
      kind: :request,
      source_kind: :completion_review,
      band: :work,
      owner: :episode,
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
        sections: [
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
          background: decision(section.artifact),
          sections: [section]
        })

      [submitted, result]
    else
      [submitted]
    end
  end

  # Read the redacted artifact, never unredacted model text into visible facts.
  defp decision(%{state: :retained, text: text}) do
    case Work.CompletionReview.Prompt.parse(text) do
      {:ok, %{"decision" => choice, "reason" => reason, "actions" => actions}} ->
        %{
          headline: decision_label(choice),
          reason: reason,
          facts:
            Enum.map(actions, fn action ->
              %{label: "Next step", value: action["action"], note: action["basis"]}
            end)
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
