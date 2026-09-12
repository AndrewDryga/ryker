defmodule Responder.Work.TaskStages do
  @moduledoc """
  One stable seven-stage lifecycle for a code task, built from host receipts.

  Stages never disappear: waiting, failure, stopping, skipping and an
  unrecorded history change a stage's disposition, not the list. Workspace
  setup, Draft PR, CI and Review and merge come from session, publication and
  follow-up receipts; Planning, Implementation and Self-review come from the
  model's typed goal membership. Goals retained before typed membership existed
  stay in a separate unassigned row rather than being backfilled into a guess.
  """

  alias Responder.Episodes.Episode
  alias Responder.Publication.{Followup, Publication, Review}
  alias Responder.Work.{Session, Turn}

  @stages ~w(workspace_setup planning implementation self_review draft_pr ci review_and_merge)
  @terminal_goal_states ~w(completed excluded cancelled)
  @current_states ~w(running waiting failed)
  @published_statuses [:published, :published_ready]
  @maximum_subtasks 6

  @type facts :: %{
          episode: Episode.t(),
          followup: Followup.t() | nil,
          plan: map(),
          publication: Publication.t() | nil,
          publication_offer: map() | nil,
          session: Session.t() | nil,
          turn: Turn.t() | nil,
          workspace_hold: map() | nil
        }

  @doc "The stable stage order, oldest first."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc "The stage list with every disposition withheld."
  @spec unknown() :: [map()]
  def unknown, do: Enum.map(@stages, &row(&1, "unknown"))

  @spec build(facts()) :: [map()]
  def build(facts) do
    stale? = stale_work?(facts)
    workspace = workspace_setup(facts)
    planning = planning(facts, workspace)
    implementation = implementation(facts, planning)
    self_review = self_review(facts, stale?)
    draft_pr = draft_pr(facts, stale?)
    ci = ci(facts, stale?)

    ([
       workspace,
       planning,
       implementation,
       self_review,
       draft_pr,
       ci,
       review_and_merge(facts, ci, stale?)
     ] ++ unassigned(facts))
    |> mark_current()
  end

  # Setting the workspace up is also keeping it: a working copy the host never
  # snapshotted is this stage's failure, and saying "✓ Workspace setup" above it
  # told a reader the one thing that was not true.
  defp workspace_setup(%{workspace_hold: %{closed: closed?}}),
    do:
      row("workspace_setup", "failed",
        detail: if(closed?, do: "no saved snapshot · session closed", else: "no saved snapshot")
      )

  defp workspace_setup(%{session: %Session{coop_session_id: id}}) when is_binary(id) and id != "",
    do: row("workspace_setup", "completed")

  defp workspace_setup(%{turn: %Turn{status: :blocked, coop_turn_id: nil} = turn}),
    do: row("workspace_setup", "failed", detail: turn.last_error_detail)

  defp workspace_setup(%{episode: %Episode{state: :cancelled}}),
    do: row("workspace_setup", "stopped")

  defp workspace_setup(_facts),
    do: row("workspace_setup", "waiting", detail: "waiting for a worker")

  defp planning(facts, workspace) do
    bucket = bucket(facts, "planning")

    cond do
      bucket["goals"] != [] -> model_row("planning", facts, bucket)
      planned?(facts) -> row("planning", "completed")
      not workspace_reached?(facts, workspace) -> row("planning", "pending")
      unrecorded?(facts) -> row("planning", "unknown", detail: "not recorded")
      facts.episode.state == :cancelled -> row("planning", "stopped")
      true -> row("planning", "running")
    end
  end

  # A workspace the host later failed to keep was still reached: the worker ran
  # in it and answered. Only a workspace that never existed means planning has
  # not begun, so a held snapshot must not roll the later stages back to "○".
  defp workspace_reached?(_facts, %{"state" => "completed"}), do: true
  defp workspace_reached?(%{workspace_hold: hold}, _workspace), do: not is_nil(hold)

  defp implementation(facts, %{"state" => planning_state}) do
    bucket = bucket(facts, "implementation")

    cond do
      bucket["goals"] != [] -> model_row("implementation", facts, bucket, count: true)
      planning_state == "pending" -> row("implementation", "pending")
      unrecorded?(facts) -> row("implementation", "unknown", detail: "not recorded")
      true -> row("implementation", "pending")
    end
  end

  defp self_review(facts, stale?) do
    base = review_row(facts, bucket(facts, "self_review"))

    if stale? and base["state"] == "completed",
      do: %{base | "detail" => "previous version checked", "state" => "stale"},
      else: base
  end

  # The host owns whether the changes were checked. Its readiness review, or a
  # completed result whose review never started, outranks the model's own
  # review goals; only without either does the plan describe this stage.
  defp review_row(%{publication: %Publication{status: status}}, bucket)
       when status in [:review_pending, :review_ready],
       do: row("self_review", "running", subtasks(bucket))

  # A draft a person opened because the gate could not run is not a checked
  # change, and neither is one whose gate ran and failed. Marking this stage
  # complete for either said the opposite on the one card whose whole job is to
  # say whether the change was checked.
  defp review_row(%{publication: %Publication{review_document: review}}, bucket) do
    case Review.gate_failure(review) || incomplete_check(review) do
      nil -> row("self_review", "completed", subtasks(bucket))
      reason -> row("self_review", "failed", [detail: reason] ++ subtasks(bucket))
    end
  end

  defp review_row(%{publication_offer: %{"status" => "open"}}, bucket),
    do: row("self_review", "failed", [detail: "checks have not started"] ++ subtasks(bucket))

  defp review_row(facts, bucket) do
    cond do
      bucket["goals"] != [] -> model_row("self_review", facts, bucket)
      unrecorded?(facts) -> row("self_review", "unknown", detail: "not recorded")
      true -> row("self_review", "pending")
    end
  end

  defp draft_pr(%{publication: %Publication{status: status} = publication} = facts, stale?)
       when status in @published_statuses do
    detail = "##{publication.pull_request_number}"

    # An existing pull request stays reachable when its worker's later work was
    # stranded — but it is the earlier snapshot, and saying only "✓ #91" would
    # offer it as the current state of the change.
    cond do
      facts.workspace_hold ->
        row("draft_pr", "stale",
          detail: "#{detail} · earlier snapshot, newer work not saved",
          url: publication.pull_request_url
        )

      stale? ->
        row("draft_pr", "stale",
          detail: "#{detail} · newer changes not published",
          url: publication.pull_request_url
        )

      true ->
        row("draft_pr", "completed", detail: detail, url: publication.pull_request_url)
    end
  end

  defp draft_pr(%{publication: %Publication{status: :publish_pending}}, _stale?),
    do: row("draft_pr", "running", detail: "creating the draft")

  defp draft_pr(%{publication: %Publication{status: :blocked} = publication}, _stale?),
    do: row("draft_pr", "failed", detail: publication.last_error_detail)

  defp draft_pr(%{publication: %Publication{status: :reviewed}}, _stale?),
    do: row("draft_pr", "waiting", detail: "the reviewed candidate is ready to publish")

  defp draft_pr(%{publication: %Publication{status: :discarded}}, _stale?),
    do: row("draft_pr", "skipped", detail: "candidate discarded")

  defp draft_pr(%{publication: %Publication{}}, _stale?), do: row("draft_pr", "pending")

  defp draft_pr(%{publication_offer: %{"status" => "open"}}, _stale?),
    do: row("draft_pr", "pending")

  defp draft_pr(facts, _stale?) do
    if unrecorded?(facts),
      do: row("draft_pr", "unknown", detail: "not recorded"),
      else: row("draft_pr", "pending")
  end

  defp ci(%{publication: %Publication{status: status}} = facts, stale?)
       when status in @published_statuses do
    checks = checks_detail(facts.followup)

    cond do
      stale? ->
        row("ci", "stale", detail: [checks, "on the published revision"] |> compact_join())

      is_nil(facts.followup) or facts.followup.checks_state == "unknown" ->
        row("ci", "waiting", detail: "waiting for GitHub")

      facts.followup.pr_state == "merged" ->
        row("ci", "completed", detail: checks)

      facts.followup.checks_state == "none" ->
        row("ci", "skipped", detail: "no checks configured")

      facts.followup.checks_state == "failing" ->
        row("ci", "failed", detail: checks)

      facts.followup.checks_state == "passing" ->
        row("ci", "completed", detail: checks)

      true ->
        row("ci", "running", detail: checks)
    end
  end

  defp ci(_facts, _stale?), do: row("ci", "pending")

  defp review_and_merge(%{followup: %Followup{pr_state: "merged"}}, _ci, _stale?),
    do: row("review_and_merge", "completed", detail: "merged")

  defp review_and_merge(%{followup: %Followup{pr_state: "closed"}}, _ci, _stale?),
    do: row("review_and_merge", "stopped", detail: "closed without merging")

  defp review_and_merge(%{publication: %Publication{status: status} = publication}, ci, stale?)
       when status in @published_statuses do
    # A person reviews and merges once the draft reflects the current work and
    # its checks have settled; while the agent still owns a failing or
    # unpublished change, or a required check never ran at all, this is not their
    # turn yet. A draft opened on an unrun gate used to land here as "🙋 your
    # turn", which reads as work that stood through its checks.
    if not stale? and ci["state"] in ~w(completed skipped) and
         is_nil(incomplete_check(publication.review_document)),
       do: row("review_and_merge", "waiting", your_turn: true),
       else: row("review_and_merge", "pending")
  end

  defp review_and_merge(_facts, _ci, _stale?), do: row("review_and_merge", "pending")

  defp unassigned(facts) do
    bucket = bucket(facts, "unassigned")
    count = length(bucket["leaves"])

    case bucket["goals"] do
      [] ->
        []

      _goals ->
        [
          row(
            "unassigned",
            "unknown",
            [detail: "#{count} #{pluralize(count, "subtask")} recorded without a stage"] ++
              subtasks(bucket)
          )
        ]
    end
  end

  defp model_row(stage, facts, bucket, options \\ []) do
    state = model_state(facts, bucket)
    detail = if options[:count], do: subtask_count(bucket)

    row(
      stage,
      state,
      [detail: detail, your_turn: your_turn?(state, facts)] ++ subtasks(bucket)
    )
  end

  # Only a person's decision is their turn. An external verification wait is
  # the system's, and must not imply somebody is holding the task up.
  defp your_turn?("waiting", %{episode: %Episode{state: :waiting_for_input}}), do: true
  defp your_turn?(_state, _facts), do: false

  # Finished work stays finished even when the episode later stops or blocks;
  # otherwise the run's own disposition describes the stage, and only then do
  # its goals.
  defp model_state(facts, bucket) do
    goals = bucket["leaves"]

    if Enum.all?(goals, &(&1["state"] in @terminal_goal_states)),
      do: "completed",
      else: run_state(facts) || goal_state(goals, facts)
  end

  defp run_state(%{episode: %Episode{state: :cancelled}}), do: "stopped"
  defp run_state(%{turn: %Turn{status: :blocked}}), do: "failed"

  defp run_state(%{episode: %Episode{state: state}})
       when state in [:waiting_for_input, :waiting_for_event],
       do: "waiting"

  defp run_state(_facts), do: nil

  defp goal_state(goals, facts) do
    cond do
      Enum.any?(goals, &(&1["state"] == "working")) -> "running"
      Enum.any?(goals, &(&1["state"] == "waiting")) -> "waiting"
      Enum.any?(goals, &(&1["state"] == "blocked")) -> "failed"
      match?(%Turn{status: :pending}, facts.turn) -> "running"
      true -> "pending"
    end
  end

  defp subtask_count(%{"completed" => completed, "excluded" => excluded, "total" => total}) do
    ["#{completed}/#{total} subtasks", if(excluded > 0, do: "#{excluded} excluded")]
    |> compact_join(" · ")
  end

  # A small plan shows every subtask in plan order. A large one prioritizes the
  # work a reader can act on and says how many it is showing.
  defp subtasks(%{"leaves" => leaves}) do
    shown =
      if length(leaves) <= @maximum_subtasks,
        do: leaves,
        else: leaves |> Enum.sort_by(&subtask_priority/1) |> Enum.take(@maximum_subtasks)

    [
      subtasks:
        Enum.map(shown, fn goal ->
          %{
            "current" => false,
            "detail" => compact(goal["detail"], 200),
            "id" => goal["id"],
            "outcome" => compact(goal["requested_outcome"], 250),
            "state" => goal["state"]
          }
        end),
      subtasks_total: length(leaves)
    ]
  end

  defp subtask_priority(%{"state" => state}) do
    case state do
      state when state in ~w(working waiting blocked) -> 0
      "ready" -> 1
      _terminal -> 2
    end
  end

  # Subtasks belong under the stage a reader is acting on. A completed stage
  # keeps its name and its count; its items stay in the episode's full history.
  # The unassigned row is the exception: its list is the whole point of the row.
  defp mark_current(rows) do
    current = Enum.find(rows, &(&1["state"] in @current_states))

    Enum.map(rows, fn
      ^current -> current |> Map.put("current", true) |> mark_current_subtask()
      %{"stage" => "unassigned"} = row -> row
      row -> %{row | "subtasks" => [], "subtasks_total" => nil}
    end)
  end

  defp mark_current_subtask(row) do
    current =
      Enum.find(row["subtasks"], &(&1["state"] == "working")) ||
        Enum.find(row["subtasks"], &(&1["state"] == "waiting")) ||
        Enum.find(row["subtasks"], &(&1["state"] == "blocked"))

    %{
      row
      | "subtasks" =>
          Enum.map(row["subtasks"], fn
            ^current -> Map.put(current, "current", true)
            subtask -> subtask
          end)
    }
  end

  # Repeated checks and a published draft describe the revision they ran
  # against. Implementation work recorded after them needs its own attempt.
  defp stale_work?(%{plan: plan, publication: %Publication{} = publication}) do
    anchor = publication.reviewed_at || publication.published_at
    changed = plan["implementation"]["changed_at"]

    not is_nil(anchor) and not is_nil(changed) and DateTime.compare(changed, anchor) == :gt
  end

  defp stale_work?(_facts), do: false

  # The one required check this review has no result for, in the same words the
  # publication card uses, or nil when every required check has an answer.
  defp incomplete_check(review) do
    case Review.draft_verdict(review) do
      %{"incomplete_checks" => [reason | _rest]} -> compact(reason, 200)
      _decided -> nil
    end
  end

  defp bucket(%{plan: plan}, stage), do: Map.fetch!(plan, stage)

  # Goals retained without a stage are not a plan: they cannot say that
  # planning happened, only that something was recorded before stages existed.
  defp planned?(%{plan: plan}),
    do: Enum.any?(plan, fn {stage, bucket} -> stage != "unassigned" and bucket["goals"] != [] end)

  defp unrecorded?(%{episode: %Episode{state: :complete}} = facts), do: not planned?(facts)
  defp unrecorded?(_facts), do: false

  defp checks_detail(%Followup{checks_total: total, checks_passed: passed}) when total > 0,
    do: "#{passed}/#{total}"

  defp checks_detail(_followup), do: nil

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp compact_join(values, separator \\ " "),
    do: values |> Enum.reject(&is_nil/1) |> Enum.join(separator) |> presence()

  defp presence(""), do: nil
  defp presence(value), do: value

  defp compact(nil, _maximum), do: nil

  defp compact(value, maximum) do
    if String.length(value) > maximum,
      do: String.slice(value, 0, maximum - 1) <> "…",
      else: value
  end

  defp row(stage, state, options \\ []) do
    %{
      "current" => false,
      "detail" => compact(options[:detail], 200),
      "stage" => stage,
      "state" => state,
      "subtasks" => options[:subtasks] || [],
      "subtasks_total" => options[:subtasks_total],
      "url" => options[:url],
      "your_turn" => options[:your_turn] || false
    }
  end
end
