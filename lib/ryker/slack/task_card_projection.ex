defmodule Ryker.Slack.TaskCardProjection do
  @moduledoc """
  Builds one bounded, host-owned engineering-task card from canonical state.

  TaskCard projections reauthorize their source context before external Slack
  publication. Record projections are retained operator audit views only.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.GitHub
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.{Permalink, TaskCard, WorkControls}
  alias Ryker.Slack.Renderer.Fields
  alias Ryker.StateTools
  alias Ryker.Wording
  alias Ryker.Work

  @ui_revision 6
  @publication_conflicts ~w(publication_branch_already_exists publication_branch_changed publication_existing_pull_request_changed publication_pull_request_mismatch)
  # Why a refused grant stopped the draft, in words: the card said "needs operator attention:
  # `publication_authorization_revoked`" (2026-09-30). The recovery is on the card itself.
  @refused_grant "Ryker couldn't get permission to publish this reviewed change."
  # The card printed `:publication_existing_pull_request_changed` once a draft was closed on
  # GitHub while Ryker updated it (manual test, 2026-10-01). These are the Failures page's words.
  @changed_on_github "Someone changed this draft's branch or pull request on GitHub, so Ryker stopped to avoid overwriting their work."
  # What an attempt records while Coop is still working on it, or while the next attempt is
  # already due: Ryker's own wait ended before a long review did, the worker has not finished,
  # the session is changing placement, a lost review is being asked again. Each clears by
  # itself, so none is a person's action (Andrew, 2026-09-30: "Action needed: ...
  # coop_worker_command_timeout. again!!").
  @in_flight ~w(coop_worker_command_timeout coop_unavailable coop_session_replacement_pending publication_review_generation_spent)

  @spec build(TaskCard.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(%TaskCard{} = card) do
    # Snapshot and source checks finish before either caller performs Slack I/O.
    # A later withdrawal is handled by the next refresh, not a lock over HTTP.
    case Repo.transaction(fn -> build_public(card) end) do
      {:ok, result} -> result
      error -> error
    end
  end

  @doc false
  @spec build(Records.Record.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(
        %Records.Record{
          kind: "task_offer",
          status: :confirmed,
          confirmed_episode_id: episode_id
        } = record
      )
      when is_binary(episode_id) do
    case Repo.one(Episodes.Episode.Query.by_id(episode_id)) do
      %Episodes.Episode{} = episode -> project(record, episode, record.ref, snapshot(episode))
      nil -> {:error, :task_card_source_not_found}
    end
  end

  def build(_card), do: {:error, :invalid_task_card}

  @doc """
  The task as its own page in the control plane shows it: the card's document
  with the causes the card says only where its sources may be shown, since
  the page is the operator's.
  """
  @spec page(Records.Record.t()) :: {:ok, map()} | {:error, term()}
  def page(
        %Records.Record{kind: "task_offer", status: :confirmed, confirmed_episode_id: episode_id} =
          record
      )
      when is_binary(episode_id) do
    case Repo.one(Episodes.Episode.Query.by_id(episode_id)) do
      %Episodes.Episode{} = episode ->
        snapshot = snapshot(episode)
        {:ok, projection} = project(record, episode, record.ref, snapshot)
        {:ok, public_errors(projection, snapshot)}

      nil ->
        {:error, :task_card_source_not_found}
    end
  end

  def page(_record), do: {:error, :invalid_task_card}

  defp build_public(card) do
    with %Records.Record{} = record <- Repo.one(Records.Record.Query.by_id(card.record_id)),
         %Episodes.Episode{} = episode <- Repo.one(Episodes.Episode.Query.by_id(card.episode_id)) do
      snapshot = snapshot(episode)
      {:ok, projection} = project(record, episode, card.ref, snapshot)

      if public_sources?(card, record, episode, snapshot),
        do: {:ok, public_errors(projection, snapshot)},
        else: {:ok, neutral(projection)}
    else
      nil -> {:error, :task_card_source_not_found}
    end
  end

  defp project(record, episode, task_ref, snapshot) do
    %{
      turn: turn,
      session: session,
      publication: publication,
      records: records,
      publication_offer: publication_offer
    } = snapshot

    progress = Enum.map(snapshot.progress_records, &progress_detail/1)
    fix = snapshot.automatic_fix
    settled? = settled_on_github?(snapshot.followup)
    attention = if fix_line(fix, :fixing) || settled?, do: nil, else: publication
    # A settled pull request leaves no prepared change waiting to be reviewed.
    offer = if settled?, do: nil, else: publication_offer

    projection = %{
      "action_needed" =>
        held_work(snapshot.workspace_hold, publication) || fix_line(fix, :stopped) ||
          action_needed(episode, turn, records, attention) ||
          unstarted_review(episode, publication, offer),
      "controls" =>
        controls(record, episode, turn, session, publication, snapshot.workspace_hold),
      "publication" => publication(publication, snapshot.followup, fix),
      "request" =>
        record.payload["prompt"] |> StateTools.TaskTools.request() |> Fields.cut(12_000),
      "repository" => repository_name(record.payload["repository"]),
      "repository_url" => repository_url(publication),
      "stages" =>
        Work.TaskStages.build(%{
          episode: episode,
          followup: snapshot.followup,
          plan: Records.plan_from_records(snapshot.goal_records),
          publication: publication,
          publication_offer: publication_offer,
          session: session,
          turn: turn,
          workspace_hold: snapshot.workspace_hold
        }),
      "question_url" => question_url(episode),
      "status" => status(episode, turn, attention, offer),
      "summary" => summary(record, progress),
      "task_ref" => task_ref,
      "title" => record.payload["title"],
      "ui_revision" => @ui_revision,
      "updated_at" => DateTime.to_iso8601(updated_at(episode, publication)),
      "resume_ref" => resume_ref(task_ref, turn, snapshot.workspace_hold)
    }

    document = %{"task_card" => projection}

    {:ok,
     %{
       document: document,
       fingerprint: CanonicalJSON.digest(document),
       ui_revision: @ui_revision
     }}
  end

  defp snapshot(episode) do
    publication = latest_publication(episode.id)
    turn = Repo.one(Work.Turn.Query.current(episode))

    %{
      automatic_fix: Publication.FixLoop.progress(publication, episode),
      turn: turn,
      session: Repo.one(Work.Session.Query.latest_of_episode(episode.id)),
      publication: publication,
      followup: followup(publication),
      records: Records.retained_records(episode.id),
      publication_offer: latest_publication_offer(episode.id),
      goal_records: Records.goal_records(episode.id),
      progress_records: progress_records(episode.id),
      workspace_hold: Work.Recovery.workspace_hold(turn)
    }
  end

  defp followup(nil), do: nil

  defp followup(%Publication.Publication{id: id}),
    do: Repo.one(Publication.Followup.Query.by_publication_id(id))

  # What the person asked for, as the task offer wrote it: the card showed
  # "Sources: slack-source:v1:…" once it stopped cutting the request at 600
  # characters (2026-09-28).

  # A repository by the name people know it by, owner/repo, from the
  # repository Ryker added; one no longer added keeps the name the task
  # recorded (Andrew, 2026-09-28: "why repo name is andrewdryga-emisar while
  # it's andrewdryga/emisar?").
  defp repository_name(ref) when is_binary(ref) do
    github_repository =
      ref
      |> Settings.Repository.Query.by_ref()
      |> Settings.Repository.Query.select_github_repositories()
      |> Repo.one()

    github_repository || ref
  end

  defp repository_name(ref), do: ref

  # A repository links out only from the trusted GitHub binding its own
  # publication receipt recorded; a display label never becomes a URL.
  defp repository_url(%Publication.Publication{github_repository: repository})
       when is_binary(repository),
       do: GitHub.repository_url(repository)

  defp repository_url(_publication), do: nil

  defp progress_records(episode_id) do
    episode_id
    |> Records.Record.Query.by_episode_id()
    |> Records.Record.Query.by_kind("progress")
    |> Records.Record.Query.in_use()
    |> Records.Record.Query.not_feedback_progress()
    |> Records.Record.Query.ordered_by_sequence_desc()
    |> Records.Record.Query.limit_to(4)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp progress_detail(record) do
    %{
      "phase" => Fields.cut(record.payload["phase"], 60),
      "summary" => Fields.cut(record.payload["summary"], 600),
      "at" => DateTime.to_iso8601(record.inserted_at)
    }
  end

  defp public_sources?(card, record, episode, snapshot) do
    with true <- record.confirmed_episode_id == episode.id,
         true <- same_destination?(card, episode),
         {:ok, source_episode, source_session} <- offer_owner(record),
         true <- same_destination?(card, source_episode),
         {:ok, _} <-
           Records.DerivedContext.resolve(
             [Records.DerivedContext.record(Records.Record.document(record))],
             source_episode,
             source_session.repository_ref
           ),
         %Work.Session{} = session <- snapshot.session,
         {:ok, _} <-
           Records.DerivedContext.resolve(
             snapshot_documents(snapshot),
             episode,
             session.repository_ref
           ) do
      true
    else
      _ -> false
    end
  end

  defp offer_owner(record) do
    with %Episodes.Episode{} = episode <-
           Repo.one(Episodes.Episode.Query.by_id(record.episode_id)),
         %Work.Turn{episode_id: episode_id} = turn <-
           Repo.one(Work.Turn.Query.by_id(record.turn_id)),
         true <- episode_id == episode.id,
         %Work.Session{} = session <- Repo.one(Work.Session.Query.by_id(turn.session_id)) do
      {:ok, episode, session}
    else
      _ -> {:error, :task_card_source_not_found}
    end
  end

  defp same_destination?(card, episode) do
    episode.destination_transport == "slack" and
      episode.destination_conversation_ref ==
        ConversationRef.slack(card.workspace_ref, card.channel_ref)
  end

  defp snapshot_documents(snapshot) do
    (snapshot.records ++
       Enum.map(snapshot.goal_records ++ snapshot.progress_records, &Records.Record.document/1) ++
       Enum.reject([snapshot.publication_offer], &is_nil/1))
    |> Enum.uniq_by(& &1["ref"])
    |> Enum.map(&Records.DerivedContext.record/1)
  end

  defp public_errors(projection, snapshot) do
    fix = snapshot.automatic_fix
    attention = if fix_line(fix, :fixing), do: nil, else: snapshot.publication
    task = projection.document["task_card"]

    cond do
      # Why the pull request could not be made is said once, on the
      # publication's own line above Review latest state and Discard (Andrew,
      # 2026-09-28: the card said "PR creation is blocked" with its buttons,
      # then the same again as Action needed).
      match?(%Publication.Publication{status: :blocked}, attention) and
        is_map(task["publication"]) and
          is_nil(snapshot.workspace_hold) ->
        reason = fix_line(fix, :stopped) || blocked_cause(attention)

        task =
          task
          |> Map.put("action_needed", nil)
          |> put_in(["publication", "blocked_reason"], reason)

        replace_task(projection, task)

      message =
          fix_line(fix, :stopped) ||
            public_error(attention, snapshot.turn, snapshot.workspace_hold) ->
        task = Map.put(task, "action_needed", message)
        replace_task(projection, task)

      true ->
        projection
    end
  end

  # A review's refusal in the host's own words for Coop's codes; a refusal
  # the host has no words for names only its code, which is the host's own.
  defp blocked_cause(%Publication.Publication{} = publication) do
    case Publication.Review.refusal(publication.review_document) do
      [] -> blocked_code(publication.last_error_code)
      causes -> Wording.list(causes) <> "."
    end
  end

  defp blocked_code(code) when is_binary(code) and code != "", do: "`#{code}`."
  defp blocked_code(_code), do: nil

  # The generic notice exists so untrusted error text never reaches Slack. A held
  # workspace already carries a host-authored explanation and the worker's own
  # redacted reply for this exact destination, and replacing that with "open the
  # episode for details" is what hid the runner's actual question for two days.
  defp public_error(_publication, _turn, hold) when is_map(hold), do: nil

  defp public_error(
         %Publication.Publication{last_error_code: "publication_authorization_revoked"},
         _turn,
         _hold
       ),
       do: @refused_grant

  defp public_error(%Publication.Publication{last_error_code: code}, _turn, _hold)
       when code in @publication_conflicts,
       do: @changed_on_github

  defp public_error(%Publication.Publication{last_error_code: code}, _turn, _hold)
       when is_binary(code) and code not in @in_flight,
       do: attention("Making the draft pull request stopped and needs a person")

  # The generic notice keeps untrusted error text out of Slack, and for a task
  # that never started it was also everything the card ever said — above a
  # Workspace setup row printing the saved term. When the host can characterise
  # that same error, its own words are the only line an operator can act on; the
  # term still never travels, and an error naming nothing keeps the notice.
  # The cause ends in a worker's own sentence, which owes the host no full stop,
  # so the step answering it starts its own line rather than running on.
  defp public_error(_publication, %Work.Turn{status: :blocked} = turn, _hold) do
    case Work.FailureCause.explain(turn.last_error_detail) do
      %{cause: cause, next_step: next_step} -> Fields.cut(cause <> "\n" <> next_step, 2_000)
      nil -> attention("Task work stopped and needs a person")
    end
  end

  defp public_error(_publication, _turn, _hold), do: nil

  # "Open the episode for details" pointed a Slack reader at a page bound to
  # loopback, which their client cannot reach; it is the dead end that hid a
  # runner's question for two days. The worker's own sentence may be untrusted,
  # and the card then printed Ryker's own error code, but a Slack card carries
  # no codes (Andrew, 2026-09-30): it says where the cause is written.
  defp attention(statement), do: "#{statement}. The cause is on Ryker's Failures page."

  defp neutral(projection) do
    task = projection.document["task_card"]

    safe =
      task
      |> Map.take(~w(status task_ref ui_revision updated_at))
      |> Map.merge(%{
        "title" => "Engineering task",
        "summary" => "Task details are unavailable until their source context can be checked.",
        "action_needed" => nil,
        "repository" => "Repository details unavailable",
        "repository_url" => nil,
        "request" => nil,
        # The stage list survives, with every disposition withheld: an
        # unreadable source is unknown progress, not absent progress.
        "stages" => Work.TaskStages.unknown(),
        "publication" => nil,
        "controls" => Enum.filter(task["controls"], &(&1 in ~w(stop close timeline)))
      })

    replace_task(projection, safe)
  end

  defp replace_task(projection, task) do
    document = %{"task_card" => task}
    %{projection | document: document, fingerprint: CanonicalJSON.digest(document)}
  end

  # When the task last moved: its episode, its progress, or GitHub's last word on its pull
  # request. A draft closed a day after the task finished still read "Updated" the day before.
  defp updated_at(episode, publication) do
    progress =
      episode.id
      |> Records.Record.Query.by_episode_id()
      |> Records.Record.Query.by_kinds(["progress", "goal", "goal_state"])
      |> Records.Record.Query.in_use()
      |> Records.Record.Query.not_feedback_progress()
      |> Records.Record.Query.select_latest_insert()
      |> Repo.one()

    [episode.updated_at, progress, github_moved_at(publication)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime)
  end

  defp github_moved_at(%Publication.Publication{id: id}) do
    id
    |> Publication.LifecycleEvent.Query.by_publication_id()
    |> Publication.LifecycleEvent.Query.select_latest_occurrence()
    |> Repo.one()
  end

  defp github_moved_at(nil), do: nil

  defp latest_publication(episode_id) do
    episode_id
    |> Publication.Publication.Query.by_episode_id()
    |> Publication.Publication.Query.ordered_by_recent()
    |> Publication.Publication.Query.limit_to(1)
    |> Repo.one()
  end

  defp status(
         %Episodes.Episode{state: :working},
         %Work.Turn{status: :blocked},
         _publication,
         _offer
       ),
       do: "action_required"

  defp status(
         _episode,
         _turn,
         %Publication.Publication{status: :published, expected_remote_head_sha: head_sha},
         _offer
       )
       when is_binary(head_sha),
       do: "action_required"

  defp status(_episode, _turn, %Publication.Publication{status: :published}, _offer),
    do: "published"

  defp status(_episode, _turn, %Publication.Publication{last_error_code: code}, _offer)
       when is_binary(code) and code not in @in_flight,
       do: "action_required"

  defp status(_episode, _turn, %Publication.Publication{status: status}, _offer)
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: "reviewing"

  defp status(_episode, _turn, %Publication.Publication{status: :reviewed}, _offer),
    do: "ready_to_publish"

  defp status(_episode, _turn, %Publication.Publication{status: :blocked}, _offer),
    do: "action_required"

  defp status(_episode, _turn, %Publication.Publication{status: :discarded}, _offer),
    do: "completed"

  defp status(%Episodes.Episode{state: :cancelled}, _turn, _publication, _offer), do: "cancelled"

  defp status(%Episodes.Episode{state: :complete}, _turn, nil, %{"status" => "open"}),
    do: "action_required"

  defp status(%Episodes.Episode{state: :complete}, _turn, _publication, _offer), do: "completed"

  defp status(%Episodes.Episode{state: :waiting_for_input}, _turn, _publication, _offer),
    do: "waiting_for_input"

  defp status(%Episodes.Episode{state: :waiting_for_event}, _turn, _publication, _offer),
    do: "waiting_for_event"

  # Between confirming a task and a worker being asked for anything there is no
  # turn at all, and the card said "Working" for it. Nothing was.
  defp status(%Episodes.Episode{state: :working}, nil, nil, _offer), do: "queued"

  defp status(_episode, %Work.Turn{status: :cancel_pending}, _publication, _offer), do: "stopping"
  defp status(_episode, _turn, _publication, _offer), do: "working"

  # The worker's answer and its unsaved working copy are what an operator can act
  # on; `{:invalid_work_executor, :workspace_checkpoint_api}` is not, and neither
  # is "open the episode for details". Both are what the card said about the
  # hosted-runner bump while the runner's own answer sat retained and unread.
  defp held_work(nil, _publication), do: nil

  defp held_work(%{closed: closed?, held: held, report: report}, publication) do
    [held_cause(held), held_draft(publication), held_restore(closed?), held_report(report)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> Fields.cut(2_000)
  end

  # A pull request opened earlier stays reachable, but it predates the work the
  # host could not keep. Leaving "Draft PR created. Open it to review the
  # changes." as the only word about it offers an older snapshot as the current one.
  defp held_draft(%Publication.Publication{status: status, pull_request_number: number})
       when status in [:published, :published_ready] and is_integer(number),
       do: "Draft PR ##{number} stays open, but it is an earlier snapshot without this work."

  defp held_draft(_publication), do: "Nothing was published."

  defp held_cause(:workspace),
    do: "The worker finished, but I couldn't save its working copy, so its reply is still held."

  defp held_cause(:reply),
    do: "The worker finished, but saving its result stopped, so its reply is still held."

  defp held_restore(true) do
    "Keep its working copy and task notes: the worker session is closed, so a retry can't recover them."
  end

  defp held_restore(false),
    do: "Keep its working copy and task notes until they are restored into a bound workspace."

  defp held_report(nil), do: nil

  defp held_report(report),
    do: "The worker's own report, which is not a check result: \"#{Fields.cut(report, 900)}\""

  defp unstarted_review(%Episodes.Episode{state: :complete}, nil, %{"status" => "open"}) do
    "Prepared changes are saved, but checks have not started. Open the request's timeline to review how to recover the working copy."
  end

  defp unstarted_review(_episode, _publication, _offer), do: nil

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication.Publication{status: :blocked} = publication
       ) do
    Fields.cut(
      publication.last_error_detail || "Draft pull-request work needs operator attention.",
      500
    )
  end

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication.Publication{status: :published, expected_remote_head_sha: head_sha}
       )
       when is_binary(head_sha) do
    "The draft pull-request head changed outside this reviewed publication. Review the latest state or discard publication custody."
  end

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication.Publication{last_error_code: "publication_authorization_revoked"}
       ),
       do: @refused_grant

  defp action_needed(_episode, _turn, _records, %Publication.Publication{last_error_code: code})
       when code in @publication_conflicts,
       do: @changed_on_github

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication.Publication{last_error_code: code} = publication
       )
       when is_binary(code) and code not in @in_flight,
       do: Fields.cut(publication.last_error_detail || code, 500)

  defp action_needed(%Episodes.Episode{state: :waiting_for_input}, _turn, records, _publication),
    do: wait_summary(records, "input_request", "An operator response is required.")

  defp action_needed(%Episodes.Episode{state: :waiting_for_event}, _turn, records, _publication),
    do: wait_summary(records, "event_wait", "The task is waiting for external verification.")

  defp action_needed(_episode, %Work.Turn{status: :blocked} = turn, _records, _publication) do
    Fields.cut(
      turn.last_error_detail || "Task work is blocked and needs operator attention.",
      500
    )
  end

  defp action_needed(_episode, _turn, _records, _publication), do: nil

  # A card that says an operator response is required could not point at the
  # question: a Slack message link needs the workspace origin, and the host
  # stored every other part of it. With the origin unset this stays nil and the
  # card describes the question instead of linking nowhere.
  defp question_url(%Episodes.Episode{state: :waiting_for_input} = episode) do
    with workspace_url when is_binary(workspace_url) <- Settings.slack_workspace_url(),
         %Records.Record{turn_id: turn_id} when not is_nil(turn_id) <- open_question(episode.id),
         %Work.Turn{
           external_receipt: %{"conversation_ref" => conversation, "message_ref" => message}
         } <-
           Repo.one(Work.Turn.Query.by_id(turn_id)) do
      Permalink.message_url(workspace_url, conversation, message)
    else
      _unbuildable -> nil
    end
  end

  defp question_url(_episode), do: nil

  defp open_question(episode_id) do
    episode_id
    |> Records.Record.Query.by_episode_id()
    |> Records.Record.Query.by_kind("input_request")
    |> Records.Record.Query.open()
    |> Records.Record.Query.ordered_by_sequence_desc()
    |> Records.Record.Query.limit_to(1)
    |> Repo.one()
  end

  defp wait_summary(records, kind, fallback) do
    records
    |> Enum.reverse()
    |> Enum.find(&(&1["kind"] == kind))
    |> case do
      %{"payload" => %{"question" => question}} -> Fields.cut(question, 500)
      %{"payload" => %{"verification" => verification}} -> Fields.cut(verification, 500)
      _missing -> fallback
    end
  end

  defp summary(record, progress) do
    case List.last(progress) do
      %{"summary" => summary} -> summary
      _missing -> record.payload["prompt"] |> StateTools.TaskTools.request() |> Fields.cut(500)
    end
  end

  defp publication(nil, _followup, _fix), do: nil

  defp publication(%Publication.Publication{} = publication, followup, fix) do
    %{
      "automatic_fix" => fix_line(fix, :fixing),
      "blocked_reason" => nil,
      "branch" => publication.branch_ref,
      "controls" =>
        cond do
          fix_line(fix, :fixing) -> ["discard"]
          settled_on_github?(followup) -> ["open"]
          true -> publication_controls(publication)
        end,
      "discarded_reason" => discarded_reason(publication),
      "publication_ref" => publication.ref,
      "pull_request_number" => publication.pull_request_number,
      "pull_request_state" => pull_request_state(followup),
      "pull_request_url" => publication.pull_request_url,
      "recovery_generation" => publication.recovery_generation,
      "status" => Atom.to_string(publication.status),
      "unverified" => unverified(publication)
    }
  end

  # Only a person closes or merges a pull request on GitHub; its follow-up records which.
  defp pull_request_state(%Publication.Followup{pr_state: state})
       when state in [:closed, :merged],
       do: Atom.to_string(state)

  defp pull_request_state(_followup), do: nil

  # What the task asked for is settled on GitHub, so the card asks nothing more
  # of anyone and offers only the pull request. A merge moves its head, and the
  # card said the head "changed outside this reviewed publication", asked for
  # action and offered Update and Discard on a merged pull request (2026-10-04
  # review).
  defp settled_on_github?(followup), do: not is_nil(pull_request_state(followup))

  # Andrew, 2026-09-28: a change the trusted review refused for something the
  # task's own work can fix goes back to that work without a person, three
  # rounds at most (`Ryker.Publication.FixLoop`). While a round runs the card
  # says so beside Discard, and the refusal neither sets the task's status nor
  # asks for action: the work is doing what a person used to be asked to
  # request. Once the rounds are spent it says so plainly, as the action
  # needed, with Review latest state and Discard where they always were.

  defp fix_line({state, line}, state), do: line
  defp fix_line(_fix, _state), do: nil

  # Why Ryker ended a publication itself; nil for one a person discarded, which
  # the operator audit already names. The card said "PR preparation stopped"
  # for both, so a closed worker session read like somebody's decision.
  defp discarded_reason(%Publication.Publication{status: :discarded, discarded_reason: reason})
       when is_atom(reason) and not is_nil(reason),
       do: Atom.to_string(reason)

  defp discarded_reason(_publication), do: nil

  # Which required check has no result, in the operator's words. Without it a
  # blocked candidate can only say that something is missing, which is how a
  # missing tool, a failed assertion and a policy finding read the same — and a
  # draft opened on that candidate then read as an ordinary checked pull request.
  defp unverified(%Publication.Publication{status: status, review_document: review})
       when status in [:blocked, :publish_pending, :published_ready, :published] do
    case Publication.Review.draft_verdict(review) do
      %{"shareable" => true, "incomplete_checks" => [reason | _rest]} -> Fields.cut(reason, 500)
      _decided -> nil
    end
  end

  defp unverified(_publication), do: nil

  defp publication_controls(%Publication.Publication{
         status: status,
         last_error_code: code,
         expected_remote_head_sha: head_sha,
         pull_request_number: number,
         pull_request_url: url
       })
       when status == :publish_pending and code in @publication_conflicts and is_binary(head_sha) and
              is_integer(number) and is_binary(url),
       do: ["open", "update", "discard"]

  defp publication_controls(%Publication.Publication{
         status: :publish_pending,
         last_error_code: code
       })
       when code in @publication_conflicts,
       do: ["discard"]

  # A refused grant cannot be retried, since the worker finished that publish as refused; a fresh
  # review can (`Ryker.Publication.Custody`). The card offered Retry here until 2026-09-30.
  defp publication_controls(%Publication.Publication{
         status: :publish_pending,
         last_error_code: "publication_authorization_revoked",
         pull_request_number: number,
         pull_request_url: url
       }) do
    if is_integer(number) and is_binary(url),
      do: ["open", "update", "discard"],
      else: ["update", "discard"]
  end

  # A check takes minutes, and the card offered nothing while it ran (Andrew,
  # 2026-09-28): a person can always drop a change that is being checked.
  defp publication_controls(%Publication.Publication{
         status: :review_pending,
         last_error_code: code
       }) do
    if(is_binary(code) and code not in @in_flight, do: ["retry", "discard"], else: ["discard"])
  end

  defp publication_controls(%Publication.Publication{status: status, last_error_code: code})
       when status in [:review_ready, :publish_pending, :published_ready] and is_binary(code) and
              code not in @in_flight,
       do: ["retry"]

  # A reviewed candidate only rests here when no task grant covers its draft,
  # so this is the genuinely unauthorized path; an authorized one is already
  # publishing and offers nothing to click.
  defp publication_controls(%Publication.Publication{status: :reviewed}),
    do: ["publish", "update", "discard"]

  # A safe snapshot whose checks could not run is a person's decision, not the
  # host's: offer the draft explicitly, never open it automatically. A repository
  # with no checks answers every review of a change the same way, and a newer
  # finished run is reviewed without a click, so there a re-check could only
  # repeat itself (Andrew, 2026-09-30: "why do I even need to click to review
  # latest state?").
  defp publication_controls(%Publication.Publication{status: :blocked, review_document: review}) do
    cond do
      not Publication.Review.draft_shareable?(review) -> ["update", "discard"]
      Publication.Review.no_checks?(review) -> ["publish", "discard"]
      true -> ["publish", "update", "discard"]
    end
  end

  defp publication_controls(%Publication.Publication{
         status: :published,
         expected_remote_head_sha: head_sha
       })
       when is_binary(head_sha),
       do: ["open", "update", "discard"]

  # Ryker looks at an open pull request every ten minutes and at once on each check, workflow or
  # pull request event, so the card has nothing to offer for refreshing it (Andrew, 2026-09-30, of
  # "Check delivery": "not clear wtf this button does?").
  defp publication_controls(%Publication.Publication{status: :published}), do: ["open"]
  defp publication_controls(%Publication.Publication{status: :published_ready}), do: ["open"]
  defp publication_controls(_publication), do: []

  defp latest_publication_offer(episode_id) do
    episode_id
    |> Records.Record.Query.delivered_publication_offers()
    |> Repo.all()
    |> Enum.find_value(fn {record, delivery_document} ->
      record_refs = get_in(delivery_document || %{}, ["outcome", "record_refs"])

      if host_publication_offer?(record) or
           (is_list(record_refs) and record.ref in record_refs),
         do: Records.Record.document(record)
    end)
  end

  defp host_publication_offer?(%{operation_id: "host:publication:ready"}), do: true
  defp host_publication_offer?(_record), do: false

  # A workspace the host never saved has no changes page to open, so the diff
  # control would link to nothing; recovery is the control that state allows.
  defp controls(record, episode, turn, session, publication, hold) do
    shown = [
      {WorkControls.stoppable?(episode, turn), "stop"},
      {is_nil(hold) and resumable?(turn), "resume"},
      {is_nil(hold) and WorkControls.diff_available?(session), "view_diff"},
      {close_allowed?(episode, turn, publication), "close"},
      {true, "timeline"},
      {true, "evidence"},
      {true, "handoff"},
      {not is_nil(hold), "recovery"},
      {incident?(record), "postmortem"}
    ]

    for {true, control} <- shown, do: control
  end

  # A run an operator stopped could only be continued from the control plane, so
  # a person who stopped one in Slack had nowhere to say "carry on" from. The
  # button carries the recovery fingerprint the card was rendered against, which
  # is the same guard the control-plane action uses: a card that has gone stale
  # cannot resume a turn that has moved on.
  defp resumable?(%Work.Turn{status: :blocked, cancellation_intent: %{"action" => "block"}}),
    do: true

  defp resumable?(_turn), do: false

  defp resume_ref(task_ref, %Work.Turn{} = turn, nil) do
    if resumable?(turn), do: "#{task_ref}|#{Work.Custody.recovery_fingerprint(turn)}"
  end

  defp resume_ref(_task_ref, _turn, _hold), do: nil

  defp incident?(%Records.Record{payload: %{"kind" => "incident"}}), do: true
  defp incident?(_record), do: false

  defp close_allowed?(%Episodes.Episode{state: state}, _turn, _publication)
       when state in [:complete, :cancelled],
       do: false

  defp close_allowed?(_episode, %Work.Turn{status: status}, _publication)
       when status in [:cancel_pending, :delivery_pending],
       do: false

  defp close_allowed?(_episode, _turn, %Publication.Publication{status: status})
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: false

  defp close_allowed?(_episode, _turn, _publication), do: true
end
