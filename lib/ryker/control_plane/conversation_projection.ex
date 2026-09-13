defmodule Ryker.ControlPlane.ConversationProjection do
  @moduledoc """
  The direct-conversation pages: the directory, one conversation's merged
  transcript, its retained history pages and change feed, and its artifacts.

  Only exact local operator text, bounded integration-source markers, and
  accepted visible replies cross this read boundary. Prompts, candidates,
  arbitrary external payloads, credentials, and unreleased model output remain
  private.
  """

  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs

  alias Ryker.Artifacts.OutputArtifact

  alias Ryker.ControlPlane.{
    AdmissionProgress,
    ConversationTranscript,
    CurrentInputs,
    InspectionRedactor,
    TranscriptCursor
  }

  alias Ryker.Delivery.PlatformAction
  alias Ryker.Delivery.Reaction
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.State.Record
  alias Ryker.Work.Turn

  @prefix "control-plane:lab:"
  # One transcript page. A page is a window onto retained history, not a cap:
  # older pages are reached through `history/3` with the previous page's
  # boundary cursor. Until 2026-09-13 a 200-row window was the whole view.
  @page_size 50
  @page_maximum 200

  @doc "How many transcript rows one history page holds."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  Lists recent loopback conversations without loading their message bodies.
  """
  def index do
    Repo.all(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            like(entry.destination_conversation_ref, ^"#{@prefix}%") and
            entry.destination_thread_ref == entry.destination_conversation_ref,
        group_by: entry.destination_conversation_ref,
        order_by: [desc: max(entry.inserted_at), desc: entry.destination_conversation_ref],
        limit: 100,
        select: %{
          message_count: count(entry.native_input_id, :distinct),
          ref: entry.destination_conversation_ref,
          updated_at: max(entry.inserted_at)
        }
      )
    )
    |> Enum.flat_map(fn item ->
      case conversation_id(item.ref) do
        {:ok, id} -> [Map.put(item, :id, id)]
        :error -> []
      end
    end)
    |> directory_titles()
  end

  defp directory_titles([]), do: []

  defp directory_titles(items) do
    refs = Enum.map(items, & &1.ref)

    titles =
      Repo.all(
        from(entry in Entry,
          join: current in subquery(CurrentInputs.latest()),
          on:
            current.native_input_id == entry.native_input_id and
              current.execution_mode == entry.execution_mode,
          where:
            entry.destination_conversation_ref in ^refs and entry.source_kind == "control_plane",
          distinct: entry.destination_conversation_ref,
          order_by: [
            asc: entry.destination_conversation_ref,
            asc: entry.inserted_at,
            asc: entry.id
          ],
          select:
            {entry.destination_conversation_ref,
             CurrentInputs.visible_text(
               current.operational_pruned_at,
               current.event_kind,
               current.content
             )}
        )
      )
      |> Map.new()

    secrets = InspectionRedactor.configured_secrets()

    Enum.map(items, fn item ->
      artifact =
        InspectionRedactor.artifact(titles[item.ref],
          secrets: secrets,
          max_bytes: 600
        )

      Map.put(
        item,
        :title,
        if(artifact.text in [nil, ""],
          do: "Conversation · #{Calendar.strftime(item.updated_at, "%d %b")}",
          else: String.slice(artifact.text, 0, 160)
        )
      )
    end)
  end

  @doc """
  Projects one local conversation from its durable ingress and accepted Work rows.

  Only exact local operator text, bounded integration-source markers, and
  accepted visible replies cross this read boundary. Prompts, candidates,
  arbitrary external payloads, credentials, and unreleased model output remain
  private.

  `messages` is the latest page of the merged transcript in display order;
  `history` carries the boundary cursor for `history/3` and whether older
  retained history exists. Processing state is measured on its own, never
  from the rows that happen to be on the page.
  """
  def fetch(conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} -> project_conversation(conversation_id)
      :error -> :not_found
    end
  end

  @doc """
  One page of retained transcript older than `cursor`, newest page first.

  A `nil` cursor reads the latest page. Each returned message carries its own
  `cursor` and `sort_key`; `before` is the boundary for the next older page and
  is `nil` exactly when `exhausted` is true. A cursor that is malformed or was
  issued for another conversation is refused rather than interpreted.
  """
  def history(conversation_id, cursor, limit \\ @page_size)

  def history(conversation_id, cursor, limit)
      when is_integer(limit) and limit in 1..@page_maximum do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, boundary} <- boundary_key(cursor, conversation_id),
         true <- conversation_exists?(@prefix <> conversation_id) do
      {:ok, page(conversation_id, boundary, limit)}
    else
      :error -> :not_found
      false -> :not_found
      {:error, :invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  def history(_conversation_id, _cursor, _limit), do: {:error, :invalid_cursor}

  @doc false
  def artifact(conversation_id, turn_id, artifact_ref)
      when is_binary(turn_id) and is_binary(artifact_ref) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,256}\z/, artifact_ref),
         %OutputArtifact{} = artifact <-
           Repo.one(
             from(artifact in OutputArtifact,
               join: turn in Turn,
               on: turn.id == artifact.turn_id,
               join: episode in Episode,
               on: episode.id == turn.episode_id,
               where:
                 artifact.turn_id == ^turn_id and artifact.ref == ^artifact_ref and
                   episode.destination_transport == "control_plane" and
                   episode.destination_conversation_ref == ^(@prefix <> conversation_id) and
                   episode.destination_thread_ref == ^(@prefix <> conversation_id) and
                   not is_nil(turn.accepted_at) and not is_nil(turn.delivery_document) and
                   is_nil(turn.operational_pruned_at),
               select: artifact
             )
           ) do
      {:ok,
       %{
         byte_size: artifact.byte_size,
         data: artifact.data,
         media_type: artifact.media_type,
         name: artifact.name,
         ref: artifact.ref,
         sha256: artifact.sha256
       }}
    else
      _missing_or_invalid -> :not_found
    end
  end

  def artifact(_conversation_id, _turn_id, _artifact_ref), do: :not_found

  defp project_conversation(conversation_id) do
    ref = @prefix <> conversation_id
    episodes = episodes(ref)

    if episodes == [] and not conversation_exists?(ref) do
      :not_found
    else
      input_queue = input_queue(ref)
      deliveries = delivery_state(ref)
      page = page(conversation_id, nil, @page_size)

      blocked =
        input_queue.blocked > 0 or input_queue.reaction_blocked > 0 or
          Enum.any?(episodes, &(&1.work_status == :blocked)) or
          deliveries.actions_blocked

      {:ok,
       %{
         blocked: blocked,
         admission_progress: AdmissionProgress.conversation(ref),
         conversation_id: conversation_id,
         conversation_ref: ref,
         episodes: episodes,
         history: %{before: page.before, exhausted: page.exhausted, page_size: @page_size},
         live: live?(input_queue, episodes, deliveries),
         messages: page.messages,
         pending: input_queue.pending
       }}
    end
  end

  defp conversation_exists?(ref) do
    Repo.exists?(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref
      )
    ) or
      Repo.exists?(
        from(episode in Episode,
          where:
            episode.destination_transport == "control_plane" and
              episode.destination_conversation_ref == ^ref and
              episode.destination_thread_ref == ^ref
        )
      )
  end

  # The boundary a cursor names, or nil for the latest page. The identity in
  # a cursor must match its rank's shape, so a rank-1 cursor can only ever be
  # compared with turn identifiers.
  defp boundary_key(nil, _conversation_id), do: {:ok, nil}

  defp boundary_key(cursor, conversation_id) do
    with {:ok, {_micros, rank, identity} = key} <-
           TranscriptCursor.decode(cursor, conversation_id),
         {:ok, _value} <- identity_value(rank, identity) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp identity_value(0, "input:" <> native_input_id) when byte_size(native_input_id) > 0,
    do: {:ok, native_input_id}

  defp identity_value(1, "reply:" <> id), do: Ecto.UUID.cast(id)
  defp identity_value(2, "action:" <> id), do: Ecto.UUID.cast(id)
  defp identity_value(3, "publication:" <> id), do: Ecto.UUID.cast(id)
  defp identity_value(_rank, _identity), do: :error

  # Every source contributes its `limit + 1` newest rows older than the
  # boundary; the true next page is the newest `limit` of their union, and one
  # spare candidate says whether anything older remains. The boundary is the
  # oldest candidate on the page even when that candidate renders nothing, so
  # an invisible row can never hide the rows behind it.
  defp page(conversation_id, boundary, limit) do
    ref = @prefix <> conversation_id
    lookahead = limit + 1

    candidates =
      candidates(
        ref,
        %{
          input: inputs_older(page_boundary(boundary, :input)),
          reply: replies_older(page_boundary(boundary, :reply)),
          action: actions_older(page_boundary(boundary, :action)),
          publication: publications_older(page_boundary(boundary, :publication))
        },
        lookahead
      )

    more? = length(candidates) > limit
    window = Enum.take(candidates, limit)

    before =
      case {more?, List.last(window)} do
        {true, {key, _kind, _row}} -> TranscriptCursor.encode(conversation_id, key)
        _exhausted_or_empty -> nil
      end

    %{
      before: before,
      exhausted: not more?,
      messages: ConversationTranscript.messages(window, conversation_id)
    }
  end

  # Every source's rows matching its filter, newest first, each with the key
  # that places it in the merged transcript.
  defp candidates(ref, filters, limit) do
    Enum.concat([
      ref |> page_inputs(filters.input, limit) |> Enum.map(&{:input, &1}),
      ref |> page_replies(filters.reply, limit) |> Enum.map(&{:reply, &1}),
      ref |> page_actions(filters.action, limit) |> Enum.map(&{:action, &1}),
      ref |> page_publications(filters.publication, limit) |> Enum.map(&{:publication, &1})
    ])
    |> Enum.map(fn {kind, row} -> {candidate_key(kind, row), kind, row} end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  @doc """
  The current representation of every transcript row that changed at or
  after `since`: a new or revised input, a reaction on one, an accepted or
  confirmed reply, a card whose record moved, a delivered platform message or
  a publication that advanced. Bounded per source; ascending display order.

  This is how a live window learns about a row it holds that is no longer on
  the latest page, such as an edit to a message the reader scrolled up to.
  """
  def changes(conversation_id, since, limit \\ @page_size)

  def changes(conversation_id, %DateTime{} = since, limit)
      when is_integer(limit) and limit in 1..@page_maximum do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} ->
        ref = @prefix <> conversation_id

        candidates =
          candidates(
            ref,
            %{
              input: changed_inputs(ref, since, limit),
              reply: changed_replies(ref, since, limit),
              action: changed_actions(ref, since, limit),
              publication: changed_publications(ref, since, limit)
            },
            limit * 2
          )

        {:ok, ConversationTranscript.messages(candidates, conversation_id)}

      :error ->
        :not_found
    end
  end

  def changes(_conversation_id, _since, _limit), do: :not_found

  defp changed_inputs(ref, since, limit) do
    revised = revised_input_ids(ref, since, limit)
    reacted = reacted_item_refs(ref, since, limit)

    if revised == [] and reacted == [],
      do: dynamic(false),
      else:
        dynamic(
          [entry, first],
          entry.native_input_id in ^revised or entry.source_item_ref in ^reacted
        )
  end

  defp revised_input_ids(ref, since, limit) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and
            entry.destination_thread_ref == ^ref and
            (entry.inserted_at >= ^since or entry.operational_pruned_at >= ^since),
        distinct: true,
        select: entry.native_input_id,
        limit: ^limit
      )
    )
  end

  defp reacted_item_refs(ref, since, limit) do
    Repo.all(
      from(reaction in Reaction,
        where:
          reaction.transport == "control_plane" and reaction.conversation_ref == ^ref and
            reaction.updated_at >= ^since and not is_nil(reaction.source_item_ref),
        distinct: true,
        select: reaction.source_item_ref,
        limit: ^limit
      )
    ) ++
      Repo.all(
        from(action in PlatformAction,
          where:
            action.transport == "control_plane" and action.conversation_ref == ^ref and
              action.kind == :reaction and action.updated_at >= ^since and
              not is_nil(action.source_item_ref),
          distinct: true,
          select: action.source_item_ref,
          limit: ^limit
        )
      )
  end

  defp changed_replies(ref, since, limit) do
    turn_ids =
      updated_turn_ids(ref, since, limit) ++ moved_record_turn_ids(ref, since, limit)

    delivery_refs = reacted_delivery_refs(ref, since, limit)

    if turn_ids == [] and delivery_refs == [],
      do: dynamic(false),
      else: dynamic([turn], turn.id in ^turn_ids or turn.delivery_ref in ^delivery_refs)
  end

  defp updated_turn_ids(ref, since, limit) do
    Repo.all(
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
    )
  end

  defp moved_record_turn_ids(ref, since, limit) do
    Repo.all(
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
    )
  end

  defp reacted_delivery_refs(ref, since, limit) do
    Repo.all(
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
    )
    |> Enum.filter(&is_binary/1)
  end

  defp changed_actions(ref, since, limit) do
    case Repo.all(
           from(action in PlatformAction,
             where:
               action.transport == "control_plane" and action.conversation_ref == ^ref and
                 action.kind == :message and action.updated_at >= ^since,
             select: action.id,
             limit: ^limit
           )
         ) do
      [] -> dynamic(false)
      ids -> dynamic([action], action.id in ^ids)
    end
  end

  defp changed_publications(ref, since, limit) do
    case Repo.all(
           from(publication in Publication,
             where:
               publication.destination_transport == "control_plane" and
                 publication.destination_conversation_ref == ^ref and
                 publication.destination_thread_ref == ^ref and
                 publication.updated_at >= ^since,
             select: publication.id,
             limit: ^limit
           )
         ) do
      [] -> dynamic(false)
      ids -> dynamic([publication], publication.id in ^ids)
    end
  end

  defp candidate_key(:input, row),
    do: TranscriptCursor.key(row.position, :input, "input:" <> row.native_input_id)

  defp candidate_key(:reply, row),
    do: TranscriptCursor.key(row.occurred_at, :reply, "reply:" <> row.turn_id)

  defp candidate_key(:action, row),
    do: TranscriptCursor.key(row.delivered_at, :action, "action:" <> row.id)

  defp candidate_key(:publication, {publication, _record_ref}),
    do:
      TranscriptCursor.key(
        ConversationTranscript.publication_position(publication),
        :publication,
        "publication:" <> publication.id
      )

  # Keyset conditions per source. `own` is the rank of the source being read;
  # rows sharing the boundary's microsecond fall before it exactly when their
  # rank is lower, or equal with a smaller identity.
  defp page_boundary(nil, _kind), do: :all

  defp page_boundary({micros, rank, identity}, kind) do
    position = DateTime.from_unix!(micros, :microsecond)
    own = TranscriptCursor.rank(kind)

    cond do
      own < rank ->
        {:before_or_at, position}

      own > rank ->
        {:before, position}

      true ->
        {:ok, value} = identity_value(rank, identity)
        {:before_or_tie, position, value}
    end
  end

  # One row per logical input: its current revision, positioned where its
  # first revision entered the conversation. An edit or delete changes what
  # the row says and records `edited_at`; it never moves the row.
  defp page_inputs(ref, filter, limit) do
    latest =
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref,
        distinct: entry.native_input_id,
        order_by: [
          asc: entry.native_input_id,
          desc: entry.revision,
          desc: entry.inserted_at,
          desc: entry.id
        ],
        select: %{
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
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref,
        group_by: entry.native_input_id,
        select: %{native_input_id: entry.native_input_id, position: min(entry.inserted_at)}
      )

    Repo.all(
      from(entry in subquery(latest),
        join: first in subquery(positions),
        on: first.native_input_id == entry.native_input_id,
        where: ^filter,
        order_by: [desc: first.position, desc: fragment("? COLLATE \"C\"", entry.native_input_id)],
        limit: ^limit,
        # The current revision's own row identity, episode link and decision
        # travel with the message: an inspection link built from them opens
        # exactly this revision's admission, never the original's or the
        # newest episode's.
        select: %{
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
    )
  end

  defp inputs_older(:all), do: dynamic(true)
  defp inputs_older({:before_or_at, at}), do: dynamic([entry, first], first.position <= ^at)
  defp inputs_older({:before, at}), do: dynamic([entry, first], first.position < ^at)

  defp inputs_older({:before_or_tie, at, native_input_id}) do
    dynamic(
      [entry, first],
      first.position < ^at or
        (first.position == ^at and
           fragment("? COLLATE \"C\"", entry.native_input_id) < ^native_input_id)
    )
  end

  defp input_queue(ref) do
    entries =
      Repo.one(
        from(entry in Entry,
          where:
            entry.destination_transport == "control_plane" and
              entry.destination_conversation_ref == ^ref and
              entry.destination_thread_ref == ^ref,
          select: %{
            blocked: filter(count(entry.id), entry.status == :blocked),
            pending: filter(count(entry.id), entry.status == :pending)
          }
        )
      )

    reactions =
      Repo.one(
        from(reaction in Reaction,
          where:
            reaction.transport == "control_plane" and reaction.conversation_ref == ^ref and
              reaction.thread_ref == ^ref,
          select: %{
            blocked: filter(count(reaction.id), reaction.status == :blocked),
            pending: filter(count(reaction.id), reaction.status == :pending)
          }
        )
      )

    %{
      blocked: entries.blocked,
      pending: entries.pending,
      reaction_blocked: reactions.blocked,
      reaction_pending: reactions.pending
    }
  end

  # Whether anything in this conversation is still being delivered, measured
  # over the whole conversation rather than the page on screen.
  defp delivery_state(ref) do
    %{
      actions_blocked: action_status?(ref, :blocked),
      actions_pending: action_status?(ref, :pending),
      publications_pending:
        Repo.exists?(
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
        ),
      replies_pending:
        Repo.exists?(
          from(turn in Turn,
            join: episode in Episode,
            on: episode.id == turn.episode_id,
            where:
              episode.destination_transport == "control_plane" and
                episode.destination_conversation_ref == ^ref and
                episode.destination_thread_ref == ^ref and
                turn.status == :delivery_pending and not is_nil(turn.delivery_document)
          )
        )
    }
  end

  defp action_status?(ref, status) do
    Repo.exists?(
      from(action in PlatformAction,
        where:
          action.transport == "control_plane" and action.conversation_ref == ^ref and
            action.status == ^status
      )
    )
  end

  defp episodes(ref) do
    Repo.all(
      from(episode in Episode,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref,
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: 20,
        select: {episode, turn.status, turn.coop_turn_id}
      )
    )
    |> Enum.map(fn {episode, turn_status, coop_turn_id} ->
      %{
        id: episode.id,
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        updated_at: episode.updated_at,
        work_status: turn_status
      }
    end)
  end

  # Accepted replies, positioned at acceptance. A pruned reply keeps its row
  # and reads as expired; only an unaccepted or invisible result is absent.
  defp page_replies(ref, filter, limit) do
    Repo.all(
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
        where: ^filter,
        order_by: [desc: turn.accepted_at, desc: turn.id],
        limit: ^limit,
        select: %{
          document: turn.delivery_document,
          episode_id: turn.episode_id,
          episode_ref: episode.key,
          external_receipt: turn.external_receipt,
          occurred_at: turn.accepted_at,
          pruned_at: turn.operational_pruned_at,
          ref: turn.delivery_ref,
          status: turn.status,
          turn_id: turn.id
        }
      )
    )
  end

  defp replies_older(:all), do: dynamic(true)
  defp replies_older({:before_or_at, at}), do: dynamic([turn], turn.accepted_at <= ^at)
  defp replies_older({:before, at}), do: dynamic([turn], turn.accepted_at < ^at)

  defp replies_older({:before_or_tie, at, turn_id}) do
    dynamic(
      [turn],
      turn.accepted_at < ^at or (turn.accepted_at == ^at and turn.id < ^turn_id)
    )
  end

  # The delivery a publication currently shows, as SQL. It must agree with
  # `ConversationTranscript.publication_position/1`, which computes the same
  # value for the cursor.
  defmacrop publication_position_sql(publication) do
    quote do
      fragment(
        "COALESCE(CASE WHEN ? = 'published' THEN ? END, ?, ?, ?)",
        unquote(publication).status,
        unquote(publication).published_at,
        unquote(publication).reviewed_at,
        unquote(publication).updated_at,
        unquote(publication).inserted_at
      )
    end
  end

  # A publication is one logical row that advances from reviewed to
  # published; its position is the delivery it currently shows.
  defp page_publications(ref, filter, limit) do
    Repo.all(
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
        where: ^filter,
        order_by: [desc: publication_position_sql(publication), desc: publication.id],
        limit: ^limit,
        select: {publication, record.ref}
      )
    )
  end

  defp publications_older(:all), do: dynamic(true)

  defp publications_older({:before_or_at, at}),
    do: dynamic([publication], publication_position_sql(publication) <= ^at)

  defp publications_older({:before, at}),
    do: dynamic([publication], publication_position_sql(publication) < ^at)

  defp publications_older({:before_or_tie, at, publication_id}) do
    dynamic(
      [publication],
      publication_position_sql(publication) < ^at or
        (publication_position_sql(publication) == ^at and publication.id < ^publication_id)
    )
  end

  # Delivered platform messages, positioned at delivery.
  defp page_actions(ref, filter, limit) do
    Repo.all(
      from(action in PlatformAction,
        join: episode in Episode,
        on: episode.id == action.episode_id,
        where:
          action.transport == "control_plane" and action.conversation_ref == ^ref and
            episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            action.kind == :message and action.status == :delivered and
            action.tool == :post_slack_message and not is_nil(action.delivered_at),
        where: ^filter,
        order_by: [desc: action.delivered_at, desc: action.id],
        limit: ^limit,
        select: %{
          action_ref: action.action_ref,
          delivered_at: action.delivered_at,
          document: action.document,
          episode_ref: episode.key,
          id: action.id,
          kind: action.kind,
          status: action.status,
          tool: action.tool
        }
      )
    )
  end

  defp actions_older(:all), do: dynamic(true)
  defp actions_older({:before_or_at, at}), do: dynamic([action], action.delivered_at <= ^at)
  defp actions_older({:before, at}), do: dynamic([action], action.delivered_at < ^at)

  defp actions_older({:before_or_tie, at, action_id}) do
    dynamic(
      [action],
      action.delivered_at < ^at or (action.delivered_at == ^at and action.id < ^action_id)
    )
  end

  defp live?(input_queue, episodes, deliveries) do
    input_queue.pending > 0 or input_queue.reaction_pending > 0 or
      Enum.any?(
        episodes,
        &(&1.next_action in [
            "start_work",
            "continue_work",
            "reconcile_stop",
            "deliver_result",
            "external_event"
          ])
      ) or
      deliveries.replies_pending or deliveries.actions_pending or
      deliveries.publications_pending
  end

  defp conversation_id(@prefix <> id), do: Ecto.UUID.cast(id)
  defp conversation_id(_ref), do: :error

  defp next_action(%Episode{state: :waiting_for_input}, _turn_status, _coop_turn_id),
    do: "operator_input"

  defp next_action(%Episode{state: :waiting_for_event}, _turn_status, _coop_turn_id),
    do: "external_event"

  defp next_action(%Episode{owner_kind: :delivery}, _turn_status, _coop_turn_id),
    do: "deliver_result"

  defp next_action(_episode, :blocked, _coop_turn_id), do: "operator_recovery"
  defp next_action(_episode, :cancel_pending, _coop_turn_id), do: "reconcile_stop"
  defp next_action(%Episode{state: :complete}, _turn_status, _coop_turn_id), do: "complete"
  defp next_action(%Episode{state: :cancelled}, _turn_status, _coop_turn_id), do: "cancelled"
  defp next_action(_episode, _turn_status, nil), do: "start_work"
  defp next_action(_episode, _turn_status, _coop_turn_id), do: "continue_work"
end
