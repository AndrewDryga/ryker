defmodule Responder.ControlPlane.ConversationHistoryTest do
  @moduledoc """
  The paging contract of one conversation's retained transcript.

  Until 2026-09-13 the Conversation Lab loaded the newest 200 inputs, the newest
  200 replies and the newest 200 actions independently, merged them and showed
  the last 200. Anything older was unreachable from the page, and an edited
  message jumped to the end because its position was the latest revision's
  timestamp. These tests pin one deterministic total order over the merged
  transcript so that bounded keyset pages neither skip nor repeat a row.
  """
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.ControlPlane.{ConversationLab, LabCursor, Projection}
  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.WorkProfile
  alias Responder.Repo
  alias Responder.State.Records
  alias Responder.Work.{Custody, DeliveryReceipt, Result, SubmissionBuilder, Turn}

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d8a01"
  @other_conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d8a02"
  @epoch ~U[2026-09-01 12:00:00.000000Z]
  @page_size 50
  @row_bound 64

  test "history pages traverse every retained message once in one deterministic order" do
    # 232 rows across three sources is more than the former 200-row window and
    # more than four pages; the former projection could only ever show 200 of
    # them and could never show the oldest 32 at all.
    history = long_history!()

    assert length(history.expected) == 232
    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert length(conversation.messages) == @page_size
    assert conversation.history.exhausted == false
    assert is_binary(conversation.history.before)
    assert Enum.map(conversation.messages, & &1.identity) == Enum.take(history.expected, -50)

    pages = traverse!(conversation)
    assert Enum.map(pages, &length/1) == [50, 50, 50, 50, 32]
    traversed = pages |> Enum.reverse() |> List.flatten()
    assert Enum.map(traversed, & &1.identity) == history.expected
    assert traversed |> Enum.map(& &1.sort_key) |> Enum.uniq() |> length() == 232
    assert traversed == Enum.sort_by(traversed, & &1.sort_key)

    # Reply cards, generated artifacts and reactions stay attached to the row
    # they belong to, even when that row lives three pages back.
    carded = Enum.find(traversed, &(&1.identity == history.carded_reply))
    assert [%{kind: "task_offer", title: "Finish paging"}] = carded.cards
    reacted = Enum.find(traversed, &(&1.identity == history.reacted_input))
    assert [%{emoji_name: "eyes"}] = reacted.reactions
    assert reacted.actor == :operator
  end

  test "page boundaries split exact timestamp ties without skipping or repeating" do
    history = long_history!()
    assert {:ok, first} = Projection.lab_history(@conversation_id, nil, 50)
    assert {:ok, second} = Projection.lab_history(@conversation_id, first.before, 50)
    assert {:ok, third} = Projection.lab_history(@conversation_id, second.before, 50)

    # Four rows from three sources share one microsecond exactly where the
    # first page ends. The oldest two of them open the second page.
    tied = history.tied_identities
    assert Enum.map(Enum.take(first.messages, 2), & &1.identity) == Enum.drop(tied, 2)
    assert Enum.map(Enum.take(second.messages, -2), & &1.identity) == Enum.take(tied, 2)

    assert Enum.uniq(Enum.map(second.messages ++ first.messages, & &1.identity)) |> length() ==
             100

    refute Enum.any?(third.messages, &(&1.identity in tied))

    # A page cut at a tie cannot move because the cursor carries the tie-breaker.
    assert {:ok, again} = Projection.lab_history(@conversation_id, first.before, 50)
    assert Enum.map(again.messages, & &1.identity) == Enum.map(second.messages, & &1.identity)
  end

  test "an edited or deleted message keeps its original position and shows its current revision" do
    history = long_history!()

    all =
      @conversation_id
      |> Projection.lab_conversation()
      |> elem(1)
      |> traverse!()
      |> Enum.reverse()
      |> List.flatten()

    edited = Enum.find(all, &(&1.identity == history.edited_input))
    assert edited.text == "Message 7, third wording"
    assert edited.event_kind == :edit
    assert edited.revision == 3
    assert edited.editable
    assert DateTime.compare(edited.edited_at, edited.occurred_at) == :gt
    assert Enum.find_index(all, &(&1.identity == history.edited_input)) == history.edited_index

    deleted = Enum.find(all, &(&1.identity == history.deleted_input))
    assert deleted.text == "Message deleted"
    assert deleted.event_kind == :delete
    refute deleted.editable
    assert Enum.find_index(all, &(&1.identity == history.deleted_input)) == history.deleted_index
  end

  test "an expired message keeps its place as explicit retention state, never as an empty conversation" do
    history = long_history!()

    all =
      @conversation_id
      |> Projection.lab_conversation()
      |> elem(1)
      |> traverse!()
      |> Enum.reverse()
      |> List.flatten()

    expired_input = Enum.find(all, &(&1.identity == history.expired_input))
    assert expired_input.actor == :operator
    assert expired_input.retained == false
    refute expired_input.editable
    refute expired_input.text =~ "Message 3"

    assert Enum.find_index(all, &(&1.identity == history.expired_input)) ==
             history.expired_input_index

    expired_reply = Enum.find(all, &(&1.identity == history.expired_reply))
    assert expired_reply.actor == :responder
    assert expired_reply.retained == false
    refute expired_reply.text =~ "Reply 4 "

    assert Enum.find_index(all, &(&1.identity == history.expired_reply)) ==
             history.expired_reply_index

    # A conversation whose only message expired is not a new conversation.
    {:ok, %{entry: only}} = send!(@other_conversation_id, "Only message", 1)
    expire_input!(only)
    assert {:ok, other} = Projection.lab_conversation(@other_conversation_id)
    assert [%{actor: :operator, retained: false}] = other.messages
    assert other.history.exhausted
  end

  test "arrivals after a page was cut do not shift the older page" do
    history = long_history!()
    assert {:ok, first} = Projection.lab_history(@conversation_id, nil, 50)
    assert {:ok, before_arrivals} = Projection.lab_history(@conversation_id, first.before, 50)

    # Three newer messages land after the first page was cut, and one lands
    # with a commit timestamp older than the newest loaded rows.
    late = for index <- 1..3, do: send!(@conversation_id, "Late arrival #{index}", 500 + index)
    {:ok, %{entry: backdated}} = send!(@conversation_id, "Backdated arrival", 499)
    place_input!(backdated, history.backdated_position)

    assert {:ok, after_arrivals} = Projection.lab_history(@conversation_id, first.before, 50)

    assert Enum.map(after_arrivals.messages, & &1.identity) ==
             Enum.map(before_arrivals.messages, & &1.identity)

    assert {:ok, latest} = Projection.lab_history(@conversation_id, nil, 50)
    latest_identities = Enum.map(latest.messages, & &1.identity)

    assert Enum.take(latest_identities, -3) ==
             Enum.map(late, fn {:ok, %{entry: entry}} -> "input:#{entry.native_input_id}" end)

    older =
      Enum.count(history.positions, &(DateTime.compare(&1, history.backdated_position) == :lt))

    total = length(history.positions) + 4

    assert Enum.find_index(latest_identities, &(&1 == "input:#{backdated.native_input_id}")) ==
             older - (total - 50)

    assert latest.messages == Enum.sort_by(latest.messages, & &1.sort_key)
  end

  test "each history page costs a bounded number of bounded queries" do
    long_history!()
    assert {:ok, first} = Projection.lab_history(@conversation_id, nil, 50)
    first_page = measure(fn -> Projection.lab_history(@conversation_id, nil, 50) end)
    assert {:ok, third} = Projection.lab_history(@conversation_id, first.before, 50)
    deep_page = measure(fn -> Projection.lab_history(@conversation_id, third.before, 50) end)

    # No query ever returns more than a page plus one row of lookahead, and a
    # deep page costs the same number of queries as the first one.
    for {queries, label} <- [{first_page, "latest"}, {deep_page, "deep"}] do
      assert length(queries) <= 12, "#{label} page ran #{length(queries)} queries"

      assert Enum.all?(queries, &(&1 <= @row_bound)),
             "#{label} page returned #{inspect(queries)} rows"
    end

    assert length(first_page) == length(deep_page)
  end

  test "a cursor from another conversation or a malformed cursor is refused" do
    long_history!()
    {:ok, %{entry: _other}} = send!(@other_conversation_id, "Other conversation", 1)
    assert {:ok, first} = Projection.lab_history(@conversation_id, nil, 50)

    assert Projection.lab_history(@other_conversation_id, first.before, 50) ==
             {:error, :invalid_cursor}

    assert Projection.lab_history(@conversation_id, "not-a-cursor", 50) ==
             {:error, :invalid_cursor}

    assert Projection.lab_history(@conversation_id, "", 50) == {:error, :invalid_cursor}
    assert Projection.lab_history(@conversation_id, 42, 50) == {:error, :invalid_cursor}

    forged =
      Base.url_encode64(~s({"v":1,"c":"#{@conversation_id}","t":"soon","k":0,"i":"x"}),
        padding: false
      )

    assert Projection.lab_history(@conversation_id, forged, 50) == {:error, :invalid_cursor}

    assert Projection.lab_history("not-a-uuid", nil, 50) == :not_found
    assert Projection.lab_history(Ecto.UUID.generate(), nil, 50) == :not_found

    # The boundary names the oldest row on the page, tie-breaker included.
    assert {:ok, key} = LabCursor.decode(first.before, @conversation_id)
    assert key == hd(first.messages).sort_key
    assert {micros, 1, "reply:" <> _} = key
    assert is_integer(micros)
    assert LabCursor.decode(first.before, @other_conversation_id) == :error
  end

  test "rows changed since a moment are reported wherever they sit in history" do
    # A live window refreshes only the latest page. An edit, a reaction or a
    # retention prune on a row four pages back must still reach the window,
    # so the projection can name every row changed since the last sync.
    history = long_history!()
    since = DateTime.utc_now()
    assert {:ok, []} = Projection.lab_changes(@conversation_id, since)

    all =
      @conversation_id
      |> Projection.lab_conversation()
      |> elem(1)
      |> traverse!()
      |> Enum.reverse()
      |> List.flatten()

    edited = Enum.find(all, &(&1.identity == history.edited_input))

    {:ok, _revised} =
      ConversationLab.edit_message(@conversation_id, edited.item_id, "Fourth wording", profile())

    "reply:" <> turn_id = history.carded_reply

    Repo.update_all(from(t in Turn, where: t.id == ^turn_id),
      set: [
        delivery_document: %{"retention" => "pruned"},
        operational_pruned_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )

    assert {:ok, changed} = Projection.lab_changes(@conversation_id, since)

    assert Enum.map(changed, &{&1.identity, &1.text}) == [
             {history.edited_input, "Fourth wording"},
             {history.carded_reply, "This reply expired under retention."}
           ]

    assert changed == Enum.sort_by(changed, & &1.sort_key)
    assert Enum.find(changed, &(&1.identity == history.edited_input)).sort_key == edited.sort_key

    assert Projection.lab_changes("not-a-uuid", since) == :not_found
    assert Projection.lab_changes(@conversation_id, "yesterday") == :not_found
  end

  test "processing state does not depend on which page is loaded" do
    # The former projection derived "Processing" from the same 200-row window
    # it displayed, so a delivery still pending behind 200 newer rows read as
    # settled. Status queries are bounded on their own, not on the page.
    {:ok, %{entry: entry}} = send!(@other_conversation_id, "One decided message", 1)
    turn = accepted_reply!(entry, @other_conversation_id)
    decide_all_inputs!(@other_conversation_id)

    assert {:ok, settled} = Projection.lab_conversation(@other_conversation_id)
    refute settled.live
    assert settled.pending == 0

    for index <- 1..201 do
      action = delivered_action!(turn, index, @other_conversation_id)
      place!(:action, action, DateTime.add(@epoch, 100 + index, :second))
    end

    pending_action!(turn, DateTime.add(@epoch, 5, :second), @other_conversation_id)
    assert {:ok, live} = Projection.lab_conversation(@other_conversation_id)
    assert live.live
    assert length(live.messages) == @page_size
    refute Enum.any?(live.messages, &(&1.status == :pending))
  end

  defp traverse!(conversation) do
    Stream.unfold({:page, conversation.messages, conversation.history}, fn
      :done ->
        nil

      {:page, messages, %{exhausted: true, before: nil}} ->
        {messages, :done}

      {:page, messages, %{before: cursor}} when is_binary(cursor) ->
        assert {:ok, next} = Projection.lab_history(@conversation_id, cursor, @page_size)
        {messages, {:page, next.messages, %{before: next.before, exhausted: next.exhausted}}}
    end)
    |> Enum.to_list()
  end

  defp measure(fun) do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:responder, :repo, :query],
        &__MODULE__.record_query/4,
        {owner, handler}
      )

    try do
      fun.()
      collect_queries(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  def record_query(_event, _measurements, %{result: result}, {owner, handler}) do
    if self() == owner do
      rows =
        case result do
          {:ok, %{num_rows: rows}} -> rows
          _other -> 0
        end

      send(owner, {handler, rows})
    end
  end

  defp collect_queries(handler, rows) do
    receive do
      {^handler, count} -> collect_queries(handler, [count | rows])
    after
      0 -> Enum.reverse(rows)
    end
  end

  # One conversation with 140 operator inputs, 80 accepted replies and 12
  # delivered platform messages, interleaved and placed at explicit commit
  # times. Every row's expected position is computed from those times.
  defp long_history! do
    inputs =
      for index <- 1..140 do
        {:ok, %{entry: entry}} = send!(@conversation_id, "Message #{index}", index)
        {index, entry}
      end

    turn = accepted_reply!(Enum.at(inputs, 0) |> elem(1), @conversation_id)

    replies =
      for index <- 1..80 do
        {index, clone_reply!(turn, index)}
      end

    actions = for index <- 1..12, do: {index, delivered_action!(turn, index)}

    plan =
      interleave(
        Enum.map(inputs, fn {index, entry} -> {:input, index, entry} end),
        Enum.map(replies, fn {index, reply} -> {:reply, index, reply} end),
        Enum.map(actions, fn {index, action} -> {:action, index, action} end)
      )

    # Positions: one second per step, except a four-row tie straddling the
    # first page boundary (steps 180..183 share step 180's microsecond).
    placed =
      plan
      |> Enum.with_index()
      |> Enum.map(fn {{kind, index, row}, step} ->
        tie_step = if step in 180..183, do: 180, else: step
        position = DateTime.add(@epoch, tie_step, :second)
        place!(kind, row, position)
        {kind, index, row, position}
      end)

    edited = fetch_row(placed, :input, 7)
    deleted = fetch_row(placed, :input, 9)
    expired_input = fetch_row(placed, :input, 3)
    expired_reply = fetch_row(placed, :reply, 4)
    reacted = fetch_row(placed, :input, 5)
    carded = fetch_row(placed, :reply, 1)

    revise!(edited, :edit, "Message 7, second wording", 2)
    revise!(edited, :edit, "Message 7, third wording", 3)
    revise!(deleted, :delete, nil, 2)
    expire_input!(expired_input)
    expire_reply!(expired_reply)
    react!(reacted)

    expected =
      placed
      |> Enum.map(fn {kind, _index, row, position} ->
        {sort_key(kind, row, position), identity(kind, row)}
      end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    tied =
      placed
      |> Enum.filter(fn {_kind, _index, _row, position} ->
        position == DateTime.add(@epoch, 180, :second)
      end)
      |> Enum.map(fn {kind, _index, row, position} ->
        {sort_key(kind, row, position), identity(kind, row)}
      end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    backdated_position = DateTime.add(@epoch, 200, :second) |> DateTime.add(500, :millisecond)

    %{
      backdated_position: backdated_position,
      carded_reply: identity(:reply, carded),
      deleted_index: Enum.find_index(expected, &(&1 == identity(:input, deleted))),
      deleted_input: identity(:input, deleted),
      edited_index: Enum.find_index(expected, &(&1 == identity(:input, edited))),
      edited_input: identity(:input, edited),
      expected: expected,
      expired_input: identity(:input, expired_input),
      expired_input_index: Enum.find_index(expected, &(&1 == identity(:input, expired_input))),
      expired_reply: identity(:reply, expired_reply),
      expired_reply_index: Enum.find_index(expected, &(&1 == identity(:reply, expired_reply))),
      positions: Enum.map(placed, fn {_kind, _index, _row, position} -> position end),
      reacted_input: identity(:input, reacted),
      tied_identities: tied,
      turn: turn
    }
  end

  # Sixty inputs open the conversation, then inputs and replies alternate, and
  # a delivered action follows every eighteenth row. Rows 171..174, which share
  # one timestamp, are therefore reply, input, reply, input.
  defp interleave(inputs, replies, actions) do
    {leading, paired} = Enum.split(inputs, 60)

    rows =
      leading ++ Enum.flat_map(Enum.zip(paired, replies), fn {input, reply} -> [input, reply] end)

    rows
    |> Enum.chunk_every(18)
    |> Enum.zip(actions ++ [nil])
    |> Enum.flat_map(fn {chunk, action} -> chunk ++ Enum.reject([action], &is_nil/1) end)
  end

  defp fetch_row(placed, kind, index) do
    {^kind, ^index, row, _position} =
      Enum.find(placed, fn {k, i, _row, _position} -> k == kind and i == index end)

    row
  end

  defp identity(:input, %Entry{native_input_id: id}), do: "input:#{id}"
  defp identity(:reply, %Turn{id: id}), do: "reply:#{id}"
  defp identity(:action, %PlatformAction{id: id}), do: "action:#{id}"

  defp sort_key(kind, row, position) do
    rank = %{input: 0, reply: 1, action: 2}[kind]
    {DateTime.to_unix(position, :microsecond), rank, identity(kind, row)}
  end

  defp place!(:input, entry, position), do: place_input!(entry, position)

  defp place!(:reply, turn, position) do
    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [accepted_at: position, delivered_at: DateTime.add(position, 1, :millisecond)]
    )
  end

  defp place!(:action, action, position) do
    Repo.update_all(from(a in PlatformAction, where: a.id == ^action.id),
      set: [delivered_at: position, inserted_at: DateTime.add(position, -1, :second)]
    )
  end

  defp place_input!(entry, position) do
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [inserted_at: position])
  end

  defp send!(conversation_id, text, index) do
    ConversationLab.send_message(conversation_id, text, profile(),
      id_generator: fn -> Ecto.UUID.generate() end,
      now: fn -> DateTime.add(@epoch, index, :second) end
    )
  end

  # Revisions are recorded through the real edit/delete path and then placed
  # far in the future: the position of the item must not follow them.
  defp revise!(entry, kind, text, revision) do
    "control-plane-item:" <> item_id = entry.source_item_ref
    future = fn -> DateTime.add(@epoch, 100_000 + revision, :second) end

    {:ok, %{entry: revised}} =
      case kind do
        :edit ->
          ConversationLab.edit_message(@conversation_id, item_id, text, profile(), now: future)

        :delete ->
          ConversationLab.delete_message(@conversation_id, item_id, profile(), now: future)
      end

    assert revised.revision == revision
    place_input!(revised, future.())
  end

  defp expire_input!(entry) do
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [content: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )
  end

  defp expire_reply!(turn) do
    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [
        delivery_document: %{"retention" => "pruned"},
        operational_pruned_at: DateTime.utc_now()
      ]
    )
  end

  defp react!(entry) do
    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: DateTime.utc_now(),
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "A nonverbal acknowledgement is sufficient.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:history-reaction")
  end

  defp decide_all_inputs!(conversation_id) do
    ref = conversation_ref(conversation_id)

    Repo.all(from(e in Entry, where: e.destination_conversation_ref == ^ref))
    |> Enum.each(fn entry ->
      if entry.status == :pending do
        Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
          set: [
            status: :decided,
            decision_ref: "decision:history:#{entry.id}",
            decision_fingerprint: String.duplicate("d", 64),
            decision_action: :ignore,
            decision_document: %{"action" => "ignore"}
          ]
        )
      end
    end)
  end

  defp pending_action!(turn, inserted_at, conversation_id) do
    Repo.insert!(%PlatformAction{
      id: Ecto.UUID.generate(),
      episode_id: turn.episode_id,
      turn_id: turn.id,
      action_ref: "platform-action:history:pending",
      host_slot: "history-pending",
      tool: :post_slack_message,
      kind: :message,
      transport: "control_plane",
      conversation_ref: conversation_ref(conversation_id),
      thread_ref: conversation_ref(conversation_id),
      document: %{"message" => "Still being delivered."},
      intent_fingerprint: String.duplicate("f", 64),
      status: :pending,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp delivered_action!(turn, index, conversation_id \\ @conversation_id) do
    now = DateTime.utc_now()

    Repo.insert!(%PlatformAction{
      id: Ecto.UUID.generate(),
      episode_id: turn.episode_id,
      turn_id: turn.id,
      action_ref: "platform-action:history:#{conversation_id}:#{index}",
      host_slot: "history-#{index}",
      tool: :post_slack_message,
      kind: :message,
      transport: "control_plane",
      conversation_ref: conversation_ref(conversation_id),
      thread_ref: conversation_ref(conversation_id),
      document: %{"message" => "Action #{index}"},
      intent_fingerprint: String.duplicate("e", 64),
      status: :delivered,
      external_receipt: %{"message_ref" => "message:action:#{index}"},
      external_receipt_fingerprint: String.duplicate("c", 64),
      delivered_at: now,
      inserted_at: now,
      updated_at: now
    })
  end

  # One reply through the real custody path: staged, validated, accepted and
  # delivered, carrying a task offer card. Every other reply is a clone of it.
  defp accepted_reply!(entry, conversation_id) do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:history:#{episode_id}"
    conversation_ref = conversation_ref(conversation_id)

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "conversation-lab:#{conversation_id}",
                 native_input_id: entry.native_input_id,
                 occurred_at: @epoch,
                 payload: %{"text" => "Message 1"},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, profile().policy, profile().policy_digest)

    assert {:ok, claim} = Custody.claim_next("conversation-history", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:conversation-history"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:conversation-history"
             )

    assert {:ok, task_offer} =
             Records.create(Records.token(claim.turn), "history-task", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement bounded conversation paging.",
               "repository" => "responder",
               "title" => "Finish paging"
             })

    document = %{
      "message" => "Reply 1 carries a card.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [task_offer.ref],
        "state" => "complete"
      }
    }

    candidate = Jason.encode!(document)
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, document)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:conversation-history"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:conversation-history", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref,
               conversation_ref,
               "message:history:1"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    settled.turn
  end

  defp clone_reply!(turn, 1), do: Repo.get!(Turn, turn.id)

  defp clone_reply!(turn, index) do
    id = Ecto.UUID.generate()

    %{
      turn
      | id: id,
        turn_ref: "turn:history:clone:#{index}",
        coop_turn_id: "coop-turn:history:#{index}",
        result_ref: "result:history:#{index}",
        delivery_ref: "delivery:history:#{index}",
        delivery_document: %{
          "message" => "Reply #{index} from a cloned accepted turn.",
          "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
        },
        external_receipt: %{
          "conversation_ref" => conversation_ref(),
          "message_ref" => "message:history:#{index}",
          "thread_ref" => conversation_ref(),
          "transport" => "control_plane"
        }
    }
    |> Ecto.put_meta(state: :built)
    |> Repo.insert!()
  end

  defp conversation_ref(conversation_id \\ @conversation_id),
    do: "control-plane:lab:#{conversation_id}"

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    profile
  end
end
