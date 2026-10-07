defmodule Ryker.ControlPlane.ConversationProjection do
  @moduledoc """
  The direct-conversation pages: the directory, one conversation's merged
  transcript, its retained history pages and change feed, and its artifacts.

  Only exact local operator text, bounded integration-source markers, and
  accepted visible replies cross this read boundary. Prompts, candidates,
  arbitrary external payloads, credentials, and unreleased model output remain
  private.
  """

  alias Ryker.Artifacts.OutputArtifact
  alias Ryker.ControlPlane.{AdmissionProgress, ConversationLab, ConversationQuery}
  alias Ryker.ControlPlane.{ConversationTranscript, PublicationPositionQuery, ShortTime}
  alias Ryker.ControlPlane.TranscriptCursor
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback
  alias Ryker.InspectionRedactor
  alias Ryker.Repo

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
  Lists every loopback conversation the inbox keeps, newest first, without
  loading their message bodies. Retention bounds the list to the operational
  horizon; a cut at the newest 100 hid the oldest from the list and its
  filter (9 of 109 live, 2026-10-05).
  """
  def index do
    @prefix
    |> ConversationQuery.directory()
    |> Repo.all()
    |> Enum.flat_map(fn item ->
      case conversation_id(item.ref) do
        {:ok, id} -> [Map.put(item, :id, id)]
        :error -> []
      end
    end)
    |> directory_titles()
    |> directory_states()
    |> directory_environments()
  end

  # The environment each conversation works in, the one its head shows, so
  # the list can name it on every row.
  defp directory_environments([]), do: []

  defp directory_environments(items) do
    environments = ConversationLab.environments(Enum.map(items, & &1.id))
    Enum.map(items, &Map.put(&1, :environment_ref, Map.get(environments, &1.id)))
  end

  defp directory_titles([]), do: []

  defp directory_titles(items) do
    titles = titles(Enum.map(items, & &1.ref))

    Enum.map(items, fn item ->
      Map.put(
        item,
        :title,
        titles[item.ref] || "Conversation · " <> ShortTime.day(item.updated_at, Date.utc_today())
      )
    end)
  end

  @doc """
  What each direct conversation is called, by conversation reference: the
  name Ryker gave its latest work there, or else its opening message. A
  conversation with neither has no title.
  """
  @spec titles([String.t()]) :: %{String.t() => String.t()}
  def titles([]), do: %{}

  def titles(refs) do
    secrets = InspectionRedactor.configured_secrets()

    refs
    |> ConversationQuery.opening_texts()
    |> Repo.all()
    |> Enum.flat_map(fn {ref, text} ->
      case InspectionRedactor.artifact(text, secrets: secrets, max_bytes: 600).text do
        text when text in [nil, ""] -> []
        text -> [{ref, String.slice(text, 0, 160)}]
      end
    end)
    |> Map.new()
    # Once Ryker has named its latest work in a conversation, that name is the
    # conversation's; until then its opening message is.
    |> Map.merge(refs |> ConversationQuery.work_titles() |> Repo.all() |> Map.new())
  end

  # What a conversation needs from the reader, from its inputs and their work:
  # something stopped, Ryker is still at it, it is waiting, or it replied. The
  # database answers one row a conversation; every message row of every
  # conversation listed was read to find these (2026-10-04 review).
  defp directory_states([]), do: []

  defp directory_states(items) do
    refs = Enum.map(items, & &1.ref)

    states =
      refs
      |> ConversationQuery.needs()
      |> Repo.all()
      |> Map.new(fn {ref, needs} -> {ref, conversation_status(needs)} end)

    Enum.map(items, &Map.put(&1, :status, Map.get(states, &1.ref, :replied)))
  end

  defp conversation_status(%{attention: true}), do: :attention
  defp conversation_status(%{working: true}), do: :working
  defp conversation_status(%{waiting_for_you: true}), do: :waiting_for_you
  defp conversation_status(%{waiting: true}), do: :waiting
  defp conversation_status(_needs), do: :replied

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

  @doc "One generated file of an accepted reply, when the reply is retained and belongs to the conversation."
  def artifact(conversation_id, turn_id, artifact_ref)
      when is_binary(turn_id) and is_binary(artifact_ref) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,256}\z/, artifact_ref),
         %OutputArtifact{} = artifact <-
           Repo.one(ConversationQuery.artifact(@prefix <> conversation_id, turn_id, artifact_ref)) do
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
        input_queue.blocked > 0 or input_queue.routing_blocked > 0 or
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
    Repo.exists?(ConversationQuery.messages(ref)) or
      Repo.exists?(ConversationQuery.episodes(ref))
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
  defp identity_value(4, "quick-reply:" <> id), do: Ecto.UUID.cast(id)
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
          input: page_boundary(boundary, :input),
          reply: page_boundary(boundary, :reply),
          action: page_boundary(boundary, :action),
          publication: page_boundary(boundary, :publication),
          quick_reply: page_boundary(boundary, :quick_reply)
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
      ref |> ConversationQuery.inputs(filters.input, limit) |> rows(:input),
      ref |> ConversationQuery.replies(filters.reply, limit) |> rows(:reply),
      ref |> ConversationQuery.actions(filters.action, limit) |> rows(:action),
      ref |> ConversationQuery.publications(filters.publication, limit) |> rows(:publication),
      ref |> ConversationQuery.quick_replies(filters.quick_reply, limit) |> rows(:quick_reply)
    ])
    |> Enum.map(fn {kind, row} -> {candidate_key(kind, row), kind, row} end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp rows(query, kind), do: query |> Repo.all() |> Enum.map(&{kind, &1})

  @doc """
  The current representation of every transcript row that changed at or
  after `since`: a new or revised input, a reaction on one, an accepted or
  confirmed reply, a card whose record moved, a delivered platform message, a
  publication that advanced or a delivered quick reply. Bounded per source;
  ascending display order.

  This is how a live window learns about a row it holds that is no longer on
  the latest page, such as an edit to a message the reader scrolled up to.
  """
  def changes(conversation_id, since, limit \\ @page_size)

  def changes(conversation_id, %DateTime{} = since, limit)
      when is_integer(limit) and limit in 1..@page_maximum do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} ->
        ref = @prefix <> conversation_id
        revised = revised_input_ids(ref, since, limit)
        # A reaction on a quick reply or an update is feedback on its
        # request, never an event of the message's own row.
        reacted = Feedback.reacted_messages(ref, since, limit)

        candidates =
          candidates(
            ref,
            %{
              input: changed_inputs(ref, revised, since, limit),
              reply: changed_replies(ref, revised, since, limit),
              action: changed_actions(ref, since, limit, reacted),
              publication: changed_publications(ref, since, limit),
              quick_reply: changed_quick_replies(ref, since, limit, reacted)
            },
            limit * 2
          )

        {:ok, ConversationTranscript.messages(candidates, conversation_id)}

      :error ->
        :not_found
    end
  end

  def changes(_conversation_id, _since, _limit), do: :not_found

  defp changed_inputs(ref, revised, since, limit) do
    reacted =
      Repo.all(ConversationQuery.routing_reacted_items(ref, since, limit)) ++
        Repo.all(ConversationQuery.work_reacted_items(ref, since, limit))

    if revised == [] and reacted == [], do: :none, else: {:inputs, revised, reacted}
  end

  defp revised_input_ids(ref, since, limit),
    do: Repo.all(ConversationQuery.revised_message_ids(ref, since, limit))

  defp changed_replies(ref, revised, since, limit) do
    turn_ids =
      Repo.all(ConversationQuery.updated_turn_ids(ref, since, limit)) ++
        Repo.all(ConversationQuery.moved_record_turn_ids(ref, since, limit)) ++
        revised_answer_turn_ids(revised, limit)

    delivery_refs =
      ref
      |> ConversationQuery.reacted_delivery_refs(since, limit)
      |> Repo.all()
      |> Enum.filter(&is_binary/1)

    if turn_ids == [] and delivery_refs == [],
      do: :none,
      else: {:replies, turn_ids, delivery_refs}
  end

  # An edit changes what the earlier replies to that message say about
  # themselves ("Answered your earlier wording"), though their own rows did not.
  defp revised_answer_turn_ids([], _limit), do: []

  defp revised_answer_turn_ids(native_ids, limit),
    do: Repo.all(ConversationQuery.answering_turn_ids(native_ids, limit))

  defp changed_actions(ref, since, limit, reacted),
    do: ref |> ConversationQuery.changed_action_ids(since, reacted, limit) |> exact_rows()

  defp changed_publications(ref, since, limit),
    do: ref |> ConversationQuery.changed_publication_ids(since, limit) |> exact_rows()

  defp changed_quick_replies(ref, since, limit, reacted),
    do: ref |> ConversationQuery.changed_quick_reply_ids(since, reacted, limit) |> exact_rows()

  defp exact_rows(query) do
    case Repo.all(query) do
      [] -> :none
      ids -> {:ids, ids}
    end
  end

  defp candidate_key(:input, row),
    do: TranscriptCursor.key(row.position, :input, "input:" <> row.native_input_id)

  defp candidate_key(:reply, row),
    do: TranscriptCursor.key(row.occurred_at, :reply, "reply:" <> row.turn_id)

  defp candidate_key(:action, row),
    do: TranscriptCursor.key(row.delivered_at, :action, "action:" <> row.id)

  defp candidate_key(:quick_reply, row),
    do: TranscriptCursor.key(row.delivered_at, :quick_reply, "quick-reply:" <> row.id)

  defp candidate_key(:publication, {publication, _record_ref}) do
    TranscriptCursor.key(
      PublicationPositionQuery.at(publication),
      :publication,
      "publication:" <> publication.id
    )
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

  defp input_queue(ref) do
    entries = Repo.one(ConversationQuery.message_counts(ref))

    # A response waiting behind a stopped earlier one of its message is not
    # being sent: the stopped one says so, and the conversation is not live.
    responses = Repo.one(ConversationQuery.response_counts(ref))

    %{
      blocked: entries.blocked,
      pending: entries.pending,
      routing_blocked: responses.blocked,
      routing_pending: responses.pending
    }
  end

  # Whether anything in this conversation is still being delivered, measured
  # over the whole conversation rather than the page on screen.
  defp delivery_state(ref) do
    %{
      actions_blocked: action_status?(ref, :blocked),
      actions_pending: action_status?(ref, :pending),
      publications_pending: Repo.exists?(ConversationQuery.publications_under_way(ref)),
      replies_pending: Repo.exists?(ConversationQuery.replies_waiting(ref))
    }
  end

  defp action_status?(ref, status),
    do: Repo.exists?(ConversationQuery.actions_in_status(ref, status))

  defp episodes(ref) do
    ref
    |> ConversationQuery.latest_episodes(20)
    |> Repo.all()
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

  defp live?(input_queue, episodes, deliveries) do
    input_queue.pending > 0 or input_queue.routing_pending > 0 or
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
