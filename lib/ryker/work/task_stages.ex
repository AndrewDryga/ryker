defmodule Ryker.Work.TaskStages do
  @moduledoc """
  One stable seven-stage lifecycle for a code task, built from host receipts.

  Stages never disappear: waiting, failure, stopping, skipping and an
  unrecorded history change a stage's disposition, not the list. Workspace
  setup, Draft PR, CI and Review and merge come from session, publication and
  follow-up receipts; Planning, Implementation and Self-review come from the
  model's typed goal membership. Goals retained before typed membership existed
  stay in a separate unassigned row rather than being backfilled into a guess.
  """

  alias Ryker.Episodes.Episode
  alias Ryker.Publication.{Followup, Publication, Review}
  alias Ryker.Work.{FailureCause, Session, Turn}

  @stages ~w(workspace_setup planning implementation self_review draft_pr ci review_and_merge)
  @publication_conflicts ~w(publication_branch_already_exists publication_branch_changed publication_existing_pull_request_changed publication_pull_request_mismatch)
  @terminal_goal_states ~w(completed excluded cancelled)
  @current_states ~w(running waiting failed)
  @published_statuses [:published, :published_ready]
  @no_checks "no checks set up"
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

    [
      workspace,
      planning,
      implementation,
      self_review,
      draft_pr,
      ci,
      review_and_merge(facts, ci, stale?)
    ]
    |> open_stage_at_work(facts)
    |> mark_current()
  end

  # While the worker runs and no step says it started, the first stage with open steps is the one
  # at work. Every stage with an unfinished step used to read as running.
  defp open_stage_at_work(rows, %{turn: %Turn{status: :pending}}) do
    if Enum.any?(rows, &(&1["state"] in @current_states)) do
      rows
    else
      case Enum.find_index(rows, &open_plan_stage?/1) do
        nil -> rows
        index -> List.update_at(rows, index, &%{&1 | "state" => "running"})
      end
    end
  end

  defp open_stage_at_work(rows, _facts), do: rows

  defp open_plan_stage?(%{"stage" => stage, "state" => "pending", "subtasks" => [_ | _]})
       when stage in ~w(planning implementation self_review),
       do: true

  defp open_plan_stage?(_row), do: false

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

  # A turn the host blocked before any worker turn was bound never started, and
  # its saved error is an inspected internal term: the enum, the tuple and the
  # identifiers in it are bookkeeping, not an explanation. Printing it put
  # `{:work_retry_exhausted, {:coop_operation_failed, …}}` on an operator's card.
  defp workspace_setup(%{turn: %Turn{status: :blocked, coop_turn_id: nil} = turn}),
    do:
      row("workspace_setup", "failed",
        detail: "work never started",
        reason: never_started(turn.last_error_detail)
      )

  defp workspace_setup(%{episode: %Episode{state: :cancelled}}),
    do: row("workspace_setup", "stopped")

  defp workspace_setup(_facts),
    do: row("workspace_setup", "waiting", detail: "waiting for a worker")

  defp never_started(detail) do
    case FailureCause.explain(detail) do
      %{cause: cause} -> cause
      nil -> nil
    end
  end

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
  #
  # A repository with no checks at all is neither: nothing failed, the same as
  # a pull request whose CI has none, and the two rows say so alike (Andrew,
  # 2026-09-28: "! Self-review and checks" beside "− CI · no checks
  # configured" for the same case).
  defp review_row(%{publication: %Publication{review_document: review}}, bucket) do
    cond do
      Review.no_checks?(review) ->
        row("self_review", "skipped", [detail: @no_checks] ++ subtasks(bucket))

      Review.gate_failure(review) ->
        row("self_review", "failed", [reason: gate_detail(review)] ++ subtasks(bucket))

      reason = incomplete_check(review) ->
        row("self_review", "failed", [reason: reason] ++ subtasks(bucket))

      true ->
        row("self_review", "completed", subtasks(bucket))
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

  # Someone changed the branch or pull request on GitHub while Ryker published, and it stopped
  # rather than overwrite their work. The row said "creating the draft" (manual test, 2026-10-01).
  defp draft_pr(
         %{
           publication:
             %Publication{status: :publish_pending, last_error_code: code} = publication
         },
         _stale?
       )
       when code in @publication_conflicts do
    detail =
      case publication.pull_request_number do
        number when is_integer(number) -> "##{number} · changed on GitHub"
        nil -> "changed on GitHub"
      end

    row("draft_pr", "stopped", detail: detail, url: publication.pull_request_url)
  end

  defp draft_pr(
         %{
           publication:
             %Publication{status: :publish_pending, pull_request_number: number} = publication
         },
         _stale?
       )
       when is_integer(number),
       do:
         row("draft_pr", "running",
           detail: "##{number} · updating",
           url: publication.pull_request_url
         )

  defp draft_pr(%{publication: %Publication{status: :publish_pending}}, _stale?),
    do: row("draft_pr", "running", detail: "creating the draft")

  # A safe snapshot whose checks could not run waits for a person only when no
  # task grant covers it; a granted one goes to the draft marked unverified. The
  # pull request a newer change belongs to is still the task's, so the row
  # keeps its number and link.
  defp draft_pr(%{publication: %Publication{status: :blocked} = publication}, _stale?) do
    cond do
      is_binary(publication.last_error_detail) ->
        row("draft_pr", "failed", reason: publication.last_error_detail)

      Review.draft_shareable?(publication.review_document) and
          is_integer(publication.pull_request_number) ->
        row("draft_pr", "waiting",
          detail: "##{publication.pull_request_number} · the newer change waits for you",
          url: publication.pull_request_url,
          your_turn: true
        )

      Review.draft_shareable?(publication.review_document) ->
        row("draft_pr", "waiting", detail: "waits for you", your_turn: true)

      # Why the pull request cannot be made is said once, on the publication
      # line above its buttons.
      true ->
        row("draft_pr", "failed")
    end
  end

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
    # "CI · 6/6" is a row a person wants to open, and the followup has stored
    # the run's own URL since it first polled GitHub.
    url = facts.followup && facts.followup.checks_url

    if stale? do
      row("ci", "stale",
        detail: [checks, "on the published revision"] |> compact_join(),
        url: url
      )
    else
      ci_state(facts.followup, checks, url)
    end
  end

  defp ci(_facts, _stale?), do: row("ci", "pending")

  defp ci_state(nil, _checks, _url), do: row("ci", "waiting", detail: "waiting for GitHub")

  defp ci_state(%Followup{checks_state: "unknown"}, _checks, _url),
    do: row("ci", "waiting", detail: "waiting for GitHub")

  defp ci_state(%Followup{pr_state: "merged"}, checks, url),
    do: row("ci", "completed", detail: checks, url: url)

  defp ci_state(%Followup{checks_state: "none"}, _checks, _url),
    do: row("ci", "skipped", detail: @no_checks)

  defp ci_state(%Followup{checks_state: "failing"}, checks, url),
    do: row("ci", "failed", detail: checks, url: url)

  defp ci_state(%Followup{checks_state: "passing"}, checks, url),
    do: row("ci", "completed", detail: checks, url: url)

  defp ci_state(%Followup{}, checks, url), do: row("ci", "running", detail: checks, url: url)

  defp review_and_merge(%{followup: %Followup{pr_state: "merged"}} = facts, _ci, _stale?),
    do:
      row("review_and_merge", "completed",
        detail: "merged",
        url: publication_url(facts[:publication])
      )

  defp review_and_merge(%{followup: %Followup{pr_state: "closed"}} = facts, _ci, _stale?),
    do:
      row("review_and_merge", "stopped",
        detail: "closed without merging",
        url: publication_url(facts[:publication])
      )

  # Ryker stops following a pull request at its hard deadline, so what became
  # of it is unknown here; the row said "your turn" over a state nobody was
  # checking (2026-10-04 review).
  defp review_and_merge(%{followup: %Followup{pr_state: "expired"}} = facts, _ci, _stale?),
    do:
      row("review_and_merge", "unknown",
        detail: "no longer followed",
        url: publication_url(facts[:publication])
      )

  defp review_and_merge(%{publication: %Publication{status: status} = publication}, ci, stale?)
       when status in @published_statuses do
    # A person reviews and merges once the draft reflects the current work and
    # its checks have settled; while the agent still owns a failing or
    # unpublished change, or a required check never ran at all, this is not their
    # turn yet. A draft opened on an unrun gate used to land here as "🙋 your
    # turn", which reads as work that stood through its checks.
    if not stale? and ci["state"] in ~w(completed skipped) and
         is_nil(incomplete_check(publication.review_document)),
       do: row("review_and_merge", "waiting", your_turn: true, url: publication.pull_request_url),
       else: row("review_and_merge", "pending", url: publication.pull_request_url)
  end

  defp review_and_merge(_facts, _ci, _stale?), do: row("review_and_merge", "pending")

  defp publication_url(%Publication{pull_request_url: url}), do: url
  defp publication_url(_publication), do: nil

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

  # A stage runs when one of its steps does; one whose steps have not begun has not either.
  defp goal_state(goals, _facts) do
    cond do
      Enum.any?(goals, &(&1["state"] == "working")) -> "running"
      Enum.any?(goals, &(&1["state"] == "waiting")) -> "waiting"
      Enum.any?(goals, &(&1["state"] == "blocked")) -> "failed"
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
  # A stage waiting on a person or stopped needs attention first; otherwise the current stage is
  # the furthest one at work. A model that starts implementing before it closes its planning step
  # left the card reading "Planning" while files were being edited (Andrew, 2026-10-01).
  defp mark_current(rows) do
    current =
      Enum.find(rows, &(&1["state"] in ["waiting", "failed"])) ||
        rows |> Enum.filter(&(&1["state"] == "running")) |> List.last()

    Enum.map(rows, fn
      ^current -> current |> Map.put("current", true) |> mark_current_subtask()
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

  # The card's publication line already says the checks failed; this row adds
  # only what the checks said, when they said anything.
  defp gate_detail(review), do: if(Review.gate_error?(review), do: Review.gate_failure(review))

  # The one required check this review has no result for, in the same words the
  # publication card uses, or nil when every required check has an answer.
  defp incomplete_check(review) do
    case Review.draft_verdict(review) do
      %{"incomplete_checks" => [reason | _rest]} -> compact(reason, 200)
      _decided -> nil
    end
  end

  defp bucket(%{plan: plan}, stage), do: Map.fetch!(plan, stage)

  defp planned?(%{plan: plan}),
    do: Enum.any?(plan, fn {_stage, bucket} -> bucket["goals"] != [] end)

  defp unrecorded?(%{episode: %Episode{state: :complete}} = facts), do: not planned?(facts)
  defp unrecorded?(_facts), do: false

  defp checks_detail(%Followup{checks_total: total, checks_passed: passed}) when total > 0,
    do: "#{passed}/#{total}"

  defp checks_detail(_followup), do: nil

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

  # A detail is a short fact read on the stage's own line ("2/2 subtasks",
  # "#617"); a reason is the sentence saying why it failed, which Andrew
  # (2026-09-28) wanted on a line of its own instead of blending into the row.
  defp row(stage, state, options \\ []) do
    %{
      "current" => false,
      "detail" => compact(options[:detail], 200),
      "reason" => compact(options[:reason], 500),
      "stage" => stage,
      "state" => state,
      "subtasks" => options[:subtasks] || [],
      "subtasks_total" => options[:subtasks_total],
      "url" => options[:url],
      "your_turn" => options[:your_turn] || false
    }
  end
end
