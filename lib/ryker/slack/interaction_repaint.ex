defmodule Ryker.Slack.InteractionRepaint do
  @moduledoc """
  Rebuilds one stale Slack message from current host-owned state.

  The interaction identifies only the message to repaint. Canonical task,
  incident, setup, Work, and record state is reloaded before `chat.update`;
  action values are never interpreted as authority here.
  """
  alias Ryker.Adapter
  alias Ryker.AdvisoryLock
  alias Ryker.ConversationRef
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelSetup, ConfigurationSession}
  alias Ryker.Slack.{IncidentRoom, IncidentRoomCard}
  alias Ryker.Slack.{InteractionAudit, Mentions, Monitoring, ReplyRecords}
  alias Ryker.Slack.{TaskCard, TaskCardProjection}
  alias Ryker.Work

  @confirmation_kinds ~w(preference_offer guidance_offer standing_assignment_offer memory_offer schedule_offer automation_change_offer)

  @spec repaint(InteractionAudit.t(), map()) :: :ok | {:error, term()}
  def repaint(%InteractionAudit{} = audit, %{api: api, client: client} = options) do
    # Two independent audit leases may target one message. Serialize the build
    # and HTTP update, not episode mutations, so an older footer cannot land last.
    key =
      Crypto.lock_key([
        "slack-repaint:",
        audit.workspace_ref,
        ":",
        audit.channel_ref,
        ":",
        audit.message_ref
      ])

    Repo.checkout(fn ->
      if AdvisoryLock.try_session?(key) do
        try do
          repaint_locked(audit, api, client, options)
        after
          AdvisoryLock.release_session(key)
        end
      else
        {:error, :slack_message_repaint_busy}
      end
    end)
  end

  def repaint(_audit, _options), do: {:error, :slack_interaction_repaint_invalid}

  defp repaint_locked(audit, api, client, options) do
    if repaint_api?(api) do
      case repaint_source(audit, options) do
        {:ok, document, delivery_ref} ->
          api.update_message(
            client,
            audit.channel_ref,
            audit.message_ref,
            document,
            delivery_ref
          )

        :not_found ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :slack_interaction_repaint_api_invalid}
    end
  end

  defp repaint_source(audit, options) do
    case fetch_task_card(audit) do
      {:ok, %TaskCard{} = card} -> task_card_document(card)
      {:error, :not_found} -> repaint_non_task(audit, options)
    end
  end

  defp repaint_non_task(audit, options) do
    case fetch_incident_room(audit) do
      {:ok, %IncidentRoom{} = room} -> incident_room_document(room)
      {:error, :not_found} -> repaint_non_incident(audit, options)
    end
  end

  defp repaint_non_incident(audit, options) do
    case fetch_configuration_session(audit) do
      {:ok, %ConfigurationSession{} = session} -> setup_document(session, options)
      {:error, :not_found} -> turn_document(audit, options)
    end
  end

  defp setup_document(session, %{bot_user_ref: bot_user_ref}),
    do: {:ok, ChannelSetup.document(session, bot_user_ref), "slack-setup:#{session.id}"}

  defp setup_document(_session, _options), do: {:error, :slack_setup_presentation_unavailable}

  defp fetch_task_card(audit) do
    audit.workspace_ref
    |> TaskCard.Query.by_message(audit.channel_ref, audit.message_ref, audit.thread_ref)
    |> TaskCard.Query.limit_to(1)
    |> Repo.fetch()
  end

  defp fetch_incident_room(audit) do
    audit.workspace_ref
    |> IncidentRoom.Query.by_root_message(audit.channel_ref, audit.message_ref)
    |> IncidentRoom.Query.limit_to(1)
    |> Repo.fetch()
  end

  defp fetch_configuration_session(audit) do
    audit.workspace_ref
    |> ConfigurationSession.Query.by_current_message(audit.channel_ref, audit.message_ref)
    |> ConfigurationSession.Query.limit_to(1)
    |> Repo.fetch()
  end

  defp task_card_document(card) do
    with {:ok, projection} <- TaskCardProjection.build(card),
         do: {:ok, projection.document, TaskCard.delivery_ref(card)}
  end

  defp incident_room_document(room) do
    with {:ok, projection} <- IncidentRoomCard.build(room),
         do: {:ok, projection.document, "#{room.ref}:root"}
  end

  defp turn_document(audit, options) do
    case Repo.fetch(delivered_turn(audit)) do
      {:ok, %Work.Turn{} = turn} -> public_turn_document(turn, audit, options)
      {:error, :not_found} -> :not_found
    end
  end

  defp delivered_turn(audit) do
    Work.Turn.Query.delivered_slack_message(
      audit.workspace_ref,
      audit.channel_ref,
      audit.message_ref,
      audit.thread_ref
    )
  end

  defp public_turn_document(turn, audit, options) do
    # These are external republications, not retained audit views. Check the
    # exact projection before HTTP; a later withdrawal is seen on the next repaint.
    case Repo.transaction(fn -> checked_turn_document(turn, audit, options) end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp checked_turn_document(turn, audit, options) do
    with {:ok, document, delivery_ref} = result <- rebuild_turn_document(turn) do
      case public_turn_sources(turn, audit, document) do
        :public ->
          result

        :outdated ->
          outdated_document(turn, document, delivery_ref)

        # Ryker could not check the sources this time: the session is in use,
        # usually by the turn the typed answer being repainted for has just
        # started, or its sources could not be gathered. The worker checks
        # again, then gives up and leaves the reply as it is; until
        # 2026-09-27 this replaced the reply as though it were withdrawn.
        {:error, reason} ->
          {:error, reason}

        :withdrawn ->
          withdrawn(delivery_ref, Map.get(options, :withdraw, true))
      end
    end
  end

  defp outdated_document(turn, document, delivery_ref) do
    document = Map.put(document, "message", turn.delivery_document["message"])

    with {:ok, document} <- with_mentions(document, turn),
         do: {:ok, Map.put(document, "source_notice", "changed"), delivery_ref}
  end

  defp withdrawn(delivery_ref, true) do
    {:ok, %{"message" => "This response is unavailable until its source context can be checked."},
     delivery_ref}
  end

  # A repaint nobody clicked for, such as an offer redrawn once its incident
  # room is made, leaves a reply it cannot republish as it is.
  defp withdrawn(_delivery_ref, false), do: :not_found

  defp public_turn_sources(turn, audit, document) do
    with {:ok, episode} <- fetch_source_row(Episodes.Episode.Query.by_id(turn.episode_id)),
         true <- episode.destination_transport == "slack",
         true <-
           episode.destination_conversation_ref ==
             ConversationRef.slack(audit.workspace_ref, audit.channel_ref),
         {:ok, %Work.Session{episode_id: owner} = session} <-
           fetch_source_row(Work.Session.Query.by_id(turn.session_id)),
         true <- owner == episode.id do
      source_status(turn, document, episode, session)
    else
      # Only a source that is gone, or a receipt that is not this reply's,
      # withdraws it; any other error is Ryker's and is checked again.
      {:error, :work_knowledge_context_stale} -> :withdrawn
      {:error, reason} -> {:error, reason}
      _refused -> :withdrawn
    end
  end

  defp source_status(turn, document, episode, session) do
    sources = repaint_sources(turn, document)

    case Records.DerivedContext.resolve(
           sources,
           episode,
           session.repository_ref,
           session
         ) do
      {:ok, _} ->
        :public

      {:error, :work_knowledge_context_stale} ->
        if is_nil(turn.operational_pruned_at) and is_binary(turn.result_ref) and
             Records.DerivedContext.visible_for_repaint?(
               sources,
               episode,
               session.repository_ref,
               session
             ),
           do: :outdated,
           else: :withdrawn

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The request or session a reply came from being gone withdraws the reply.
  defp fetch_source_row(query) do
    with {:error, :not_found} <- Repo.fetch(query), do: :gone
  end

  defp repaint_sources(turn, document) do
    [
      Records.DerivedContext.delivery(Records.DerivedContext.delivery_document(turn))
      | Enum.map(
          document["records"] || [],
          # Host receipt links and presentation are not model-authored record content.
          &(Map.drop(&1, ~w(presentation message_url)) |> Records.DerivedContext.record())
        )
    ]
  end

  defp rebuild_turn_document(%Work.Turn{} = turn) do
    with {:ok, document} <- reply_document(turn),
         {:ok, document} <- with_mentions(document, turn),
         do: {:ok, document, turn.delivery_ref}
  end

  defp reply_document(%Work.Turn{delivery_document: %{"message" => message}} = turn)
       when map_size(turn.delivery_document) == 1 and is_binary(message),
       do: {:ok, %{"message" => message}}

  defp reply_document(
         %Work.Turn{
           delivery_document:
             %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => message,
               "outcome" => %{"record_refs" => refs} = outcome
             } = document
         } = turn
       )
       when map_size(document) == 4 and map_size(outcome) == 3 and is_binary(message) and
              is_list(refs) do
    with {:ok, records} <- ReplyRecords.fetch(turn.episode_id, refs, turn.id) do
      {:ok,
       %{
         "message" => confirmation_message(records, message),
         "records" =>
           ReplyRecords.documents("slack", turn.episode_id, records) |> Monitoring.decorate(turn)
       }}
    end
  end

  defp reply_document(_turn), do: {:error, :slack_interaction_repaint_document_invalid}

  # The publisher sends a reply that names someone with its delivery's
  # mention authority, and the repaint names them the same way.
  defp with_mentions(%{"message" => message} = document, turn) do
    if Mentions.typed?(message) do
      with {:ok, authority} <- Mentions.authority_for_delivery(turn.delivery_ref),
           do: {:ok, Map.put(document, "slack_mentions", authority)}
    else
      {:ok, document}
    end
  end

  defp confirmation_message(records, message) do
    cond do
      Enum.any?(records, &(&1.kind == "slack_post_offer" and &1.status == :confirmed)) ->
        "Confirmed."

      Enum.any?(records, &(&1.kind in @confirmation_kinds and &1.status == :confirmed)) ->
        "Saved."

      true ->
        message
    end
  end

  defp repaint_api?(api) do
    Adapter.implements?(api, update_message: 5)
  end
end
