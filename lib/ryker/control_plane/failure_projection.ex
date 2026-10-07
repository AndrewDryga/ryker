defmodule Ryker.ControlPlane.FailureProjection do
  @moduledoc """
  The Failures page: every blocked item an operator can retry, across work,
  admission, delivery, retention, Slack repaint, incident rooms, publications,
  Emisar approvals and background learning, plus stops their worker has not
  confirmed, each with the host's own diagnosis and never a raw error body.
  """

  alias Ryker.Config
  alias Ryker.ControlPlane.{Activity, Failure, LearningActivity, ProductReadiness}
  alias Ryker.ControlPlane.RepositoryNames
  alias Ryker.CoopFleet.{JobAuthority, Worker}
  alias Ryker.Credentials
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.Batch, as: LearningBatch
  alias Ryker.Observability
  alias Ryker.Operator.Delivery, as: DeliveryOperator
  alias Ryker.Operator.Emisar, as: EmisarOperator
  alias Ryker.Operator.FailureDetail
  alias Ryker.Operator.FailureDismissals
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, IncidentRoom, IncidentRooms}
  alias Ryker.Slack.{InteractionAudit, Names}
  alias Ryker.Slack.{TaskCard, ThreadStatus}
  alias Ryker.Work.{Cancellation, FailureCause, Recovery, Session, Turn}

  # The phases Ryker is still retrying. A recorded failure there is a stuck
  # publication; a reviewed change waiting for a person, a review verdict and a
  # finished or discarded publication are not failures, whatever code an
  # earlier attempt left behind.
  @running_publication_statuses [
    :review_pending,
    :review_ready,
    :publish_pending,
    :published_ready
  ]

  @page_size 100
  @maximum_page 100
  @kinds ~w(admission delivery emisar learning publication retention slack_incident
            slack_interaction slack_task_card slack_thread_status stopping work)

  @doc """
  One page of every blocked item, newest first, a hundred to a page (`"page"`
  in `params`, the first by default); `{:error, :unavailable}` when the
  database cannot answer, so a broken read never renders as nothing wrong.

  Each kind is read newest first and as deep as the page needs. Blocked
  replies were read oldest first, a hundred at a time, and only then sorted:
  past a hundred, the newest were cut before anything saw them, and the page
  said nothing about it. Older failures are now the next page.
  """
  @spec list(map()) :: {:ok, [map()]} | {:error, :unavailable}
  def list(params) do
    with {:ok, %{rows: rows}} <- page(params), do: {:ok, rows}
  end

  @doc """
  `list/1`'s page with whether older failures are behind it: `:next_page`,
  `:none`, or `:unlisted` past the deepest page the list reads. The page ran
  the whole projection a second time to learn this (2026-10-04 review); the
  one read that fills it fetches a row more than it needs and knows.
  """
  @spec page(map()) ::
          {:ok, %{rows: [map()], older: :next_page | :none | :unlisted}}
          | {:error, :unavailable}
  def page(params) do
    page = page_number(params)
    # The newest items of every kind that the pages up to this one can hold,
    # and one more: enough to fill this page whatever the mix of kinds.
    fetch = page * @page_size + 1
    # A failure someone left still comes back from its kind's query and is
    # dropped below, so each kind reads that many more: a hundred left ones
    # hid an older open one on every page.
    left = FailureDismissals.counts()
    deep = &(fetch + Map.get(left, &1, 0))

    work =
      Failure.Query.blocked_work()
      |> Failure.Query.limit_to(deep.("work"))
      |> Repo.all()
      |> Enum.map(&work_item/1)

    admission =
      Entry.Query.blocked()
      |> Entry.Query.ordered_by_recently_updated()
      |> Entry.Query.limit_to(deep.("admission"))
      |> Repo.all()
      |> Enum.map(&admission_item/1)

    # A learning session has no episode; an inner join hid every blocked
    # learning cleanup from this page and from its retry.
    retention =
      Failure.Query.blocked_cleanups()
      |> Failure.Query.limit_to(deep.("retention"))
      |> Repo.all()
      |> Enum.map(&retention_item/1)

    # A stop retries without end, because only its worker's answer (or the
    # worker's removal) proves a run stopped. One that never got that answer
    # read "stopping" forever and was listed nowhere.
    stopping =
      Cancellation.stalled_after_attempts()
      |> Failure.Query.stalled_stops()
      |> Failure.Query.limit_to(deep.("stopping"))
      |> Repo.all()
      |> Enum.map(&stopping_item/1)

    interaction_feedback =
      InteractionAudit.Query.repaint_blocked()
      |> InteractionAudit.Query.ordered_by_recently_updated()
      |> InteractionAudit.Query.limit_to(deep.("slack_interaction"))
      |> Repo.all()
      |> Enum.map(&interaction_item/1)

    incident_rooms =
      IncidentRoom.Query.blocked()
      |> IncidentRoom.Query.ordered_by_recently_updated()
      |> IncidentRoom.Query.limit_to(deep.("slack_incident"))
      |> Repo.all()
      |> Enum.map(&incident_item/1)

    # A task's card and a thread's status are edited in place as work moves;
    # one Slack kept refusing was retried for as long as its task existed and
    # listed nowhere, so nobody learned the message or channel was gone.
    task_cards =
      TaskCard.Query.blocked()
      |> TaskCard.Query.ordered_by_recently_updated()
      |> TaskCard.Query.limit_to(deep.("slack_task_card"))
      |> Repo.all()
      |> Enum.map(&task_card_item/1)

    thread_statuses =
      ThreadStatus.Query.blocked()
      |> ThreadStatus.Query.ordered_by_recently_updated()
      |> ThreadStatus.Query.limit_to(deep.("slack_thread_status"))
      |> Repo.all()
      |> Enum.map(&thread_status_item/1)

    publications =
      @running_publication_statuses
      |> Failure.Query.failing_publications()
      |> Failure.Query.limit_to(deep.("publication"))
      |> Repo.all()
      |> Enum.map(&publication_item/1)

    # Learning that only a person can move was listed only on the Learning
    # page, so nothing here said a conversation had stopped being learned.
    learning =
      Failure.Query.stalled_learning()
      |> Failure.Query.limit_to(deep.("learning"))
      |> Repo.all()
      |> Enum.map(&learning_item/1)

    with {:ok, delivery_items} <- DeliveryOperator.list_blocked(deep.("delivery")),
         {:ok, emisar_items} <- EmisarOperator.failures(deep.("emisar")) do
      failures =
        work ++
          admission ++
          Enum.map(delivery_items, &delivery_item/1) ++
          retention ++
          stopping ++
          interaction_feedback ++
          incident_rooms ++
          task_cards ++
          thread_statuses ++
          publications ++
          learning ++
          Enum.map(emisar_items, &emisar_item/1)

      open =
        failures
        |> FailureDismissals.reject_left()
        |> Enum.map(&Map.put(&1, :left_at, nil))
        |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc)

      older =
        cond do
          length(open) <= page * @page_size -> :none
          page == @maximum_page -> :unlisted
          true -> :next_page
        end

      rows = open |> Enum.slice((page - 1) * @page_size, @page_size) |> decorate_failures()
      {:ok, %{rows: rows, older: older}}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  @doc "How many failures one page of the list holds."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "The deepest page the list reads; each page reads every kind that deep."
  @spec maximum_page() :: pos_integer()
  def maximum_page, do: @maximum_page

  @doc "The page `params` ask for: a whole number up to the deepest page, else the first."
  @spec page_number(map()) :: pos_integer()
  def page_number(%{"page" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page in 1..@maximum_page -> page
      {page, ""} when page > @maximum_page -> @maximum_page
      _other -> 1
    end
  end

  def page_number(_params), do: 1

  @doc """
  Every kind of failure the list shows, each with its own page.

  The detail route used to keep its own copy of this list, and a new kind
  listed on Failures opened "This failure does not exist" until someone
  remembered the copy. It happened to publications and then to learning.
  """
  def kinds, do: @kinds

  @doc """
  One blocked item by kind and reference, decorated exactly as the list
  decorates it, or `:not_found` once it is no longer blocked.

  A failure's own page and its confirmation read this rather than searching
  the list, which is bounded to a hundred rows: the hundred-and-first failure
  was listed nowhere and could not be opened.
  """
  def fetch(kind, ref) do
    case failure_exact(kind, ref) do
      {:ok, item} ->
        {:ok, item |> decorate_failure() |> Map.put(:left_at, FailureDismissals.left_at(item))}

      other ->
        other
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp failure_exact("admission", ref), do: admission(ref)
  defp failure_exact("delivery", ref), do: delivery(ref)
  defp failure_exact("emisar", ref), do: emisar(ref)
  defp failure_exact("slack_incident", ref), do: slack_incident(ref)
  defp failure_exact("slack_interaction", ref), do: slack_interaction(ref)
  defp failure_exact("slack_task_card", ref), do: slack_task_card(ref)
  defp failure_exact("slack_thread_status", ref), do: slack_thread_status(ref)
  defp failure_exact("work", ref), do: work(ref)

  defp failure_exact("publication", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    found = Repo.one(Failure.Query.failing_publication(@running_publication_statuses, ref))
    if found, do: {:ok, publication_item(found)}, else: :not_found
  end

  defp failure_exact("retention", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    found = Repo.one(Failure.Query.blocked_cleanup(ref))
    if found, do: {:ok, retention_item(found)}, else: :not_found
  end

  defp failure_exact("stopping", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    found =
      Cancellation.stalled_after_attempts()
      |> Failure.Query.stalled_stops()
      |> Failure.Query.by_episode_key(ref)
      |> Repo.one()

    if found, do: {:ok, stopping_item(found)}, else: :not_found
  end

  defp failure_exact("learning", ref) do
    with {:ok, id} <- Ecto.UUID.cast(ref),
         %LearningBatch{} = batch <- Repo.one(Failure.Query.stalled_batch(id)) do
      {:ok, learning_item(batch)}
    else
      _missing -> :not_found
    end
  end

  defp failure_exact(_kind, _ref), do: :not_found

  def delivery(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case DeliveryOperator.fetch(ref) do
      {:ok, %{status: :blocked} = item} -> {:ok, delivery_item(item)}
      {:ok, _item} -> :not_found
      {:error, _reason} -> :not_found
    end
  end

  def delivery(_ref), do: :not_found

  def admission(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Inbox.fetch(ref) do
      {:ok, %Entry{status: :blocked} = entry} -> {:ok, admission_item(entry)}
      _unavailable -> :not_found
    end
  end

  def admission(_ref), do: :not_found

  def work(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case blocked_work(ref) do
      nil -> :not_found
      row -> {:ok, row |> work_item() |> List.wrap() |> attach_work_recovery() |> hd()}
    end
  end

  def work(_ref), do: :not_found

  # A blocked watch is a failure while its task could still continue from it;
  # a watching one only while a task waits for it and nothing can make
  # progress on it (`Ryker.Operator.Emisar.failures/1`).
  def emisar(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case EmisarOperator.fetch(ref) do
      {:ok, %{status: :blocked, wait: wait} = item} when wait != :ended ->
        {:ok, emisar_item(item)}

      {:ok, %{status: :monitoring, stall: stall} = item} when not is_nil(stall) ->
        {:ok, emisar_item(item)}

      _unavailable ->
        :not_found
    end
  end

  def emisar(_ref), do: :not_found

  def slack_interaction(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(InteractionAudit.Query.by_event_ref(ref)) do
      %InteractionAudit{repaint_status: :blocked} = audit -> {:ok, interaction_item(audit)}
      _unavailable -> :not_found
    end
  end

  def slack_interaction(_ref), do: :not_found

  def slack_incident(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(IncidentRoom.Query.by_ref(ref)) do
      %IncidentRoom{status: :blocked} = room -> {:ok, incident_item(room)}
      _unavailable -> :not_found
    end
  end

  def slack_incident(_ref), do: :not_found

  def slack_task_card(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(TaskCard.Query.by_ref(ref)) do
      %TaskCard{status: :blocked} = card -> {:ok, task_card_item(card)}
      _unavailable -> :not_found
    end
  end

  def slack_task_card(_ref), do: :not_found

  # A thread status has no reference of its own beyond its row id.
  def slack_thread_status(ref) when is_binary(ref) do
    with {:ok, id} <- Ecto.UUID.cast(ref),
         %ThreadStatus{status: :blocked} = status <- Repo.one(ThreadStatus.Query.by_id(id)) do
      {:ok, thread_status_item(status)}
    else
      _unavailable -> :not_found
    end
  end

  def slack_thread_status(_ref), do: :not_found

  # A routing response (a reaction or quick reply) belongs to an input rather
  # than an episode; its input id is what finds the conversation and source it
  # answered. A weekly report belongs to neither and names its channel.
  defp delivery_item(item) do
    %{
      action: :rearm,
      attempt_count: item.attempt_count,
      destination: Map.get(item, :destination),
      detail: FailureDetail.project(item.error_detail),
      diagnosis: FailureDetail.facts(item.error_detail),
      episode_id: Map.get(item, :episode_id),
      delivery_kind: item.kind,
      input_id: Map.get(item, :input_id),
      kind: "delivery",
      provider_error: provider_error(item.error_detail),
      ref: item.delivery_ref,
      source: "#{item.kind} delivery",
      status: item.status,
      summary: item.error_code || "delivery blocked",
      updated_at: item.updated_at
    }
  end

  defp admission_item(%Entry{} = entry) do
    %{
      action: :rearm,
      attempt_count: entry.attempt_count,
      detail: FailureDetail.project(entry.last_error_detail),
      diagnosis: FailureDetail.facts(entry.last_error_detail),
      cause: explained_cause(entry.last_error_detail),
      destination: failure_destination(entry),
      episode_id: entry.episode_id,
      kind: "admission",
      ref: Inbox.ref(entry),
      source: "#{entry.source_kind}:#{entry.source_ref} · #{entry.event_ref}",
      status: entry.status,
      summary: entry.last_error_code || "admission blocked",
      updated_at: entry.updated_at
    }
  end

  defp blocked_work(ref) do
    Failure.Query.blocked_work() |> Failure.Query.by_episode_key(ref) |> Repo.one()
  end

  # A row is cheap until the page is cut: its recovery brief (custody reads
  # and a question to the fleet) and its paused room are read for the rows the
  # page shows (`attach_work_recovery/1`), not for every row each kind fetched
  # to fill it (2026-10-04 review).
  defp work_item({%Turn{} = turn, %Episode{} = episode}) do
    %{
      action: nil,
      attempt_count: max(turn.work_attempt_count, turn.cancel_attempt_count),
      detail: FailureDetail.project(turn.last_error_detail),
      diagnosis: FailureDetail.facts(turn.last_error_detail),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "work",
      ref: episode.key,
      session_id: turn.session_id,
      source: turn.execution_target,
      status: turn.status,
      stop_code: stop_code(turn),
      summary: turn.last_error_code || "work blocked",
      updated_at: turn.updated_at,
      work: {turn, episode}
    }
  end

  defp attach_work_recovery(items) do
    Enum.map(items, fn
      %{kind: "work", work: {turn, episode}} = item ->
        recovery = Recovery.brief(turn)
        paused_room = paused_room(item.stop_code, episode)

        item
        |> Map.delete(:work)
        |> Map.merge(%{
          # A task whose room was deleted is closed by Ryker itself; running it
          # again would only post into a room that no longer exists.
          action: if(room_deleted?(paused_room), do: nil, else: recovery.action),
          paused_room: paused_room,
          work_recovery: recovery
        })

      item ->
        item
    end)
  end

  # The incident room a paused task waits for. An archived room can become
  # active again and the task resumes; a deleted one never can, so its task
  # closes instead, and the page must not promise otherwise.
  defp paused_room("destination_paused", %Episode{id: episode_id}),
    do: Repo.one(Failure.Query.room_of(episode_id))

  defp paused_room(_stop_code, _episode), do: nil

  defp interaction_item(%InteractionAudit{} = audit) do
    %{
      action: :rearm,
      attempt_count: audit.attempt_count,
      detail: FailureDetail.project(audit.last_error_detail),
      diagnosis: FailureDetail.facts(audit.last_error_detail),
      destination:
        join_target("slack:#{audit.workspace_ref}:#{audit.channel_ref}", audit.thread_ref),
      kind: "slack_interaction",
      action_id: audit.action_id,
      outcome: audit.outcome,
      provider_error: provider_error(audit.last_error_detail),
      ref: audit.event_ref,
      # Who pressed it is a person, shown as every person is; the control is
      # the source (until 2026-09-26 both were one raw "U… · action" line).
      pressed_by: Names.person(audit.workspace_ref, audit.actor_ref),
      source: audit.action_id,
      status: audit.repaint_status,
      summary: audit.last_error_code || "Slack repaint blocked",
      updated_at: audit.updated_at
    }
  end

  defp incident_item(%IncidentRoom{} = room) do
    %{
      action: :rearm,
      attempt_count: room.attempt_count || 0,
      detail: FailureDetail.project(room.last_error_detail),
      diagnosis: FailureDetail.facts(room.last_error_detail),
      destination:
        join_target(
          "slack:#{room.workspace_ref}:#{room.source_channel_ref}",
          room.source_thread_ref
        ),
      automatic: String.starts_with?(room.confirmation_ref || "", "automatic-alert:"),
      channel_ref: room.channel_ref,
      channel_state: room.channel_state,
      episode_id: room.episode_id || room.source_episode_id,
      kind: "slack_incident",
      provider_error: provider_error(room.last_error_detail),
      ref: room.ref,
      setup_step: setup_step(room),
      title: room.title,
      source: room.source_message_ref,
      status: room.status,
      summary: room.last_error_code || "Slack incident-room reconciliation blocked",
      updated_at: room.updated_at
    }
  end

  defp task_card_item(%TaskCard{} = card) do
    %{
      action: :rearm,
      attempt_count: card.attempt_count,
      detail: FailureDetail.project(card.last_error_detail),
      diagnosis: FailureDetail.facts(card.last_error_detail),
      destination:
        join_target("slack:#{card.workspace_ref}:#{card.channel_ref}", card.thread_ref),
      episode_id: card.episode_id,
      kind: "slack_task_card",
      provider_error: provider_error(card.last_error_detail),
      ref: card.ref,
      source: card.message_ref,
      status: card.status,
      summary: card.last_error_code || "Slack task card update blocked",
      updated_at: card.updated_at
    }
  end

  # The status belongs to the request that wanted it shown, when one did; a
  # status a message wanted before any request existed names no request.
  defp thread_status_item(%ThreadStatus{} = status) do
    %{
      action: :rearm,
      attempt_count: status.attempt_count,
      desired_text: status.desired_text,
      detail: FailureDetail.project(status.last_error_detail),
      diagnosis: FailureDetail.facts(status.last_error_detail),
      destination:
        join_target("slack:#{status.workspace_ref}:#{status.channel_ref}", status.thread_ref),
      episode_id: if(status.origin_kind == "episode", do: status.origin_id),
      kind: "slack_thread_status",
      phase: status.phase,
      provider_error: provider_error(status.last_error_detail),
      ref: status.id,
      source: nil,
      status: status.status,
      summary: status.last_error_code || "Slack thread status blocked",
      updated_at: status.updated_at
    }
  end

  # A watch nothing can make progress on is not blocked, so there is nothing
  # to rearm: the fix is the account's monitoring switch or its token, and the
  # watch goes on by itself once that is fixed.
  defp emisar_item(item) do
    %{
      action: if(item.status == :blocked, do: :rearm),
      attempt_count: item.failure_count,
      detail: FailureDetail.project(item.last_error),
      diagnosis: FailureDetail.facts(item.last_error),
      action_id: item.action_id,
      approval_url: item.approval_url,
      connection_ref: item.connection_ref,
      episode_id: item.episode_id,
      expires_at: item.expires_at,
      kind: "emisar",
      ref: item.ref,
      request_id: item.request_id,
      source: "#{item.connection_ref} · #{item.runner_ref} · #{item.action_id}",
      stall: item.stall,
      status: item.status,
      summary: emisar_stall_code(item.stall) || emisar_reason(item.last_error),
      updated_at: item.updated_at
    }
  end

  defp emisar_stall_code(:monitoring_off), do: "emisar_monitoring_off"
  defp emisar_stall_code(:token_unavailable), do: "emisar_token_unavailable"
  defp emisar_stall_code(nil), do: nil

  defp retention_item({%Session{} = session, episode}) do
    %{
      action: :rearm,
      attempt_count: session.cleanup_attempt_count,
      detail: FailureDetail.project(session.cleanup_last_error_detail),
      diagnosis: FailureDetail.facts(session.cleanup_last_error_detail),
      cleanup_phase: session.cleanup_blocked_from,
      request_state: episode && episode.state,
      closed_at: session.closed_at,
      discarded_at: session.discarded_at,
      destination: episode && failure_destination(episode),
      episode_id: episode && episode.id,
      episode_ref: episode && episode.key,
      execution_kind: session.execution_kind,
      kind: "retention",
      policy: session.policy,
      ready_state: session.ready_state,
      ref: session.external_ref,
      session_id: session.id,
      source: session.repository_ref || "no repository",
      status: session.cleanup_status,
      summary: session.cleanup_last_error_code || "retention blocked",
      updated_at: session.updated_at
    }
  end

  # No retry: Ryker is already retrying it. What a person can change is the
  # worker, which the explanation reads from the attached worker facts.
  defp stopping_item({%Turn{} = turn, %Episode{} = episode}) do
    %{
      action: nil,
      attempt_count: turn.cancel_attempt_count,
      detail: FailureDetail.project(turn.last_error_detail),
      diagnosis: FailureDetail.facts(turn.last_error_detail),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "stopping",
      ref: episode.key,
      session_id: turn.session_id,
      source: turn.execution_target,
      status: turn.status,
      stop_intent: turn.cancellation_intent["action"],
      summary: turn.last_error_code || "stop pending",
      updated_at: turn.updated_at
    }
  end

  # A publication that keeps failing was invisible: not a failure kind here, and
  # not action_needed on its task card until it is `:blocked`. Production ran two
  # for days — 2,902 attempts against a Coop session that closed on the 10th, and
  # 1,087 against a repository whose GitHub App is not installed — while this
  # page, whose question is "what is broken and can I retry it?", said nothing.
  # A recorded failure is the same evidence custody already requires before it
  # offers recovery: a publication that is merely slow is not stuck. A closed
  # session no longer lands here: Ryker discards that publication itself.
  defp publication_item({%Publication{} = publication, %Episode{} = episode}) do
    %{
      action: nil,
      attempt_count: publication.attempt_count || 0,
      detail: FailureDetail.project(publication.last_error_detail),
      diagnosis: FailureDetail.facts(publication.last_error_detail),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "publication",
      ref: publication.ref,
      source: publication.repository || "no repository",
      status: publication.status,
      summary: publication.last_error_code || "publication blocked",
      updated_at: publication.updated_at
    }
  end

  # No retry here: a start can be a model call, so it is granted on the
  # Learning page, next to why each earlier attempt stopped.
  defp learning_item(%LearningBatch{} = batch) do
    %{
      action: nil,
      attempt_count: batch.start_count,
      attempt_error: nil,
      destination: batch.conversation_ref,
      execution_kind: :learning,
      input_count: batch.input_count,
      kind: "learning",
      learning_path: LearningActivity.path(batch.id),
      relearn_path: nil,
      learning: batch,
      policy: batch.policy,
      ref: batch.id,
      source: batch.repository_ref || "no repository",
      start_limit: batch.start_limit,
      status: batch.status,
      summary: LearningActivity.cause_code(batch) || "learning_deferred",
      updated_at: batch.updated_at
    }
  end

  # What a shown batch's last attempt stopped on, so its page can say it in
  # words, and where to relearn what it stopped on: read for the rows the page
  # shows, after the cut (2026-10-04 review).
  defp attach_learning_causes(items) do
    Enum.map(items, fn
      %{kind: "learning", learning: batch} = item ->
        item
        |> Map.delete(:learning)
        |> Map.merge(%{
          attempt_error: last_attempt_error(batch.id),
          relearn_path: relearn_path(LearningActivity.relearn_topics(batch))
        })

      item ->
        item
    end)
  end

  # What the batch's last attempt stopped on, so its page can say it in words.
  defp last_attempt_error(batch_id), do: Repo.one(Failure.Query.last_attempt_error(batch_id))

  # Where to relearn the topics a batch stopped on: the topic itself when
  # there is one, the Learned list when there are several.
  defp relearn_path([]), do: nil
  defp relearn_path([topic]), do: topic.path
  defp relearn_path(_topics), do: "/memory/learned"

  defp decorate_failures(items) do
    items
    |> attach_work_recovery()
    |> attach_learning_causes()
    |> attach_input_contexts()
    |> attach_deleted_rooms()
    |> attach_episode_contexts()
    |> attach_session_workers()
    |> attach_live_state()
    |> Activity.with_request_titles()
    |> name_repositories()
    |> Enum.map(&failure_defaults/1)
  end

  # A stopped cleanup or learning pass names its repository by its ref; it
  # reads as owner/repo, even after the repository was removed.
  @repository_sources ["retention", "learning"]
  defp name_repositories(items) do
    if Enum.any?(items, &(Map.get(&1, :kind) in @repository_sources)) do
      names = RepositoryNames.all()

      Enum.map(items, fn
        %{kind: kind, source: source} = item when kind in @repository_sources ->
          %{item | source: RepositoryNames.name(names, source)}

        item ->
          item
      end)
    else
      items
    end
  end

  # A reply owed to an incident room Slack deleted can never be posted there,
  # so Ryker moves it to the alert thread the room was opened from on its own:
  # there is nothing to retry until it is moved, and once moved it posts to
  # that thread, which the row names. The page never asks anyone to bring back
  # a room that cannot come back.
  defp attach_deleted_rooms(items) do
    replies =
      items
      |> Enum.filter(&room_reply?/1)
      |> Enum.map(& &1.ref)
      |> deleted_room_replies()

    Enum.map(items, fn item ->
      case room_reply?(item) && Map.get(replies, item.ref) do
        {%{reply: :moved} = room, alert_thread} ->
          Map.merge(item, %{destination: alert_thread, incident_room: room})

        # Posting it again into the deleted room would only be refused.
        {%{reply: :in_room} = room, _alert_thread} ->
          Map.merge(item, %{action: nil, incident_room: room})

        _not_owed_to_a_deleted_room ->
          item
      end
    end)
  end

  defp room_deleted?(%{channel_state: :deleted}), do: true
  defp room_deleted?(_room), do: false

  defp room_reply?(%{kind: "delivery", delivery_kind: :message}), do: true
  defp room_reply?(_item), do: false

  defp deleted_room_replies([]), do: %{}

  defp deleted_room_replies(delivery_refs) do
    delivery_refs
    |> Failure.Query.replies_to_deleted_rooms()
    |> Repo.all()
    |> Enum.flat_map(fn {delivery_ref, target, room} ->
      case owed_room_reply(target, room) do
        nil -> []
        reply -> [{delivery_ref, reply}]
      end
    end)
    |> Map.new()
  end

  # A reply without a frozen target posts to its request's home: the room.
  defp owed_room_reply(target, room) do
    alert_thread = IncidentRooms.alert_thread(room)

    reply =
      cond do
        target == alert_thread ->
          :moved

        is_nil(target) ->
          :in_room

        target["conversation_ref"] == "slack:#{room.workspace_ref}:#{room.channel_ref}" ->
          :in_room

        true ->
          nil
      end

    if reply do
      {%{channel_name: room.channel_name, channel_state: room.channel_state, reply: reply},
       join_target(alert_thread["conversation_ref"], alert_thread["thread_ref"])}
    end
  end

  # Whether the worker that held a session could take it back right now.
  #
  # A session's cleanup, and a finished task's saving, can only run on the
  # worker that holds it, and only while that worker still reports, still
  # runs the exact policy version the session started with and has a free
  # slot. Placement decides that under a lock
  # (`Placements.recover_placement_on_previous_worker/5`); this reads the same
  # facts without taking anything, so the page can say whether a retry would
  # stop the same way before anyone presses it. The action itself is still
  # decided by placement, never by this read.
  defp attach_session_workers(items) do
    session_ids =
      items
      |> Enum.map(&Map.get(&1, :session_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    workers = session_workers(session_ids)

    Enum.map(items, fn item ->
      case Map.fetch(workers, Map.get(item, :session_id)) do
        {:ok, worker} -> Map.put(item, :worker, worker)
        :error -> item
      end
    end)
  end

  defp session_workers([]), do: %{}

  defp session_workers(session_ids) do
    now = Repo.now!()

    session_ids
    |> Failure.Query.session_workers()
    |> Repo.all()
    |> Map.new(fn {placement, session, worker} ->
      {placement.session_id, session_worker(placement, session, worker, now)}
    end)
  end

  defp session_worker(placement, _session, nil, _now),
    do: %{id: placement.worker_id, enrolled: false}

  defp session_worker(placement, session, %Worker{} = worker, now) do
    requirements = placement.requirements || %{}

    %{
      id: worker.id,
      enrolled: worker.state != :revoked and is_nil(worker.revoked_at),
      draining: worker.state == :draining or not is_nil(worker.drain_requested_at),
      reporting: reporting?(worker, now),
      last_seen_at: worker.last_seen_at,
      job_valid: match?({:ok, _session}, JobAuthority.validate(session)),
      setup_current: setup_current?(worker, requirements),
      free_slot:
        Enum.all?(
          ~w(session turn workspace),
          &(Map.get(worker.capacity || %{}, "#{&1}_slots_free", 0) > 0)
        )
    }
  end

  defp setup_current?(worker, requirements) do
    capabilities = Map.new(worker.capabilities || [], &{&1["name"], &1["version"]})

    worker.protocol_version == "2" and
      worker.workspace_ref == requirements["workspace_ref"] and
      worker.sandbox_digest == requirements["sandbox_digest"] and
      Enum.all?(requirements["capability_names"] || [], &Map.has_key?(capabilities, &1)) and
      Enum.all?(requirements["capability_versions"] || %{}, fn {name, version} ->
        capabilities[name] == version
      end)
  end

  defp reporting?(%Worker{last_seen_at: %DateTime{} = seen} = worker, now) do
    worker.state in [:eligible, :busy] and is_nil(worker.drain_requested_at) and
      is_nil(worker.revoked_at) and
      DateTime.diff(now, seen, :second) <= Worker.heartbeat_seconds()
  end

  defp reporting?(_worker, _now), do: false

  defp decorate_failure(item), do: item |> List.wrap() |> decorate_failures() |> hd()

  defp attach_input_contexts(items) do
    input_ids =
      items
      |> Enum.map(&Map.get(&1, :input_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts = input_ids |> Entry.Query.by_ids() |> Repo.all() |> Map.new(&{&1.id, &1})

    Enum.map(items, fn item ->
      case Map.get(contexts, Map.get(item, :input_id)) do
        %Entry{} = entry ->
          item
          |> Map.put(:episode_id, entry.episode_id)
          |> Map.put(:destination, failure_destination(entry))
          |> Map.put(:source, "#{entry.source_kind}:#{entry.source_ref} · #{entry.event_ref}")

        nil ->
          item
      end
    end)
  end

  defp attach_episode_contexts(items) do
    episode_ids =
      items
      |> Enum.map(&Map.get(&1, :episode_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts = episode_ids |> Episode.Query.by_ids() |> Repo.all() |> Map.new(&{&1.id, &1})

    Enum.map(items, fn item ->
      case Map.get(contexts, Map.get(item, :episode_id)) do
        %Episode{} = episode ->
          item
          |> put_if_nil(:episode_ref, episode.key)
          |> put_if_nil(:destination, failure_destination(episode))
          |> put_if_nil(:request_state, episode.state)

        nil ->
          item
      end
    end)
  end

  @doc """
  The code a stopped task's saved error names, never the term around it.

  A block the dispatcher requested saves "<code>: <term>" under the generic
  code work_execution_blocked, so every stopped task read
  "work_execution_blocked" on the Failures page. A person's Stop saves
  operator_stop itself (`Ryker.Work.Cancellation.new_stop/2`).
  """
  @spec stop_code(Turn.t()) :: String.t() | nil
  def stop_code(%Turn{last_error_code: "work_execution_blocked", last_error_detail: detail})
      when is_binary(detail) do
    cond do
      # A run paused for its incident room saves the pause's own reason.
      String.starts_with?(detail, "destination_paused:") ->
        "destination_paused"

      match =
          Regex.run(
            ~r/\A(work_retry_exhausted): \{:work_retry_exhausted, \{:([a-z_]{1,80})/,
            detail
          ) ->
        "work_retry_exhausted:" <> List.last(match)

      match = Regex.run(~r/\A([a-z_]{1,80}): /, detail) ->
        List.last(match)

      true ->
        nil
    end
  end

  def stop_code(%Turn{last_error_code: code}), do: code

  @provider_errors ~w(not_in_channel channel_not_found is_archived invalid_auth token_revoked
    token_expired account_inactive missing_scope not_authed no_permission restricted_action
    message_not_found thread_not_found cant_update_message edit_window_closed user_not_found
    ratelimited fatal_error internal_error request_timeout service_unavailable
    team_access_not_granted ekm_access_denied name_taken)

  @doc """
  Slack's own error word when a saved error carries one, from a closed list.

  The word is what tells "invite Ryker to the channel" apart from "reconnect
  Slack", and the rest of the saved term never leaves the row.
  """
  @spec provider_error(String.t() | nil) :: String.t() | nil
  def provider_error(detail) when is_binary(detail) do
    case Regex.run(~r/\{:slack_api_error, "([a-z_]{1,60})"\}/, detail) do
      [_, code] -> if code in @provider_errors, do: code
      nil -> nil
    end
  end

  def provider_error(_detail), do: nil

  # A provider's own sentence, unescaped, redacted and bounded once by
  # FailureCause, for the saved errors it can read; nil otherwise.
  defp explained_cause(detail) do
    case FailureCause.explain(detail) do
      %{cause: cause} -> cause
      nil -> nil
    end
  end

  # The first setup step without its receipt is where a room stopped.
  defp setup_step(%IncidentRoom{channel_ref: nil}), do: :channel
  defp setup_step(%IncidentRoom{root_message_ref: nil}), do: :root
  defp setup_step(%IncidentRoom{audience_prepared_at: nil}), do: :audience
  defp setup_step(%IncidentRoom{topic_prepared_at: nil}), do: :topic
  defp setup_step(%IncidentRoom{root_pinned_at: nil}), do: :pin
  defp setup_step(%IncidentRoom{handoff_message_ref: nil}), do: :handoff
  defp setup_step(%IncidentRoom{}), do: :finalize

  # Whether what stopped a failure has changed since: the Slack connection and
  # the bot's place in the channel for Slack work, and whether any worker is
  # reporting for work that needs one. Each is read once per page, and only
  # when a row needs it.
  defp attach_live_state(items) do
    live = %{
      slack: if(Enum.any?(items, &slack_row?/1), do: slack_live(items)),
      fleet: if(Enum.any?(items, &fleet_row?/1), do: fleet_state()),
      emisar: if(Enum.any?(items, &(&1.kind == "emisar")), do: emisar_state(items)),
      publishing: if(Enum.any?(items, &(&1.kind == "publication")), do: publishing_repositories())
    }

    Enum.map(items, &with_live(&1, live))
  end

  defp with_live(item, live) do
    item
    |> put_live(:slack, live.slack && slack_row?(item) && slack_state(item, live.slack))
    |> put_live(:fleet, live.fleet && fleet_row?(item) && live.fleet)
    |> put_live(:emisar, approval_watch(item, live.emisar))
    |> put_live(:publishing, publishing(item, live.publishing))
  end

  defp fleet_row?(item), do: item.kind in ["admission", "work"]

  defp approval_watch(%{kind: "emisar", ref: ref}, %{} = emisar), do: Map.get(emisar, ref)
  defp approval_watch(_item, _emisar), do: nil

  defp publishing(%{kind: "publication", source: repository}, %MapSet{} = repositories),
    do: %{configured: MapSet.member?(repositories, repository)}

  defp publishing(_item, _repositories), do: nil

  defp slack_live(items), do: %{connection: slack_connection(), memberships: memberships(items)}

  defp put_live(item, _key, value) when value in [nil, false], do: item
  defp put_live(item, key, value), do: Map.put(item, key, value)

  defp slack_row?(item) do
    item.kind in [
      "delivery",
      "slack_interaction",
      "slack_incident",
      "slack_task_card",
      "slack_thread_status"
    ] and
      slack_channel(item) != nil
  end

  @doc """
  The Slack workspace and channel a failure's destination names
  (`slack:<workspace>:<channel> / <thread>`), or nil for any other place.
  """
  @spec slack_channel(map()) :: {String.t(), String.t()} | nil
  def slack_channel(%{destination: "slack:" <> rest}) do
    [conversation | _thread] = String.split(rest, " / ", parts: 2)

    case String.split(conversation, ":", parts: 2) do
      [workspace, channel] -> {workspace, channel}
      _other -> nil
    end
  end

  def slack_channel(_item), do: nil

  defp slack_state(item, slack),
    do: %{
      connection: slack.connection.state,
      renewed_at: slack.connection.renewed_at,
      membership: Map.get(slack.memberships, slack_channel(item))
    }

  defp slack_connection do
    state =
      case ProductReadiness.current() do
        %{slack: %{state: state}} -> state
        _other -> :unknown
      end

    # When Slack's bot sign-in was last saved or checked: a refusal older than
    # that may already be fixed.
    renewed =
      Credentials.statuses()
      |> Enum.filter(&(&1.kind == :slack_bot))
      |> Enum.flat_map(&[&1[:verified_at], &1[:updated_at]])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    %{state: state, renewed_at: renewed}
  end

  defp memberships(items) do
    items
    |> Enum.filter(&slack_row?/1)
    |> Enum.map(&slack_channel/1)
    |> Enum.uniq()
    |> Map.new(fn {workspace, channel} = key ->
      {key,
       case ChannelConfigurations.fetch_membership(workspace, channel) do
         {:ok, %{status: status}} -> status
         {:error, :not_found} -> nil
       end}
    end)
  end

  defp fleet_state do
    case Observability.fleet() do
      {:ok, fleet} -> %{reporting: fleet.eligible_workers, fresh: fleet.fresh_workers}
      {:error, _reason} -> nil
    end
  end

  # Whether anything watches the approval's connection now, whether its token
  # was replaced after monitoring stopped, and when the approval expires.
  defp emisar_state(items) do
    monitored =
      case Config.get_env(:emisar) do
        %{connections: connections} -> MapSet.new(connections, & &1.connection_ref)
        _none -> MapSet.new()
      end

    rows = Enum.filter(items, &(&1.kind == "emisar"))

    Map.new(rows, fn row ->
      token = Credentials.status(:emisar, row[:connection_ref] || "")

      {row.ref,
       %{
         monitored: MapSet.member?(monitored, row[:connection_ref]),
         token_changed_at: token[:updated_at],
         expires_at: row[:expires_at]
       }}
    end)
  end

  # The repositories the running configuration can publish to right now.
  defp publishing_repositories do
    case Config.get_env(:publication) do
      %{repositories: repositories} when is_map(repositories) ->
        MapSet.new(Map.keys(repositories))

      _none ->
        MapSet.new()
    end
  end

  # What kind of refusal stopped an approval watch, as a code: Emisar's HTTP
  # status, a protocol mismatch, or a message Ryker could not update. The
  # saved term itself stays in the row.
  defp emisar_reason(error) when is_binary(error) do
    cond do
      String.starts_with?(error, ":emisar_approval_identity_mismatch") ->
        "emisar_approval_identity_mismatch"

      match = Regex.run(~r/\A\{:emisar_http_error, ([1-5]\d{2})/, error) ->
        "emisar_http_" <> List.last(match)

      String.starts_with?(error, "{:emisar_protocol_error, :review") ->
        "emisar_review_unreadable"

      String.starts_with?(error, "{:emisar_protocol_error") ->
        "emisar_protocol_error"

      String.starts_with?(error, "{:invalid_emisar_client") ->
        "invalid_emisar_client"

      String.starts_with?(error, "{:emisar_approval_presentation_permanent") ->
        "emisar_approval_presentation_failed"

      true ->
        "emisar_approval_monitoring_blocked"
    end
  end

  defp emisar_reason(_error), do: "emisar_approval_monitoring_blocked"

  defp failure_defaults(item) do
    Map.merge(
      %{
        attempt_count: 0,
        detail: nil,
        destination: nil,
        episode_ref: nil,
        source: nil
      },
      item
    )
  end

  defp put_if_nil(map, key, value) do
    if is_nil(Map.get(map, key)), do: Map.put(map, key, value), else: map
  end

  defp failure_destination(%{destination_transport: transport} = owner) do
    conversation = owner.destination_conversation_ref

    target =
      if String.starts_with?(conversation, "#{transport}:"),
        do: conversation,
        else: "#{transport}:#{conversation}"

    join_target(target, owner.destination_thread_ref)
  end

  defp join_target(target, nil), do: target
  defp join_target(target, thread), do: "#{target} / #{thread}"
end
