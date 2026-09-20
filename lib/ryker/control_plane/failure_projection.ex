defmodule Ryker.ControlPlane.FailureProjection do
  @moduledoc """
  The Failures page: every blocked item an operator can retry, across work,
  admission, delivery, retention, Slack repaint, incident rooms, publications
  and Emisar approvals, each with the host's own diagnosis and never a raw
  error body.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Activity, WorkRecovery}
  alias Ryker.Delivery.Operator, as: DeliveryOperator
  alias Ryker.Emisar.Operator, as: EmisarOperator
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.FailureDetail
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, InteractionAudit}
  alias Ryker.Work.{Session, Turn}

  @doc """
  Every blocked item, newest first, bounded to a hundred; `{:error, :unavailable}`
  when the database cannot answer, so a broken read never renders as nothing wrong.
  """
  def list(_params) do
    work =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on:
            episode.id == turn.episode_id and episode.state == :working and
              episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
          where: turn.status == :blocked and is_nil(turn.delivery_ref),
          order_by: [desc: turn.updated_at, desc: turn.id],
          limit: 100,
          select: {turn, episode}
        )
      )
      |> Enum.map(&work_item/1)

    admission =
      Repo.all(
        from(entry in Entry,
          where: entry.status == :blocked,
          order_by: [desc: entry.updated_at, desc: entry.id],
          limit: 100
        )
      )
      |> Enum.map(&admission_item/1)

    # A learning session has no episode; an inner join hid every blocked
    # learning cleanup from this page and from its retry.
    retention =
      Repo.all(
        from(session in Session,
          left_join: episode in Episode,
          on: episode.id == session.episode_id,
          where: session.cleanup_status == :blocked,
          order_by: [desc: session.updated_at, desc: session.id],
          limit: 100,
          select: {session, episode}
        )
      )
      |> Enum.map(&retention_item/1)

    interaction_feedback =
      Repo.all(
        from(audit in InteractionAudit,
          where: audit.repaint_status == :blocked,
          order_by: [desc: audit.updated_at, desc: audit.id],
          limit: 100,
          select: audit
        )
      )
      |> Enum.map(&interaction_item/1)

    incident_rooms =
      Repo.all(
        from(room in IncidentRoom,
          where: room.status == :blocked,
          order_by: [desc: room.updated_at, desc: room.id],
          limit: 100
        )
      )
      |> Enum.map(&incident_item/1)

    publications =
      Repo.all(
        from(publication in Publication,
          join: episode in Episode,
          on: episode.id == publication.episode_id,
          where:
            publication.status not in [:published, :discarded] and
              not is_nil(publication.last_error_code),
          order_by: [desc: publication.updated_at, desc: publication.id],
          limit: 100,
          select: {publication, episode}
        )
      )
      |> Enum.map(&publication_item/1)

    with {:ok, delivery_items} <- DeliveryOperator.list_blocked(100),
         {:ok, emisar_items} <- EmisarOperator.list_blocked(100) do
      failures =
        work ++
          admission ++
          Enum.map(delivery_items, &delivery_item/1) ++
          retention ++
          interaction_feedback ++
          incident_rooms ++
          publications ++
          Enum.map(emisar_items, &emisar_item/1)

      {:ok,
       failures
       |> decorate_failures()
       |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc)
       |> Enum.take(100)}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  @doc "One blocked item by kind and reference, or `:not_found` once it is no longer blocked."
  def fetch(kind, ref) do
    failure_exact(kind, ref)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp failure_exact("admission", ref), do: admission(ref)
  defp failure_exact("delivery", ref), do: delivery(ref)
  defp failure_exact("emisar", ref), do: emisar(ref)
  defp failure_exact("slack_incident", ref), do: slack_incident(ref)
  defp failure_exact("slack_interaction", ref), do: slack_interaction(ref)
  defp failure_exact("work", ref), do: work(ref)

  defp failure_exact("publication", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(publication in Publication,
             join: episode in Episode,
             on: episode.id == publication.episode_id,
             where:
               publication.ref == ^ref and publication.status not in [:published, :discarded] and
                 not is_nil(publication.last_error_code),
             select: {publication, episode}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> publication_item() |> decorate_failure()}
    end
  end

  defp failure_exact("retention", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             left_join: episode in Episode,
             on: episode.id == session.episode_id,
             where: session.external_ref == ^ref and session.cleanup_status == :blocked,
             select: {session, episode}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> retention_item() |> decorate_failure()}
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
      row -> {:ok, work_item(row)}
    end
  end

  def work(_ref), do: :not_found

  def emisar(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case EmisarOperator.fetch(ref) do
      {:ok, %{status: :blocked} = item} -> {:ok, emisar_item(item)}
      _unavailable -> :not_found
    end
  end

  def emisar(_ref), do: :not_found

  def slack_interaction(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.get_by(InteractionAudit, event_ref: ref) do
      %InteractionAudit{repaint_status: :blocked} = audit -> {:ok, interaction_item(audit)}
      _unavailable -> :not_found
    end
  end

  def slack_interaction(_ref), do: :not_found

  def slack_incident(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.get_by(IncidentRoom, ref: ref) do
      %IncidentRoom{status: :blocked} = room -> {:ok, incident_item(room)}
      _unavailable -> :not_found
    end
  end

  def slack_incident(_ref), do: :not_found

  # A reaction delivery belongs to an input rather than an episode; its input
  # id is what finds the conversation and source it was reacting in.
  defp delivery_item(item) do
    %{
      action: :rearm,
      attempt_count: item.attempt_count,
      detail: FailureDetail.project(item.error_detail),
      diagnosis: FailureDetail.facts(item.error_detail),
      episode_id: Map.get(item, :episode_id),
      input_id: Map.get(item, :input_id),
      kind: "delivery",
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
    Repo.one(
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.state == :working and
            episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
        where: episode.key == ^ref and turn.status == :blocked and is_nil(turn.delivery_ref),
        select: {turn, episode}
      )
    )
  end

  defp work_item({%Turn{} = turn, %Episode{} = episode}) do
    recovery = WorkRecovery.brief(turn)

    %{
      action: recovery.action,
      work_recovery: recovery,
      attempt_count: max(turn.work_attempt_count, turn.cancel_attempt_count),
      detail: FailureDetail.project(turn.last_error_detail),
      diagnosis: FailureDetail.facts(turn.last_error_detail),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "work",
      ref: episode.key,
      source: turn.execution_target,
      status: turn.status,
      summary: turn.last_error_code || "work blocked",
      updated_at: turn.updated_at
    }
  end

  defp interaction_item(%InteractionAudit{} = audit) do
    %{
      action: :rearm,
      attempt_count: audit.attempt_count,
      detail: FailureDetail.project(audit.last_error_detail),
      diagnosis: FailureDetail.facts(audit.last_error_detail),
      destination:
        join_target("slack:#{audit.workspace_ref}:#{audit.channel_ref}", audit.thread_ref),
      kind: "slack_interaction",
      ref: audit.event_ref,
      source: "#{audit.actor_ref} · #{audit.action_id}",
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
      episode_id: room.episode_id || room.source_episode_id,
      kind: "slack_incident",
      ref: room.ref,
      source: room.source_message_ref,
      status: room.status,
      summary: room.last_error_code || "Slack incident-room reconciliation blocked",
      updated_at: room.updated_at
    }
  end

  defp emisar_item(item) do
    %{
      action: :rearm,
      attempt_count: item.failure_count,
      detail: FailureDetail.project(item.last_error),
      diagnosis: FailureDetail.facts(item.last_error),
      episode_id: item.episode_id,
      kind: "emisar",
      ref: item.ref,
      source: "#{item.connection_ref} · #{item.runner_ref} · #{item.action_id}",
      status: item.status,
      summary: "Emisar approval monitoring blocked",
      updated_at: item.updated_at
    }
  end

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
      ref: session.external_ref,
      source: session.repository_ref || "no repository",
      status: session.cleanup_status,
      summary: session.cleanup_last_error_code || "retention blocked",
      updated_at: session.updated_at
    }
  end

  # A publication that keeps failing was invisible: not a failure kind here, and
  # not action_needed on its task card until it is `:blocked`. Production ran two
  # for days — 2,902 attempts against a Coop session that closed on the 10th, and
  # 1,087 against a repository whose GitHub App is not installed — while this
  # page, whose question is "what is broken and can I retry it?", said nothing.
  # A recorded failure is the same evidence custody already requires before it
  # offers recovery: a publication that is merely slow is not stuck.
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

  defp decorate_failures(items) do
    items
    |> attach_input_contexts()
    |> attach_episode_contexts()
    |> Activity.with_request_titles()
    |> Enum.map(&failure_defaults/1)
  end

  defp decorate_failure(item), do: item |> List.wrap() |> decorate_failures() |> hd()

  defp attach_input_contexts(items) do
    input_ids =
      items
      |> Enum.map(&Map.get(&1, :input_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts =
      Repo.all(
        from(entry in Entry,
          where: entry.id in ^input_ids,
          select: {entry.id, entry}
        )
      )
      |> Map.new()

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

    contexts =
      Repo.all(
        from(episode in Episode,
          where: episode.id in ^episode_ids,
          select: {episode.id, episode}
        )
      )
      |> Map.new()

    Enum.map(items, fn item ->
      case Map.get(contexts, Map.get(item, :episode_id)) do
        %Episode{} = episode ->
          item
          |> put_if_nil(:episode_ref, episode.key)
          |> put_if_nil(:destination, failure_destination(episode))

        nil ->
          item
      end
    end)
  end

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
