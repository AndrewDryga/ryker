defmodule Responder.Slack.TaskCardProjection do
  @moduledoc """
  Builds one bounded, host-owned engineering-task card from canonical state.

  TaskCard projections reauthorize their source context before external Slack
  publication. Record projections are retained operator audit views only.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.WorkRecovery
  alias Responder.Episodes.Episode
  alias Responder.Publication.{Followup, Publication, Review}
  alias Responder.Repo
  alias Responder.Slack.{Permalink, TaskCard}
  alias Responder.State.{DerivedContext, Record, Records}
  alias Responder.Work.{FailureCause, Session, TaskStages, Turn}

  @ui_revision 6
  @publication_conflicts ~w(publication_branch_already_exists publication_branch_changed publication_existing_pull_request_changed publication_pull_request_mismatch)

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
  @spec build(Record.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(
        %Record{
          kind: "task_offer",
          status: :confirmed,
          confirmed_episode_id: episode_id
        } = record
      )
      when is_binary(episode_id) do
    case Repo.get(Episode, episode_id) do
      %Episode{} = episode -> project(record, episode, record.ref, snapshot(episode))
      nil -> {:error, :task_card_source_not_found}
    end
  end

  def build(_card), do: {:error, :invalid_task_card}

  defp build_public(card) do
    with %Record{} = record <- Repo.get(Record, card.record_id),
         %Episode{} = episode <- Repo.get(Episode, card.episode_id) do
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

    projection = %{
      "action_needed" =>
        held_work(snapshot.workspace_hold, publication) ||
          action_needed(episode, turn, records, publication) ||
          unstarted_review(episode, publication, publication_offer),
      "confirmed_at" => DateTime.to_iso8601(record.confirmed_at),
      "confirmed_by" => record.confirmed_by_actor_ref,
      "controls" =>
        controls(record, episode, turn, session, publication, snapshot.workspace_hold),
      "episode_state" => Atom.to_string(episode.state),
      "publication" => publication(publication, publication_offer),
      "request" => compact(record.payload["prompt"], 600),
      "repository" => record.payload["repository"],
      "repository_url" => repository_url(publication),
      "session_generation" => session && session.generation,
      "stages" =>
        TaskStages.build(%{
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
      "status" => status(episode, turn, publication, publication_offer),
      "summary" => summary(record, progress),
      "task_ref" => task_ref,
      "title" => record.payload["title"],
      "ui_revision" => @ui_revision,
      "updated_at" => DateTime.to_iso8601(updated_at(episode)),
      "work_state" => turn && Atom.to_string(turn.status)
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
    turn = current_turn(episode)

    %{
      turn: turn,
      session: latest_session(episode.id),
      publication: publication,
      followup: followup(publication),
      records: Records.retained_records(episode.id),
      publication_offer: latest_publication_offer(episode.id),
      goal_records: goal_records(episode.id),
      progress_records: progress_records(episode.id),
      workspace_hold: WorkRecovery.workspace_hold(turn)
    }
  end

  defp followup(nil), do: nil

  defp followup(%Publication{id: id}),
    do: Repo.one(from(followup in Followup, where: followup.publication_id == ^id))

  # A repository links out only from the trusted GitHub binding its own
  # publication receipt recorded; a display label never becomes a URL.
  defp repository_url(%Publication{github_repository: repository}) when is_binary(repository),
    do: "https://github.com/#{repository}"

  defp repository_url(_publication), do: nil

  defp goal_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind in ["goal", "goal_state"] and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
  end

  defp progress_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind == "progress" and
            record.status in [:open, :confirmed] and
            fragment("COALESCE((?::jsonb)->>'phase', '') NOT LIKE 'feedback:%'", record.payload),
        order_by: [desc: record.sequence],
        limit: 4
      )
    )
    |> Enum.reverse()
  end

  defp progress_detail(record) do
    %{
      "phase" => compact(record.payload["phase"], 60),
      "summary" => compact(record.payload["summary"], 600),
      "at" => DateTime.to_iso8601(record.inserted_at)
    }
  end

  defp public_sources?(card, record, episode, snapshot) do
    with true <- record.confirmed_episode_id == episode.id,
         true <- same_destination?(card, episode),
         {:ok, source_episode, source_session} <- offer_owner(record),
         true <- same_destination?(card, source_episode),
         {:ok, _} <-
           DerivedContext.resolve(
             [DerivedContext.record(record_document(record))],
             source_episode,
             source_session.repository_ref
           ),
         %Session{} = session <- snapshot.session,
         {:ok, _} <-
           DerivedContext.resolve(
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
    with %Episode{} = episode <- Repo.get(Episode, record.episode_id),
         %Turn{episode_id: episode_id} = turn <- Repo.get(Turn, record.turn_id),
         true <- episode_id == episode.id,
         %Session{} = session <- Repo.get(Session, turn.session_id) do
      {:ok, episode, session}
    else
      _ -> {:error, :task_card_source_not_found}
    end
  end

  defp same_destination?(card, episode),
    do:
      episode.destination_transport == "slack" and
        episode.destination_conversation_ref == "slack:#{card.workspace_ref}:#{card.channel_ref}"

  defp snapshot_documents(snapshot) do
    (snapshot.records ++
       Enum.map(snapshot.goal_records ++ snapshot.progress_records, &record_document/1) ++
       Enum.reject([snapshot.publication_offer], &is_nil/1))
    |> Enum.uniq_by(& &1["ref"])
    |> Enum.map(&DerivedContext.record/1)
  end

  defp record_document(record),
    do: %{
      "kind" => record.kind,
      "payload" => record.payload,
      "ref" => record.ref,
      "status" => Atom.to_string(record.status)
    }

  defp public_errors(projection, snapshot) do
    case public_error(snapshot.publication, snapshot.turn, snapshot.workspace_hold) do
      nil ->
        projection

      message ->
        replace_task(
          projection,
          Map.put(projection.document["task_card"], "action_needed", message)
        )
    end
  end

  # The generic notice exists so untrusted error text never reaches Slack. A held
  # workspace already carries a host-authored explanation and the worker's own
  # redacted reply for this exact destination, and replacing that with "open the
  # episode for details" is what hid the runner's actual question for two days.
  defp public_error(_publication, _turn, hold) when is_map(hold), do: nil

  defp public_error(%Publication{status: :blocked}, _turn, _hold),
    do: "Draft pull-request work needs operator attention. Open the episode for details."

  defp public_error(%Publication{last_error_code: code}, _turn, _hold) when is_binary(code),
    do: "Draft pull-request work needs operator attention. Open the episode for details."

  # The generic notice keeps untrusted error text out of Slack, and for a task
  # that never started it was also everything the card ever said — above a
  # Workspace setup row printing the saved term. When the host can characterise
  # that same error, its own words are the only line an operator can act on; the
  # term still never travels, and an error naming nothing keeps the notice.
  # The cause ends in a worker's own sentence, which owes the host no full stop,
  # so the step answering it starts its own line rather than running on.
  defp public_error(_publication, %Turn{status: :blocked} = turn, _hold) do
    case FailureCause.explain(turn.last_error_detail) do
      %{cause: cause, next_step: next_step} -> compact(cause <> "\n" <> next_step, 2_000)
      nil -> "Task work is blocked and needs operator attention. Open the episode for details."
    end
  end

  defp public_error(_publication, _turn, _hold), do: nil

  defp neutral(projection) do
    task = projection.document["task_card"]

    safe =
      task
      |> Map.take(
        ~w(confirmed_at confirmed_by episode_state session_generation status task_ref ui_revision updated_at work_state)
      )
      |> Map.merge(%{
        "title" => "Engineering task",
        "summary" => "Task details are unavailable until their source context can be checked.",
        "action_needed" => nil,
        "repository" => "Repository details unavailable",
        "repository_url" => nil,
        "request" => nil,
        # The stage list survives, with every disposition withheld: an
        # unreadable source is unknown progress, not absent progress.
        "stages" => TaskStages.unknown(),
        "publication" => nil,
        "controls" => Enum.filter(task["controls"], &(&1 in ~w(stop close timeline)))
      })

    replace_task(projection, safe)
  end

  defp replace_task(projection, task) do
    document = %{"task_card" => task}
    %{projection | document: document, fingerprint: CanonicalJSON.digest(document)}
  end

  defp updated_at(episode) do
    latest =
      Repo.one(
        from(record in Record,
          where:
            record.episode_id == ^episode.id and record.kind in ["progress", "goal", "goal_state"] and
              record.status in [:open, :confirmed] and
              fragment("COALESCE((?::jsonb)->>'phase', '') NOT LIKE 'feedback:%'", record.payload),
          select: max(record.inserted_at)
        )
      )

    if latest && DateTime.compare(latest, episode.updated_at) == :gt,
      do: latest,
      else: episode.updated_at
  end

  defp current_turn(%Episode{owner_kind: :turn, owner_ref: turn_ref} = episode),
    do: Repo.get_by(Turn, episode_id: episode.id, turn_ref: turn_ref)

  defp current_turn(%Episode{owner_kind: :delivery, owner_ref: delivery_ref} = episode),
    do: Repo.get_by(Turn, episode_id: episode.id, delivery_ref: delivery_ref)

  defp current_turn(episode) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode.id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  defp latest_session(episode_id) do
    Repo.one(
      from(session in Session,
        where: session.episode_id == ^episode_id,
        order_by: [desc: session.generation],
        limit: 1
      )
    )
  end

  defp latest_publication(episode_id) do
    Repo.one(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [desc: publication.inserted_at, desc: publication.id],
        limit: 1
      )
    )
  end

  defp status(%Episode{state: :working}, %Turn{status: :blocked}, _publication, _offer),
    do: "action_required"

  defp status(
         _episode,
         _turn,
         %Publication{status: :published, expected_remote_head_sha: head_sha},
         _offer
       )
       when is_binary(head_sha),
       do: "action_required"

  defp status(_episode, _turn, %Publication{status: :published}, _offer), do: "published"

  defp status(_episode, _turn, %Publication{last_error_code: code}, _offer)
       when is_binary(code),
       do: "action_required"

  defp status(_episode, _turn, %Publication{status: status}, _offer)
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: "reviewing"

  defp status(_episode, _turn, %Publication{status: :reviewed}, _offer),
    do: "ready_to_publish"

  defp status(_episode, _turn, %Publication{status: :blocked}, _offer),
    do: "action_required"

  defp status(_episode, _turn, %Publication{status: :discarded}, _offer),
    do: "completed"

  defp status(%Episode{state: :cancelled}, _turn, _publication, _offer), do: "cancelled"

  defp status(%Episode{state: :complete}, _turn, nil, %{"status" => "open"}),
    do: "action_required"

  defp status(%Episode{state: :complete}, _turn, _publication, _offer), do: "completed"

  defp status(%Episode{state: :waiting_for_input}, _turn, _publication, _offer),
    do: "waiting_for_input"

  defp status(%Episode{state: :waiting_for_event}, _turn, _publication, _offer),
    do: "waiting_for_event"

  # Between confirming a task and a worker being asked for anything there is no
  # turn at all, and the card said "Working" for it. Nothing was.
  defp status(%Episode{state: :working}, nil, nil, _offer), do: "queued"

  defp status(_episode, %Turn{status: :cancel_pending}, _publication, _offer), do: "stopping"
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
    |> compact(2_000)
  end

  # A pull request opened earlier stays reachable, but it predates the work the
  # host could not keep. Leaving "Draft PR created. Open it to review the
  # changes." as the only word about it offers an older snapshot as the current one.
  defp held_draft(%Publication{status: status, pull_request_number: number})
       when status in [:published, :published_ready] and is_integer(number),
       do: "Draft PR ##{number} stays open, but it is an earlier snapshot without this work."

  defp held_draft(_publication), do: "Nothing was published."

  defp held_cause(:workspace),
    do: "The worker finished, but I couldn't save its working copy, so its reply is still held."

  defp held_cause(:reply),
    do: "The worker finished, but saving its result stopped, so its reply is still held."

  defp held_restore(true),
    do:
      "Keep its working copy and task notes: the worker session is closed, so a retry can't recover them."

  defp held_restore(false),
    do: "Keep its working copy and task notes until they are restored into a bound workspace."

  defp held_report(nil), do: nil

  defp held_report(report),
    do: "The worker's own report, which is not a check result: “#{compact(report, 900)}”"

  defp unstarted_review(%Episode{state: :complete}, nil, %{"status" => "open"}),
    do:
      "Prepared changes are saved, but checks have not started. Open the episode to review workspace recovery."

  defp unstarted_review(_episode, _publication, _offer), do: nil

  defp action_needed(_episode, _turn, _records, %Publication{status: :blocked} = publication),
    do:
      compact(
        publication.last_error_detail || "Draft pull-request work needs operator attention.",
        500
      )

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication{status: :published, expected_remote_head_sha: head_sha}
       )
       when is_binary(head_sha),
       do:
         "The draft pull-request head changed outside this reviewed publication. Review the latest state or discard publication custody."

  defp action_needed(
         _episode,
         _turn,
         _records,
         %Publication{last_error_code: code} = publication
       )
       when is_binary(code),
       do: compact(publication.last_error_detail || code, 500)

  defp action_needed(%Episode{state: :waiting_for_input}, _turn, records, _publication),
    do: wait_summary(records, "input_request", "An operator response is required.")

  defp action_needed(%Episode{state: :waiting_for_event}, _turn, records, _publication),
    do: wait_summary(records, "event_wait", "The task is waiting for external verification.")

  defp action_needed(_episode, %Turn{status: :blocked} = turn, _records, _publication),
    do:
      compact(turn.last_error_detail || "Task work is blocked and needs operator attention.", 500)

  defp action_needed(_episode, _turn, _records, _publication), do: nil

  # A card that says an operator response is required could not point at the
  # question: a Slack message link needs the workspace origin, and the host
  # stored every other part of it. With the origin unset this stays nil and the
  # card describes the question instead of linking nowhere.
  defp question_url(%Episode{state: :waiting_for_input} = episode) do
    with %{workspace_url: workspace_url} when is_binary(workspace_url) <- slack_settings(),
         %Record{turn_id: turn_id} when not is_nil(turn_id) <- open_question(episode.id),
         %Turn{external_receipt: %{"conversation_ref" => conversation, "message_ref" => message}} <-
           Repo.get(Turn, turn_id) do
      Permalink.message_url(workspace_url, conversation, message)
    else
      _unbuildable -> nil
    end
  end

  defp question_url(_episode), do: nil

  defp slack_settings do
    case Responder.Settings.fetch() do
      {:ok, %{slack: %{} = slack}} -> slack
      _unavailable -> nil
    end
  rescue
    _error -> nil
  end

  defp open_question(episode_id) do
    Repo.one(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind == "input_request" and
            record.status == :open,
        order_by: [desc: record.sequence],
        limit: 1
      )
    )
  end

  defp wait_summary(records, kind, fallback) do
    records
    |> Enum.reverse()
    |> Enum.find(&(&1["kind"] == kind))
    |> case do
      %{"payload" => %{"question" => question}} -> compact(question, 500)
      %{"payload" => %{"verification" => verification}} -> compact(verification, 500)
      _missing -> fallback
    end
  end

  defp summary(record, progress) do
    case List.last(progress) do
      %{"summary" => summary} -> summary
      _missing -> compact(record.payload["prompt"], 500)
    end
  end

  defp publication(nil, _offer), do: nil

  defp publication(%Publication{} = publication, _offer) do
    %{
      "branch" => publication.branch_ref,
      "controls" => publication_controls(publication),
      "publication_ref" => publication.ref,
      "pull_request_number" => publication.pull_request_number,
      "pull_request_url" => publication.pull_request_url,
      "recovery_generation" => publication.recovery_generation,
      "status" => Atom.to_string(publication.status),
      "unverified" => unverified(publication)
    }
  end

  # Which required check has no result, in the operator's words. Without it a
  # blocked candidate can only say that something is missing, which is how a
  # missing tool, a failed assertion and a policy finding read the same — and a
  # draft opened on that candidate then read as an ordinary checked pull request.
  defp unverified(%Publication{status: status, review_document: review})
       when status in [:blocked, :publish_pending, :published_ready, :published] do
    case Review.draft_verdict(review) do
      %{"shareable" => true, "incomplete_checks" => [reason | _rest]} -> compact(reason, 500)
      _decided -> nil
    end
  end

  defp unverified(_publication), do: nil

  defp publication_controls(%Publication{
         status: status,
         last_error_code: code,
         expected_remote_head_sha: head_sha,
         pull_request_number: number,
         pull_request_url: url
       })
       when status == :publish_pending and code in @publication_conflicts and is_binary(head_sha) and
              is_integer(number) and is_binary(url),
       do: ["open", "update", "discard"]

  defp publication_controls(%Publication{status: :publish_pending, last_error_code: code})
       when code in @publication_conflicts,
       do: ["discard"]

  defp publication_controls(%Publication{status: status, last_error_code: code})
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready] and
              is_binary(code),
       do: ["retry"]

  # A reviewed candidate only rests here when no task grant covers its draft,
  # so this is the genuinely unauthorized path; an authorized one is already
  # publishing and offers nothing to click.
  defp publication_controls(%Publication{status: :reviewed}),
    do: ["publish", "update", "discard"]

  # A safe snapshot whose checks could not run is a person's decision, not the
  # host's: offer the draft explicitly, never open it automatically.
  defp publication_controls(%Publication{status: :blocked} = publication) do
    if Review.draft_shareable?(publication.review_document),
      do: ["publish", "update", "discard"],
      else: ["update", "discard"]
  end

  defp publication_controls(%Publication{status: :published, expected_remote_head_sha: head_sha})
       when is_binary(head_sha),
       do: ["open", "check", "update", "discard"]

  defp publication_controls(%Publication{status: :published}), do: ["open", "check"]
  defp publication_controls(%Publication{status: :published_ready}), do: ["open"]
  defp publication_controls(_publication), do: []

  defp latest_publication_offer(episode_id) do
    Repo.all(
      from(record in Responder.State.Record,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where:
          record.episode_id == ^episode_id and record.kind == "publication_offer" and
            record.status == :open and turn.status == :settled,
        order_by: [desc: record.sequence],
        limit: 16,
        select: {record, turn.delivery_document}
      )
    )
    |> Enum.find_value(fn {record, delivery_document} ->
      record_refs = get_in(delivery_document || %{}, ["outcome", "record_refs"])

      if host_publication_offer?(record) or
           (is_list(record_refs) and record.ref in record_refs),
         do: %{
           "kind" => record.kind,
           "payload" => record.payload,
           "ref" => record.ref,
           "status" => Atom.to_string(record.status)
         }
    end)
  end

  defp host_publication_offer?(%{operation_id: "host:publication:ready"}), do: true
  defp host_publication_offer?(_record), do: false

  # A workspace the host never saved has no changes page to open, so the diff
  # control would link to nothing; recovery is the control that state allows.
  defp controls(record, episode, turn, session, publication, hold) do
    []
    |> maybe_control(stop_allowed?(episode, turn), "stop")
    |> maybe_control(is_nil(hold) and bound_session?(session), "view_diff")
    |> maybe_control(close_allowed?(episode, turn, publication), "close")
    |> Kernel.++(~w(timeline evidence handoff))
    |> maybe_control(not is_nil(hold), "recovery")
    |> maybe_control(incident?(record), "postmortem")
  end

  defp incident?(%Record{payload: %{"kind" => "incident"}}), do: true
  defp incident?(_record), do: false

  defp stop_allowed?(%Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref}, %Turn{
         status: :pending,
         turn_ref: turn_ref
       }),
       do: true

  defp stop_allowed?(_episode, _turn), do: false

  defp close_allowed?(%Episode{state: state}, _turn, _publication)
       when state in [:complete, :cancelled],
       do: false

  defp close_allowed?(_episode, %Turn{status: status}, _publication)
       when status in [:cancel_pending, :delivery_pending],
       do: false

  defp close_allowed?(_episode, _turn, %Publication{status: status})
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: false

  defp close_allowed?(_episode, _turn, _publication), do: true

  defp bound_session?(%Session{coop_session_id: value}) when is_binary(value) and value != "",
    do: true

  defp bound_session?(_session), do: false

  defp maybe_control(controls, true, control), do: controls ++ [control]
  defp maybe_control(controls, false, _control), do: controls

  defp compact(value, maximum) when is_binary(value) do
    if String.length(value) > maximum,
      do: String.slice(value, 0, maximum - 1) <> "…",
      else: value
  end

  defp compact(_value, _maximum), do: nil
end
