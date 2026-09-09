defmodule Responder.Slack.InteractionRepaint do
  @moduledoc """
  Rebuilds one stale Slack message from current host-owned state.

  The interaction identifies only the message to repaint. Canonical task,
  incident, setup, Work, and record state is reloaded before `chat.update`;
  action values are never interpreted as authority here.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Repo

  alias Responder.Slack.{
    ChannelSetup,
    ConfigurationSession,
    IncidentRoom,
    IncidentRoomCard,
    InteractionAudit,
    ReplyRecords,
    TaskCard,
    TaskCardProjection
  }

  alias Responder.State.{DerivedContext, Records}
  alias Responder.Work.{Session, Turn}

  @confirmation_kinds ~w(preference_offer guidance_offer standing_assignment_offer memory_offer schedule_offer automation_change_offer)

  @spec repaint(InteractionAudit.t(), map()) :: :ok | {:error, term()}
  def repaint(%InteractionAudit{} = audit, %{api: api, client: client}) do
    if repaint_api?(api) do
      case repaint_source(audit) do
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

  defp repaint_source(audit) do
    case task_card(audit) do
      %TaskCard{} = card -> task_card_document(card)
      nil -> repaint_non_task(audit)
    end
  end

  defp repaint_non_task(audit) do
    case incident_room(audit) do
      %IncidentRoom{} = room -> incident_room_document(room)
      nil -> repaint_non_incident(audit)
    end
  end

  defp repaint_non_incident(audit) do
    case configuration_session(audit) do
      %ConfigurationSession{} = session ->
        {:ok, ChannelSetup.document(session), "slack-setup:#{session.id}:#{session.revision}"}

      nil ->
        turn_document(audit)
    end
  end

  defp task_card(audit) do
    query =
      from(card in TaskCard,
        where:
          card.workspace_ref == ^audit.workspace_ref and card.channel_ref == ^audit.channel_ref and
            card.message_ref == ^audit.message_ref,
        limit: 1
      )

    query
    |> maybe_task_thread(audit.thread_ref)
    |> Repo.one()
  end

  defp incident_room(audit) do
    Repo.one(
      from(room in IncidentRoom,
        where:
          room.workspace_ref == ^audit.workspace_ref and room.channel_ref == ^audit.channel_ref and
            room.root_message_ref == ^audit.message_ref,
        limit: 1
      )
    )
  end

  defp configuration_session(audit) do
    Repo.one(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^audit.workspace_ref and
            session.channel_ref == ^audit.channel_ref and
            session.current_message_ref == ^audit.message_ref,
        order_by: [desc: session.revision, desc: session.updated_at],
        limit: 1
      )
    )
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
    conversation_ref = "slack:#{audit.workspace_ref}:#{audit.channel_ref}"

    query =
      from(turn in Turn,
        where:
          not is_nil(turn.external_receipt) and
            fragment("(?::jsonb)->>'transport' = 'slack'", turn.external_receipt) and
            fragment(
              "(?::jsonb)->>'conversation_ref' = ?",
              turn.external_receipt,
              ^conversation_ref
            ) and
            fragment(
              "(?::jsonb)->>'message_ref' = ?",
              turn.external_receipt,
              ^audit.message_ref
            ),
        order_by: [desc: turn.delivered_at, desc: turn.id],
        limit: 1
      )

    turn = query |> maybe_turn_thread(audit.thread_ref) |> Repo.one()

    case turn do
      %Turn{} = turn -> public_turn_document(turn, audit)
      nil -> :not_found
    end
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
      if public_turn_sources?(turn, audit, document) do
        result
      else
        {:ok,
         %{"message" => "This response is unavailable until its source context can be checked."},
         delivery_ref}
      end
    end
  end

  defp public_turn_sources?(turn, audit, document) do
    with %Episode{} = episode <- Repo.get(Episode, turn.episode_id),
         true <- episode.destination_transport == "slack",
         true <-
           episode.destination_conversation_ref ==
             "slack:#{audit.workspace_ref}:#{audit.channel_ref}",
         %Session{episode_id: owner} = session <- Repo.get(Session, turn.session_id),
         true <- owner == episode.id,
         {:ok, _} <-
           DerivedContext.resolve(
             repaint_sources(turn, document),
             episode,
             session.repository_ref
           ) do
      true
    else
      _ -> false
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

  defp rebuild_turn_document(%Turn{delivery_document: %{"message" => message}} = turn)
       when map_size(turn.delivery_document) == 1 and is_binary(message) do
    {:ok, %{"message" => message}, turn.delivery_ref}
  end

  defp rebuild_turn_document(%Turn{} = turn) do
    case turn.delivery_document do
      %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => message,
        "outcome" => %{"record_refs" => refs} = outcome
      } = document
      when map_size(document) == 4 and map_size(outcome) == 3 and is_binary(message) and
             is_list(refs) ->
        with {:ok, records} <- Records.fetch_for_episode(turn.episode_id, refs) do
          {:ok,
           %{
             "message" => confirmation_message(records, message),
             "records" => ReplyRecords.documents("slack", turn.episode_id, records)
           }, turn.delivery_ref}
        end

      _invalid ->
        {:error, :slack_interaction_repaint_document_invalid}
    end
  end

  defp confirmation_message(records, message) do
    if Enum.any?(records, &(&1.kind in @confirmation_kinds and &1.status == :confirmed)),
      do: "Confirmation saved. The confirmed items are shown below.",
      else: message
  end

  defp maybe_task_thread(query, nil), do: query

  defp maybe_task_thread(query, thread_ref),
    do: from(card in query, where: card.thread_ref == ^thread_ref)

  defp maybe_turn_thread(query, nil) do
    from(turn in query,
      where: fragment("(?::jsonb)->>'thread_ref' IS NULL", turn.external_receipt)
    )
  end

  defp maybe_turn_thread(query, thread_ref) do
    from(turn in query,
      where: fragment("(?::jsonb)->>'thread_ref' = ?", turn.external_receipt, ^thread_ref)
    )
  end

  defp repaint_api?(api) do
    is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :update_message, 5)
  end
end
