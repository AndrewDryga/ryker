defmodule Ryker.Slack.InteractionRepaint do
  @moduledoc """
  Rebuilds one stale Slack message from current host-owned state.

  The interaction identifies only the message to repaint. Canonical task,
  incident, setup, Work, and record state is reloaded before `chat.update`;
  action values are never interpreted as authority here.
  """

  alias Ryker.Episodes.{Episode, EpisodeQuery}
  alias Ryker.Records.DerivedContext
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelSetup, ConfigurationSession, ConfigurationSessionQuery}
  alias Ryker.Slack.{IncidentRoom, IncidentRoomCard, IncidentRoomQuery}
  alias Ryker.Slack.{InteractionAudit, Mentions, ReplyRecords}
  alias Ryker.Slack.{TaskCard, TaskCardProjection, TaskCardQuery}
  alias Ryker.Work.{Session, SessionQuery, Turn, TurnQuery}

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

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :slack_interaction_repaint_api_invalid}
    end
  end

  def repaint(_audit, _options), do: {:error, :slack_interaction_repaint_invalid}

  defp repaint_source(audit, options) do
    case task_card(audit) do
      %TaskCard{} = card -> task_card_document(card)
      nil -> repaint_non_task(audit, options)
    end
  end

  defp repaint_non_task(audit, options) do
    case incident_room(audit) do
      %IncidentRoom{} = room -> incident_room_document(room)
      nil -> repaint_non_incident(audit, options)
    end
  end

  defp repaint_non_incident(audit, options) do
    case configuration_session(audit) do
      %ConfigurationSession{} = session -> setup_document(session, options)
      nil -> turn_document(audit)
    end
  end

  defp setup_document(session, %{bot_user_ref: bot_user_ref}),
    do: {:ok, ChannelSetup.document(session, bot_user_ref), "slack-setup:#{session.id}"}

  defp setup_document(_session, _options), do: {:error, :slack_setup_presentation_unavailable}

  defp task_card(audit) do
    audit.workspace_ref
    |> TaskCardQuery.by_message(audit.channel_ref, audit.message_ref, audit.thread_ref)
    |> TaskCardQuery.limit_to(1)
    |> Repo.one()
  end

  defp incident_room(audit) do
    audit.workspace_ref
    |> IncidentRoomQuery.by_root_message(audit.channel_ref, audit.message_ref)
    |> IncidentRoomQuery.limit_to(1)
    |> Repo.one()
  end

  defp configuration_session(audit) do
    audit.workspace_ref
    |> ConfigurationSessionQuery.by_current_message(audit.channel_ref, audit.message_ref)
    |> ConfigurationSessionQuery.limit_to(1)
    |> Repo.one()
  end

  defp task_card_document(card) do
    with {:ok, projection} <- TaskCardProjection.build(card),
         do: {:ok, projection.document, card.ref}
  end

  defp incident_room_document(room) do
    with {:ok, projection} <- IncidentRoomCard.build(room),
         do: {:ok, projection.document, "#{room.ref}:root"}
  end

  defp turn_document(audit) do
    case Repo.one(delivered_turn(audit)) do
      %Turn{} = turn -> public_turn_document(turn, audit)
      nil -> :not_found
    end
  end

  defp delivered_turn(audit) do
    TurnQuery.delivered_slack_message(
      audit.workspace_ref,
      audit.channel_ref,
      audit.message_ref,
      audit.thread_ref
    )
  end

  defp public_turn_document(turn, audit) do
    # These are external republications, not retained audit views. Check the
    # exact projection before HTTP; a later withdrawal is seen on the next repaint.
    case Repo.transaction(fn -> checked_turn_document(turn, audit) end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp checked_turn_document(turn, audit) do
    with {:ok, document, delivery_ref} = result <- rebuild_turn_document(turn) do
      case public_turn_sources(turn, audit, document) do
        :public ->
          result

        # Ryker could not check the sources this time: the session is in use,
        # usually by the turn the typed answer being repainted for has just
        # started, or its sources could not be gathered. The worker checks
        # again, then gives up and leaves the reply as it is; until
        # 2026-09-27 this replaced the reply as though it were withdrawn.
        {:error, _reason} = unchecked ->
          unchecked

        :withdrawn ->
          {:ok,
           %{
             "message" => "This response is unavailable until its source context can be checked."
           }, delivery_ref}
      end
    end
  end

  defp public_turn_sources(turn, audit, document) do
    with %Episode{} = episode <- Repo.one(EpisodeQuery.by_id(turn.episode_id)),
         true <- episode.destination_transport == "slack",
         true <-
           episode.destination_conversation_ref ==
             "slack:#{audit.workspace_ref}:#{audit.channel_ref}",
         %Session{episode_id: owner} = session <- Repo.one(SessionQuery.by_id(turn.session_id)),
         true <- owner == episode.id,
         {:ok, _} <-
           DerivedContext.resolve(
             repaint_sources(turn, document),
             episode,
             session.repository_ref
           ) do
      :public
    else
      # Only a source that is gone, or a receipt that is not this reply's,
      # withdraws it; any other error is Ryker's and is checked again.
      {:error, :work_knowledge_context_stale} -> :withdrawn
      {:error, _reason} = unchecked -> unchecked
      _refused -> :withdrawn
    end
  end

  defp repaint_sources(turn, document) do
    [
      DerivedContext.delivery(DerivedContext.delivery_document(turn))
      | Enum.map(
          document["records"] || [],
          &(Map.delete(&1, "presentation") |> DerivedContext.record())
        )
    ]
  end

  defp rebuild_turn_document(%Turn{} = turn) do
    with {:ok, document} <- reply_document(turn),
         {:ok, document} <- with_mentions(document, turn),
         do: {:ok, document, turn.delivery_ref}
  end

  defp reply_document(%Turn{delivery_document: %{"message" => message}} = turn)
       when map_size(turn.delivery_document) == 1 and is_binary(message),
       do: {:ok, %{"message" => message}}

  defp reply_document(%Turn{} = turn) do
    case turn.delivery_document do
      %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => message,
        "outcome" => %{"record_refs" => refs} = outcome
      } = document
      when map_size(document) == 4 and map_size(outcome) == 3 and is_binary(message) and
             is_list(refs) ->
        with {:ok, records} <- ReplyRecords.fetch(turn.episode_id, refs) do
          {:ok,
           %{
             "message" => confirmation_message(records, message),
             "records" => ReplyRecords.documents("slack", turn.episode_id, records)
           }}
        end

      _invalid ->
        {:error, :slack_interaction_repaint_document_invalid}
    end
  end

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
      do: "Confirmation saved. The confirmed items are shown below.",
      else: message
  end

  defp repaint_api?(api) do
    is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :update_message, 5)
  end
end
