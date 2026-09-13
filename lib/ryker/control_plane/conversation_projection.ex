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
    Card,
    CurrentInputs,
    InspectionRedactor,
    TranscriptCursor
  }

  alias Ryker.Delivery.PlatformAction
  alias Ryker.Delivery.Reaction
  alias Ryker.Episodes.{Episode, Event, Reactions}
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
  @record_limit 64

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
      messages: window_messages(window, conversation_id)
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

        {:ok, window_messages(candidates, conversation_id)}

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
        publication_position(publication),
        :publication,
        "publication:" <> publication.id
      )

  defp window_messages(window, conversation_id) do
    rows = Enum.group_by(window, &elem(&1, 1), &elem(&1, 2))
    inputs = Map.get(rows, :input, [])
    replies = Map.get(rows, :reply, [])
    actions = Map.get(rows, :action, [])
    publications = Map.get(rows, :publication, [])
    item_refs = inputs |> Enum.map(& &1.source_item_ref) |> Enum.filter(&is_binary/1)

    reactions =
      Map.merge(
        delivery_reactions(item_refs),
        input_reaction_actions(item_refs),
        fn _item_ref, delivered, acted -> delivered ++ acted end
      )

    messages =
      messages(
        inputs,
        replies,
        cards(replies),
        output_artifacts(replies, conversation_id),
        actions,
        reactions,
        Reactions.current_for_episodes(Enum.uniq(Enum.map(replies, & &1.episode_id)))
      ) ++ publication_messages(publications)

    messages
    |> attach_execution()
    |> Enum.map(&put_cursor(&1, conversation_id))
    |> sort_messages()
  end

  defp put_cursor(%{sort_key: key} = message, conversation_id),
    do: Map.put(message, :cursor, TranscriptCursor.encode(conversation_id, key))

  # The execution an operator message started, as it stands now: the episode's
  # state, or "blocked" when its owning turn is, so a message whose model work
  # stopped says so beside the message and offers the same retry /failures
  # does. Complete work carries nothing; the reply already sits below it.
  defp attach_execution(messages) do
    episode_ids =
      messages
      |> Enum.filter(&(&1.actor == :operator and is_binary(&1[:episode_id])))
      |> Enum.map(& &1.episode_id)
      |> Enum.uniq()

    executions =
      if episode_ids == [] do
        %{}
      else
        Repo.all(
          from(episode in Episode,
            left_join: turn in Turn,
            on:
              turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
                episode.owner_kind == :turn,
            where: episode.id in ^episode_ids,
            select: %{
              id: episode.id,
              key: episode.key,
              state:
                fragment(
                  "CASE WHEN ? = 'blocked' THEN 'blocked' ELSE ?::text END",
                  turn.status,
                  episode.state
                )
            }
          )
        )
        |> Map.new(fn row -> {row.id, %{key: row.key, state: row.state}} end)
      end

    Enum.map(messages, fn message ->
      case message do
        %{actor: :operator, episode_id: id} when is_binary(id) ->
          Map.put(message, :execution, Map.get(executions, id))

        _other ->
          message
      end
    end)
  end

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

  defp delivery_reactions([]), do: %{}

  defp delivery_reactions(item_refs) do
    Repo.all(
      from(reaction in Reaction,
        where: reaction.transport == "control_plane" and reaction.source_item_ref in ^item_refs,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        limit: ^(@page_maximum * 4),
        select: %{
          delivery_ref: reaction.delivery_ref,
          emoji_name: fragment("(?::jsonb ->> 'emoji_name')", reaction.document),
          source_item_ref: reaction.source_item_ref,
          status: reaction.status
        }
      )
    )
    |> Enum.filter(&(is_binary(&1.emoji_name) and is_binary(&1.source_item_ref)))
    |> Enum.group_by(& &1.source_item_ref, &Map.delete(&1, :source_item_ref))
  end

  defp input_reaction_actions([]), do: %{}

  defp input_reaction_actions(item_refs) do
    Repo.all(
      from(action in PlatformAction,
        where:
          action.transport == "control_plane" and action.kind == :reaction and
            action.source_item_ref in ^item_refs,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: ^(@page_maximum * 4),
        select: %{
          action_ref: action.action_ref,
          document: action.document,
          source_item_ref: action.source_item_ref,
          status: action.status
        }
      )
    )
    |> Enum.filter(&(is_map(&1.document) and is_binary(&1.document["emoji_name"])))
    |> Enum.group_by(& &1.source_item_ref, fn action ->
      %{
        delivery_ref: action.action_ref,
        emoji_name: action.document["emoji_name"],
        status: action.status
      }
    end)
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
  # `publication_position/1`, which computes the same value for the cursor.
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

  defp publication_position(publication) do
    if publication.status == :published,
      do: publication.published_at || publication.updated_at || publication.inserted_at,
      else: publication.reviewed_at || publication.updated_at || publication.inserted_at
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

  defp cards(replies) do
    pairs = card_pairs(replies)

    refs = Enum.map(pairs, &elem(&1, 1))
    allowed = MapSet.new(pairs)

    refs
    |> card_records()
    |> Enum.reduce(%{}, &put_card(&1, &2, allowed))
  end

  defp card_pairs(replies) do
    replies
    |> Enum.reverse()
    |> Enum.flat_map(fn reply ->
      reply.document
      |> reply_outcome()
      |> Map.get("record_refs", [])
      |> bounded_refs()
      |> Enum.map(&{reply.turn_id, &1})
    end)
    |> Enum.uniq()
    |> Enum.take(@record_limit)
  end

  defp card_records([]), do: []

  defp card_records(refs) do
    Repo.all(
      from(record in Record,
        where: record.ref in ^refs,
        limit: @record_limit
      )
    )
  end

  defp put_card(record, cards, allowed) do
    key = {record.turn_id, record.ref}

    if MapSet.member?(allowed, key),
      do: put_projected_card(record, key, cards),
      else: cards
  end

  defp put_projected_card(record, key, cards) do
    case Card.project(record) do
      {:ok, card} -> Map.put(cards, key, card)
      :ignore -> cards
    end
  end

  defp output_artifacts(replies, conversation_id) do
    replies
    |> Enum.map(& &1.turn_id)
    |> Enum.uniq()
    |> project_output_artifacts(conversation_id)
  end

  defp project_output_artifacts([], _conversation_id), do: %{}

  defp project_output_artifacts(turn_ids, conversation_id) do
    Repo.all(
      from(artifact in OutputArtifact,
        where: artifact.turn_id in ^turn_ids,
        order_by: [asc: artifact.name, asc: artifact.ref],
        limit: ^(@page_maximum * 5)
      )
    )
    |> Map.new(&{{&1.turn_id, &1.ref}, output_artifact(&1, conversation_id)})
  end

  defp output_artifact(artifact, conversation_id) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name: artifact.name,
      path:
        "/conversations/#{conversation_id}/turns/#{artifact.turn_id}/artifacts/#{URI.encode(artifact.ref, &URI.char_unreserved?/1)}",
      ref: artifact.ref,
      status: "available"
    }
  end

  defp messages(
         inputs,
         replies,
         cards,
         artifacts,
         actions,
         reactions,
         feedback_reactions
       ) do
    input_messages =
      Enum.flat_map(inputs, fn input ->
        case input do
          %{pruned_at: %DateTime{}, source_kind: "control_plane", source_ref: "local"} ->
            [expired_input_message(input)]

          %{
            content: %{"text" => text},
            source_kind: "control_plane",
            source_ref: "local"
          }
          when is_binary(text) ->
            deleted = input.event_kind == :delete

            [
              input_identity(input, %{
                actor: :operator,
                artifact_refs: if(deleted, do: [], else: input_artifact_refs(input.content)),
                attachments: if(deleted, do: [], else: input_attachments(input.content)),
                cards: [],
                editable: not deleted,
                event_kind: input.event_kind,
                item_id: item_id(input.source_item_ref),
                reactions: Map.get(reactions, input.source_item_ref, []),
                record_refs: [],
                ref: input.ref,
                retained: true,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: if(deleted, do: "Message deleted", else: text)
              })
            ]

          %{source_kind: source_kind, source_ref: source_ref}
          when is_binary(source_kind) and is_binary(source_ref) ->
            [integration_message(input)]

          _invalid_source ->
            []
        end
      end)

    reply_messages =
      Enum.flat_map(replies, &reply_message(&1, cards, artifacts, feedback_reactions))

    action_messages = Enum.flat_map(actions, &action_message/1)

    sort_messages(input_messages ++ reply_messages ++ action_messages)
  end

  # Position, identity and sort key of one logical input: where its first
  # revision entered the conversation, named by the durable input id.
  # The exact provenance rides along: the current revision's own row id, its
  # episode link and decision, so the page can link this message's own
  # admission or recorded decision, and the native input id so admission
  # progress can sit beside the message that caused it.
  defp input_identity(input, message) do
    Map.merge(message, %{
      decision_action: input.decision_action,
      edited_at: if(input.revision > 1, do: input.edited_at),
      episode_id: input.episode_id,
      identity: "input:" <> input.native_input_id,
      input_id: input.id,
      native_input_id: input.native_input_id,
      occurred_at: input.position,
      sort_key: TranscriptCursor.key(input.position, :input, "input:" <> input.native_input_id)
    })
  end

  # Retention replaced the body. The row stays where the message was so the
  # transcript never reads as shorter than it was, and nothing can edit it.
  defp expired_input_message(input) do
    input_identity(input, %{
      actor: :operator,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: item_id(input.source_item_ref),
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: false,
      revision: input.revision,
      state: nil,
      status: input.status,
      text: "This message expired under retention."
    })
  end

  defp integration_message(input) do
    event_type =
      case input.content do
        %{"event_type" => value} when is_binary(value) -> marker_component(value, "event")
        _other -> input.event_kind |> Atom.to_string() |> marker_component("event")
      end

    input_identity(input, %{
      actor: :integration,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: nil,
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: is_nil(input.pruned_at),
      revision: input.revision,
      state: nil,
      status: input.status,
      text:
        "#{source_label(input.source_kind)} #{marker_component(input.source_ref, "integration")} · #{event_type} · revision #{input.revision}"
    })
  end

  defp source_label("webhook"), do: "Webhook"

  defp source_label(source_kind) do
    source_kind
    |> marker_component("Integration")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp marker_component(value, fallback) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 160) do
      "" -> fallback
      component -> component
    end
  end

  defp marker_component(_value, fallback), do: fallback

  defp action_message(
         %{
           action_ref: action_ref,
           delivered_at: %DateTime{} = delivered_at,
           document: %{"message" => message},
           kind: :message,
           status: :delivered,
           tool: :post_slack_message
         } = action
       )
       when is_binary(action_ref) and is_binary(message) do
    [
      %{
        actor: :ryker,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: action.episode_ref,
        identity: "action:" <> action.id,
        occurred_at: delivered_at,
        reactions: [],
        record_refs: [],
        ref: action_ref,
        retained: true,
        sort_key: TranscriptCursor.key(delivered_at, :action, "action:" <> action.id),
        state: nil,
        status: :delivered,
        text: message
      }
    ]
  end

  defp action_message(_action), do: []

  defp publication_messages(publications) do
    Enum.flat_map(publications, &publication_message/1)
  end

  defp publication_message(
         {%Publication{status: status, review_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when status in [:reviewed, :blocked] and is_map(receipt) do
    project_publication_message(
      publication,
      record_ref,
      receipt,
      publication_review_message(status)
    )
  end

  defp publication_message(
         {%Publication{status: :published, published_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when is_map(receipt) do
    project_publication_message(
      publication,
      record_ref,
      receipt,
      "Published the exact reviewed candidate as a draft pull request."
    )
  end

  defp publication_message(_not_delivered), do: []

  defp project_publication_message(publication, record_ref, receipt, message) do
    case Card.project_publication(publication, record_ref) do
      {:ok, card} -> [build_publication_message(publication, receipt, card, message)]
      :ignore -> []
    end
  end

  defp publication_review_message(:reviewed) do
    "The committed change passed trusted review. Publish this exact candidate only after reviewing the host-owned details."
  end

  defp publication_review_message(:blocked) do
    "The committed change is not publishable. Review the trusted findings below."
  end

  defp build_publication_message(publication, receipt, card, message) do
    occurred_at = publication_position(publication)
    identity = "publication:" <> publication.id

    %{
      actor: :ryker,
      artifact_refs: [],
      attachments: [],
      cards: [card],
      identity: identity,
      occurred_at: occurred_at,
      record_refs: [],
      ref: receipt["delivery_ref"],
      retained: true,
      sort_key: TranscriptCursor.key(occurred_at, :publication, identity),
      state: nil,
      status: publication.status,
      text: message
    }
  end

  defp sort_messages(messages), do: Enum.sort_by(messages, & &1.sort_key)

  # Retention replaced the delivered document. The reply keeps its place in
  # the transcript so the answer's absence is visible as retention, not as a
  # question nobody answered.
  defp reply_message(
         %{document: %{"retention" => "pruned"}, pruned_at: %DateTime{}} = reply,
         _cards,
         _artifacts,
         _feedback_reactions
       ) do
    [
      %{
        actor: :ryker,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: reply.episode_ref,
        feedback_reactions: [],
        generated_files: [],
        identity: "reply:" <> reply.turn_id,
        message_ref: nil,
        occurred_at: reply.occurred_at,
        record_refs: [],
        ref: reply.ref,
        retained: false,
        sort_key: TranscriptCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        state: nil,
        status: reply.status,
        text: "This reply expired under retention.",
        turn_id: reply.turn_id
      }
    ]
  end

  defp reply_message(
         %{document: %{"message" => text} = document} = reply,
         cards,
         artifacts,
         feedback_reactions
       )
       when is_binary(text) do
    outcome = reply_outcome(document)
    record_refs = bounded_refs(outcome["record_refs"])
    artifact_refs = bounded_refs(outcome["artifact_refs"])

    [
      %{
        actor: :ryker,
        artifact_refs: artifact_refs,
        identity: "reply:" <> reply.turn_id,
        retained: true,
        sort_key: TranscriptCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        generated_files:
          artifacts
          |> Enum.filter(fn {{turn_id, ref}, _artifact} ->
            turn_id == reply.turn_id and ref not in artifact_refs
          end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort_by(& &1.name),
        attachments:
          Enum.flat_map(artifact_refs, fn ref ->
            case Map.get(artifacts, {reply.turn_id, ref}) do
              %{} = artifact -> [artifact]
              _missing -> []
            end
          end),
        cards:
          Enum.flat_map(record_refs, fn ref ->
            case Map.get(cards, {reply.turn_id, ref}) do
              %{} = card -> [card]
              _missing -> []
            end
          end),
        episode_ref: reply.episode_ref,
        feedback_reactions: Map.get(feedback_reactions, reply.ref, []),
        message_ref: reply_message_ref(reply),
        occurred_at: reply.occurred_at,
        record_refs: record_refs,
        ref: reply.ref,
        state: outcome["state"],
        status: reply.status,
        text: text,
        turn_id: reply.turn_id
      }
    ]
  end

  defp reply_message(_not_visible_reply, _cards, _artifacts, _feedback_reactions), do: []

  defp reply_message_ref(%{
         status: :settled,
         external_receipt: %{
           "conversation_ref" => conversation_ref,
           "message_ref" => message_ref,
           "transport" => "control_plane"
         }
       })
       when is_binary(conversation_ref) and is_binary(message_ref),
       do: message_ref

  defp reply_message_ref(_reply), do: nil

  defp item_id("control-plane-item:" <> item_id) do
    case Ecto.UUID.cast(item_id) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp item_id(_source_item_ref), do: nil

  defp input_artifact_refs(content) do
    content
    |> input_attachments()
    |> Enum.flat_map(fn
      %{ref: ref, status: "available"} when is_binary(ref) -> [ref]
      _unavailable -> []
    end)
  end

  defp input_attachments(%{"files" => files}) when is_list(files) do
    files
    |> Enum.take(2)
    |> Enum.flat_map(fn
      %{
        "artifact_ref" => ref,
        "bytes" => bytes,
        "media_type" => media_type,
        "name" => name,
        "status" => "available"
      }
      when is_binary(ref) and is_integer(bytes) and bytes > 0 and is_binary(media_type) and
             is_binary(name) ->
        [
          %{
            bytes: bytes,
            media_type: media_type,
            name: name,
            ref: ref,
            status: "available"
          }
        ]

      %{"reason" => reason, "status" => "unavailable"} when is_binary(reason) ->
        [%{bytes: nil, media_type: nil, name: "Attachment", ref: nil, status: reason}]

      _invalid ->
        []
    end)
  end

  defp input_attachments(_content), do: []

  defp reply_outcome(%{"outcome" => %{} = outcome}), do: outcome
  defp reply_outcome(_document), do: %{}

  defp bounded_refs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_024))
    |> Enum.take(64)
  end

  defp bounded_refs(_values), do: []

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
