defmodule Ryker.Slack.InteractionRepaint do
  @moduledoc """
  Rebuilds one stale Slack message from current host-owned state.

  The interaction identifies only the message to repaint. Canonical task,
  incident, setup, Work, and record state is reloaded before `chat.update`;
  action values are never interpreted as authority here.
  """
  alias Ryker.Adapter
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelSetup, ConfigurationSession}
  alias Ryker.Slack.{IncidentRoom, IncidentRoomCard}
  alias Ryker.Slack.{InteractionAudit, Mentions, ReplyRecords}
  alias Ryker.Slack.{TaskCard, TaskCardProjection}
  alias Ryker.Work

  @confirmation_kinds ~w(preference_offer guidance_offer standing_assignment_offer memory_offer schedule_offer automation_change_offer)

  @spec repaint(InteractionAudit.t(), map()) :: :ok | {:error, term()}
  def repaint(%InteractionAudit{} = audit, %{api: api, client: client} = options) do
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

  def repaint(_audit, _options), do: {:error, :slack_interaction_repaint_invalid}

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
         do: {:ok, projection.document, card.ref}
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
         true <- owner == episode.id,
         {:ok, _} <-
           Records.DerivedContext.resolve(
             repaint_sources(turn, document),
             episode,
             session.repository_ref
           ) do
      :public
    else
      # Only a source that is gone, or a receipt that is not this reply's,
      # withdraws it; any other error is Ryker's and is checked again.
      {:error, :work_knowledge_context_stale} -> :withdrawn
      {:error, reason} -> {:error, reason}
      _refused -> :withdrawn
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
          &(Map.delete(&1, "presentation") |> Records.DerivedContext.record())
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
    with {:ok, records} <- ReplyRecords.fetch(turn.episode_id, refs) do
      {:ok,
       %{
         "message" => confirmation_message(records, message),
         "records" => ReplyRecords.documents("slack", turn.episode_id, records)
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
    if Enum.any?(records, &(&1.kind in @confirmation_kinds and &1.status == :confirmed)),
      do: "Saved.",
      else: message
  end

  defp repaint_api?(api) do
    Adapter.implements?(api, update_message: 5)
  end
end
