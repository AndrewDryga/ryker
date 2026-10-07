defmodule Ryker.ControlPlane.ConversationQuery do
  @moduledoc """
  What the direct-conversation pages read (`Ryker.ControlPlane.ConversationProjection`):
  the directory, each source of a conversation's transcript, what changed in
  it since a moment, and what is still under way there. `ref` names a
  conversation, which is also its only thread.

  A transcript page reads each source from a boundary, newest first: `:all`,
  `{:before_or_at, at}`, `{:before, at}` or `{:before_or_tie, at, identity}`.
  A change feed names its rows instead: `{:ids, ids}` for actions,
  publications and quick replies, `{:inputs, native_input_ids,
  source_item_refs}`, `{:replies, turn_ids, delivery_refs}`, or `:none`.
  """
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputQuery
  require Ryker.ControlPlane.PublicationPositionQuery
  alias Ryker.Admission.Attempt
  alias Ryker.Artifacts.OutputArtifact
  alias Ryker.ControlPlane.{CurrentInputQuery, PublicationPositionQuery}
  alias Ryker.Delivery.{PlatformAction, RoutingResponse, RoutingResponseQuery}
  alias Ryker.Episodes.{Episode, Event, RoutingDigest}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.InputCustodyTransition
  alias Ryker.Publication.Publication
  alias Ryker.Records.Record
  alias Ryker.Work.Turn

  @doc """
  Every loopback conversation whose ref starts with `prefix`, newest first, as
  `%{message_count, ref, updated_at}`: its messages counted once each, and
  when its latest arrived.
  """
  def directory(prefix) do
    from(entry in Entry,
      where:
        entry.destination_transport == "control_plane" and
          like(entry.destination_conversation_ref, ^"#{prefix}%") and
          entry.destination_thread_ref == entry.destination_conversation_ref,
      group_by: entry.destination_conversation_ref,
      order_by: [desc: max(entry.inserted_at), desc: entry.destination_conversation_ref],
      select: %{
        message_count: count(entry.native_input_id, :distinct),
        ref: entry.destination_conversation_ref,
        updated_at: max(entry.inserted_at)
      }
    )
  end

  @doc "Each of `refs`' first message as it reads now, as `{ref, text}`."
  def opening_texts(refs) do
    first_messages =
      from(entry in Entry,
        where:
          entry.destination_conversation_ref in ^refs and entry.source_kind == "control_plane",
        distinct: entry.destination_conversation_ref,
        order_by: [asc: entry.destination_conversation_ref, asc: entry.inserted_at, asc: entry.id]
      )

    from(entry in subquery(first_messages),
      as: :revision,
      inner_lateral_join: current in subquery(CurrentInputQuery.current()),
      on: true,
      select:
        {entry.destination_conversation_ref,
         CurrentInputQuery.visible_text(
           current.operational_pruned_at,
           current.event_kind,
           current.content
         )}
    )
  end

  @doc "The name Ryker gave each of `refs`' latest named work, as `{ref, title}`."
  def work_titles(refs) do
    from(entry in Entry,
      join: digest in RoutingDigest,
      on: digest.episode_id == entry.episode_id,
      where: entry.destination_conversation_ref in ^refs and not is_nil(digest.title),
      distinct: entry.destination_conversation_ref,
      order_by: [
        asc: entry.destination_conversation_ref,
        desc: digest.title_updated_at,
        desc: digest.episode_id
      ],
      select: {entry.destination_conversation_ref, digest.title}
    )
  end

  @doc """
  What each of `refs` needs from its reader, one row a conversation, as `{ref,
  %{attention, working, waiting_for_you, waiting}}`: something stopped, Ryker
  is still at it, it waits for the person, or it waits for an event.
  """
  def needs(refs) do
    from(entry in Entry,
      left_join: episode in Episode,
      on: episode.id == entry.episode_id,
      where:
        entry.destination_transport == "control_plane" and
          entry.destination_conversation_ref in ^refs,
      group_by: entry.destination_conversation_ref,
      select:
        {entry.destination_conversation_ref,
         %{
           attention:
             fragment(
               "coalesce(bool_or(? = 'blocked' OR (? <> 'complete' AND EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.episode_id = ? AND turn.status = 'blocked'))), false)",
               entry.status,
               episode.state,
               episode.id
             ),
           working:
             fragment(
               "coalesce(bool_or(? = 'pending' OR ? = 'working'), false)",
               entry.status,
               episode.state
             ),
           waiting_for_you:
             fragment("coalesce(bool_or(? = 'waiting_for_input'), false)", episode.state),
           waiting: fragment("coalesce(bool_or(? = 'waiting_for_event'), false)", episode.state)
         }}
    )
  end

  @doc """
  Generated file `artifact_ref` of accepted reply `turn_id` in conversation
  `ref`, while the reply is retained.
  """
  def artifact(ref, turn_id, artifact_ref) do
    from(artifact in OutputArtifact,
      join: turn in Turn,
      on: turn.id == artifact.turn_id,
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        artifact.turn_id == ^turn_id and artifact.ref == ^artifact_ref and
          episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and
          not is_nil(turn.accepted_at) and not is_nil(turn.delivery_document) and
          is_nil(turn.operational_pruned_at),
      select: artifact
    )
  end

  @doc "Every revision of every message of conversation `ref`."
  def messages(ref) do
    from(entry in Entry,
      where:
        entry.destination_transport == "control_plane" and
          entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref
    )
  end

  @doc "The episodes of conversation `ref`."
  def episodes(ref) do
    from(episode in Episode,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref
    )
  end

  @doc """
  The `limit` latest episodes of conversation `ref`, with the status and Coop
  turn of the turn that owns each, as `{episode, turn_status, coop_turn_id}`.
  """
  def latest_episodes(ref, limit) do
    from(episode in episodes(ref),
      left_join: turn in Turn,
      on:
        turn.episode_id == episode.id and episode.owner_kind == :turn and
          episode.owner_ref == turn.turn_ref,
      order_by: [desc: episode.updated_at, desc: episode.id],
      limit: ^limit,
      select: {episode, turn.status, turn.coop_turn_id}
    )
  end

  @doc """
  The messages of conversation `ref` that have not become work, oldest first,
  at most `limit`: each with the admission attempt of its current
  generation, when it was last put back to wait, and its current text.
  """
  def waiting_messages(ref, limit) do
    from(entry in Entry,
      as: :revision,
      inner_lateral_join: current in subquery(CurrentInputQuery.current()),
      on: true,
      left_join: attempt in Attempt,
      on: attempt.input_id == entry.id and attempt.generation == entry.execution_generation,
      left_join: retried in subquery(latest_retries()),
      on: retried.input_id == entry.id,
      where:
        entry.destination_transport == "control_plane" and
          entry.destination_conversation_ref == ^ref and entry.status in [:pending, :blocked],
      order_by: [asc: entry.inserted_at, asc: entry.id],
      limit: ^limit,
      select: %{
        id: entry.id,
        native_input_id: entry.native_input_id,
        status: entry.status,
        received_at: entry.inserted_at,
        retried_at: retried.at,
        retry_at: entry.next_attempt_at,
        leased: not is_nil(entry.lease_ref),
        claims: entry.attempt_count,
        generation: entry.execution_generation,
        phase: attempt.phase,
        observed_at: attempt.updated_at,
        target: attempt.execution_target,
        error_detail: entry.last_error_detail,
        text:
          CurrentInputQuery.visible_text(
            current.operational_pruned_at,
            current.event_kind,
            current.content
          )
      }
    )
  end

  # A retried message is routed again from the retry: counting from when it
  # first arrived read "Routing your message 307m 29s" on the live install
  # (2026-09-26) for a message retried five hours after it stopped.
  defp latest_retries do
    from(transition in InputCustodyTransition,
      where: transition.kind == :rearmed,
      group_by: transition.input_id,
      select: %{input_id: transition.input_id, at: max(transition.occurred_at)}
    )
  end

  @doc "How many of conversation `ref`'s messages wait, as `%{blocked, pending}`."
  def message_counts(ref) do
    from(entry in messages(ref),
      select: %{
        blocked: filter(count(entry.id), entry.status == :blocked),
        pending: filter(count(entry.id), entry.status == :pending)
      }
    )
  end

  @doc """
  How many of conversation `ref`'s quick replies wait to be sent, as
  `%{blocked, pending}`. One waiting behind a stopped earlier one of its
  message is not counted: the stopped one says so.
  """
  def response_counts(ref) do
    from(response in RoutingResponseQuery.in_order(),
      where:
        response.transport == "control_plane" and response.conversation_ref == ^ref and
          response.thread_ref == ^ref,
      select: %{
        blocked: filter(count(response.id), response.status == :blocked),
        pending: filter(count(response.id), response.status == :pending)
      }
    )
  end

  @doc "Publications of conversation `ref` still being reviewed or published."
  def publications_under_way(ref) do
    from(publication in Publication,
      where:
        publication.destination_transport == "control_plane" and
          publication.destination_conversation_ref == ^ref and
          publication.destination_thread_ref == ^ref and
          publication.status in [
            :review_pending,
            :review_ready,
            :publish_pending,
            :published_ready
          ]
    )
  end

  @doc "Replies of conversation `ref` accepted and waiting to be delivered."
  def replies_waiting(ref) do
    from(turn in Turn,
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and
          turn.status == :delivery_pending and not is_nil(turn.delivery_document)
    )
  end

  @doc "Platform actions of conversation `ref` in `status`."
  def actions_in_status(ref, status) do
    from(action in PlatformAction,
      where:
        action.transport == "control_plane" and action.conversation_ref == ^ref and
          action.status == ^status
    )
  end

  @doc """
  The messages of conversation `ref` as each reads now, `limit` at most, the
  latest placed first: one row per message, its current revision positioned
  where its first revision entered the conversation. An edit or delete
  changes what the row says and records `edited_at`; it never moves the row.
  """
  def inputs(ref, filter, limit) do
    latest =
      from(entry in messages(ref),
        distinct: entry.native_input_id,
        order_by: [
          asc: entry.native_input_id,
          desc: entry.revision,
          desc: entry.inserted_at,
          desc: entry.id
        ],
        select: %{
          actor_ref: entry.actor_ref,
          content: entry.content,
          decision_action: entry.decision_action,
          episode_id: entry.episode_id,
          event_kind: entry.event_kind,
          id: entry.id,
          inserted_at: entry.inserted_at,
          native_input_id: entry.native_input_id,
          pruned_at: entry.operational_pruned_at,
          ref: entry.event_ref,
          revision: entry.revision,
          source_kind: entry.source_kind,
          source_ref: entry.source_ref,
          source_item_ref: entry.source_item_ref,
          status: entry.status
        }
      )

    positions =
      from(entry in messages(ref),
        group_by: entry.native_input_id,
        select: %{native_input_id: entry.native_input_id, position: min(entry.inserted_at)}
      )

    from(entry in subquery(latest),
      join: first in subquery(positions),
      on: first.native_input_id == entry.native_input_id,
      where: ^inputs_filter(filter),
      order_by: [desc: first.position, desc: fragment("? COLLATE \"C\"", entry.native_input_id)],
      limit: ^limit,
      # The current revision's own row identity, episode link and decision
      # travel with the message: an inspection link built from them opens
      # exactly this revision's admission, never the original's or the
      # newest episode's.
      select: %{
        actor_ref: entry.actor_ref,
        content: entry.content,
        decision_action: entry.decision_action,
        edited_at: entry.inserted_at,
        episode_id: entry.episode_id,
        event_kind: entry.event_kind,
        id: entry.id,
        native_input_id: entry.native_input_id,
        position: first.position,
        pruned_at: entry.pruned_at,
        ref: entry.ref,
        revision: entry.revision,
        source_kind: entry.source_kind,
        source_ref: entry.source_ref,
        source_item_ref: entry.source_item_ref,
        status: entry.status
      }
    )
  end

  defp inputs_filter(:all), do: dynamic(true)
  defp inputs_filter(:none), do: dynamic(false)
  defp inputs_filter({:before_or_at, at}), do: dynamic([entry, first], first.position <= ^at)
  defp inputs_filter({:before, at}), do: dynamic([entry, first], first.position < ^at)

  defp inputs_filter({:before_or_tie, at, native_input_id}) do
    dynamic(
      [entry, first],
      first.position < ^at or
        (first.position == ^at and
           fragment("? COLLATE \"C\"", entry.native_input_id) < ^native_input_id)
    )
  end

  defp inputs_filter({:inputs, native_input_ids, source_item_refs}) do
    dynamic(
      [entry, first],
      entry.native_input_id in ^native_input_ids or entry.source_item_ref in ^source_item_refs
    )
  end

  @doc """
  Accepted replies of conversation `ref`, positioned at acceptance, the latest
  first, `limit` at most. A pruned reply keeps its row and reads as expired;
  only an unaccepted or invisible result is absent.
  """
  def replies(ref, filter, limit) do
    from(turn in Turn,
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and
          not is_nil(turn.delivery_document) and not is_nil(turn.accepted_at) and
          fragment(
            "(jsonb_typeof(?::jsonb -> 'message') = 'string' OR ?::jsonb ->> 'retention' = 'pruned')",
            turn.delivery_document,
            turn.delivery_document
          ),
      where: ^replies_filter(filter),
      order_by: [desc: turn.accepted_at, desc: turn.id],
      limit: ^limit,
      select: %{
        document: turn.delivery_document,
        episode_id: turn.episode_id,
        external_receipt: turn.external_receipt,
        occurred_at: turn.accepted_at,
        pruned_at: turn.operational_pruned_at,
        ref: turn.delivery_ref,
        status: turn.status,
        turn_id: turn.id
      }
    )
  end

  defp replies_filter(:all), do: dynamic(true)
  defp replies_filter(:none), do: dynamic(false)
  defp replies_filter({:before_or_at, at}), do: dynamic([turn], turn.accepted_at <= ^at)
  defp replies_filter({:before, at}), do: dynamic([turn], turn.accepted_at < ^at)

  defp replies_filter({:before_or_tie, at, turn_id}) do
    dynamic(
      [turn],
      turn.accepted_at < ^at or (turn.accepted_at == ^at and turn.id < ^turn_id)
    )
  end

  defp replies_filter({:replies, turn_ids, delivery_refs}),
    do: dynamic([turn], turn.id in ^turn_ids or turn.delivery_ref in ^delivery_refs)

  @doc """
  Publications of conversation `ref` that show a delivery, each with its
  offer's ref, as `{publication, record_ref}`, the latest placed first,
  `limit` at most. A publication is one row that advances from reviewed to
  published; its position is the delivery it currently shows.
  """
  def publications(ref, filter, limit) do
    from(publication in Publication,
      join: record in Record,
      on: record.id == publication.record_id and record.episode_id == publication.episode_id,
      where:
        publication.destination_transport == "control_plane" and
          publication.destination_conversation_ref == ^ref and
          publication.destination_thread_ref == ^ref and
          ((publication.status in [:reviewed, :blocked] and
              not is_nil(publication.review_delivery_receipt)) or
             (publication.status == :published and
                not is_nil(publication.published_delivery_receipt))),
      where: ^publications_filter(filter),
      order_by: [desc: PublicationPositionQuery.sql(publication), desc: publication.id],
      limit: ^limit,
      select: {publication, record.ref}
    )
  end

  defp publications_filter(:all), do: dynamic(true)
  defp publications_filter(:none), do: dynamic(false)
  defp publications_filter({:ids, ids}), do: dynamic([publication], publication.id in ^ids)

  defp publications_filter({:before_or_at, at}),
    do: dynamic([publication], PublicationPositionQuery.sql(publication) <= ^at)

  defp publications_filter({:before, at}),
    do: dynamic([publication], PublicationPositionQuery.sql(publication) < ^at)

  defp publications_filter({:before_or_tie, at, publication_id}) do
    dynamic(
      [publication],
      PublicationPositionQuery.sql(publication) < ^at or
        (PublicationPositionQuery.sql(publication) == ^at and publication.id < ^publication_id)
    )
  end

  @doc """
  Platform messages delivered in conversation `ref`, positioned at delivery,
  the latest first, `limit` at most.
  """
  def actions(ref, filter, limit) do
    from(action in PlatformAction,
      join: episode in Episode,
      on: episode.id == action.episode_id,
      where:
        action.transport == "control_plane" and action.conversation_ref == ^ref and
          episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          action.kind == :message and action.status == :delivered and
          action.tool in [:post_slack_message, :post_slack_update] and
          not is_nil(action.delivered_at),
      where: ^actions_filter(filter),
      order_by: [desc: action.delivered_at, desc: action.id],
      limit: ^limit,
      select: %{
        action_ref: action.action_ref,
        delivered_at: action.delivered_at,
        document: action.document,
        episode_id: episode.id,
        external_receipt: action.external_receipt,
        id: action.id,
        kind: action.kind,
        status: action.status,
        tool: action.tool
      }
    )
  end

  defp actions_filter(:all), do: dynamic(true)
  defp actions_filter(:none), do: dynamic(false)
  defp actions_filter({:ids, ids}), do: dynamic([action], action.id in ^ids)
  defp actions_filter({:before_or_at, at}), do: dynamic([action], action.delivered_at <= ^at)
  defp actions_filter({:before, at}), do: dynamic([action], action.delivered_at < ^at)

  defp actions_filter({:before_or_tie, at, action_id}) do
    dynamic(
      [action],
      action.delivered_at < ^at or (action.delivered_at == ^at and action.id < ^action_id)
    )
  end

  @doc """
  Quick replies routing sent in conversation `ref` without Work, positioned
  at delivery like a platform message, the latest first, `limit` at most.
  """
  def quick_replies(ref, filter, limit) do
    from(response in RoutingResponse,
      where:
        response.kind == :message and response.transport == "control_plane" and
          response.conversation_ref == ^ref and response.thread_ref == ^ref and
          response.status == :delivered and not is_nil(response.delivered_at),
      where: ^quick_replies_filter(filter),
      order_by: [desc: response.delivered_at, desc: response.id],
      limit: ^limit,
      select: %{
        delivered_at: response.delivered_at,
        delivery_ref: response.delivery_ref,
        document: response.document,
        external_receipt: response.external_receipt,
        id: response.id,
        input_id: response.input_id,
        status: response.status
      }
    )
  end

  defp quick_replies_filter(:all), do: dynamic(true)
  defp quick_replies_filter(:none), do: dynamic(false)
  defp quick_replies_filter({:ids, ids}), do: dynamic([response], response.id in ^ids)

  defp quick_replies_filter({:before_or_at, at}),
    do: dynamic([response], response.delivered_at <= ^at)

  defp quick_replies_filter({:before, at}), do: dynamic([response], response.delivered_at < ^at)

  defp quick_replies_filter({:before_or_tie, at, response_id}) do
    dynamic(
      [response],
      response.delivered_at < ^at or (response.delivered_at == ^at and response.id < ^response_id)
    )
  end

  @doc "Messages of conversation `ref` that arrived or were pruned since `since`, `limit` at most."
  def revised_message_ids(ref, since, limit) do
    from(entry in messages(ref),
      where: entry.inserted_at >= ^since or entry.operational_pruned_at >= ^since,
      distinct: true,
      select: entry.native_input_id,
      limit: ^limit
    )
  end

  @doc "Messages of conversation `ref` whose reaction from routing changed since `since`."
  def routing_reacted_items(ref, since, limit) do
    from(reaction in RoutingResponse,
      where:
        reaction.kind == :reaction and reaction.transport == "control_plane" and
          reaction.conversation_ref == ^ref and reaction.updated_at >= ^since and
          not is_nil(reaction.source_item_ref),
      distinct: true,
      select: reaction.source_item_ref,
      limit: ^limit
    )
  end

  @doc "Messages of conversation `ref` whose reaction from Work changed since `since`."
  def work_reacted_items(ref, since, limit) do
    from(action in PlatformAction,
      where:
        action.transport == "control_plane" and action.conversation_ref == ^ref and
          action.kind == :reaction and action.updated_at >= ^since and
          not is_nil(action.source_item_ref),
      distinct: true,
      select: action.source_item_ref,
      limit: ^limit
    )
  end

  @doc "Turns of conversation `ref` updated since `since`, `limit` at most."
  def updated_turn_ids(ref, since, limit) do
    from(turn in Turn,
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and turn.updated_at >= ^since,
      select: turn.id,
      limit: ^limit
    )
  end

  @doc "Turns of the episodes local messages `native_input_ids` started, `limit` at most."
  def answering_turn_ids(native_input_ids, limit) do
    from(turn in Turn,
      join: entry in Entry,
      on: entry.episode_id == turn.episode_id,
      where:
        entry.source_kind == "control_plane" and entry.source_ref == "local" and
          entry.native_input_id in ^native_input_ids,
      distinct: true,
      select: turn.id,
      limit: ^limit
    )
  end

  @doc "Turns whose records in conversation `ref` moved since `since`, `limit` at most."
  def moved_record_turn_ids(ref, since, limit) do
    from(record in Record,
      join: episode in Episode,
      on: episode.id == record.episode_id,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and record.updated_at >= ^since and
          not is_nil(record.turn_id),
      distinct: true,
      select: record.turn_id,
      limit: ^limit
    )
  end

  @doc """
  The deliveries in conversation `ref` a person reacted to since `since`,
  `limit` at most; a reaction that names none reads nil.
  """
  def reacted_delivery_refs(ref, since, limit) do
    from(event in Event,
      join: episode in Episode,
      on: episode.id == event.episode_id,
      where:
        episode.destination_transport == "control_plane" and
          episode.destination_conversation_ref == ^ref and
          episode.destination_thread_ref == ^ref and event.kind == :reaction_recorded and
          event.inserted_at >= ^since,
      select: fragment("?::jsonb ->> 'target_delivery_ref'", event.payload),
      limit: ^limit
    )
  end

  @doc """
  Platform messages of conversation `ref` updated since `since` or among the
  messages `reacted` names, `limit` at most.
  """
  def changed_action_ids(ref, since, reacted, limit) do
    from(action in PlatformAction,
      where:
        action.transport == "control_plane" and action.conversation_ref == ^ref and
          action.kind == :message,
      where:
        action.updated_at >= ^since or
          fragment("(?::jsonb ->> 'message_ref')", action.external_receipt) in ^reacted,
      select: action.id,
      limit: ^limit
    )
  end

  @doc "Publications of conversation `ref` updated since `since`, `limit` at most."
  def changed_publication_ids(ref, since, limit) do
    from(publication in Publication,
      where:
        publication.destination_transport == "control_plane" and
          publication.destination_conversation_ref == ^ref and
          publication.destination_thread_ref == ^ref and
          publication.updated_at >= ^since,
      select: publication.id,
      limit: ^limit
    )
  end

  @doc """
  Quick replies of conversation `ref` updated since `since` or among the
  messages `reacted` names, `limit` at most.
  """
  def changed_quick_reply_ids(ref, since, reacted, limit) do
    from(response in RoutingResponse,
      where:
        response.kind == :message and response.transport == "control_plane" and
          response.conversation_ref == ^ref,
      where:
        response.updated_at >= ^since or
          fragment("(?::jsonb ->> 'message_ref')", response.external_receipt) in ^reacted,
      select: response.id,
      limit: ^limit
    )
  end
end
