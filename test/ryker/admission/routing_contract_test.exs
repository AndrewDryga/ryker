defmodule Ryker.Admission.RoutingContractTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Admission
  alias Ryker.Admission.{Candidate, Context, Decision, Prompt}
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Origin, Origins}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Custody, Turn}

  @moduletag isolation: "REPEATABLE READ"

  @workspace "TROUTE"
  @now ~U[2026-09-11 12:00:00.000000Z]

  setup do
    Enum.each(~w(CDEVOPS CALERTS CENGINEERING), &joined!/1)
    :ok
  end

  test "a human message can join work that started in another channel" do
    # Admission searched only the destination conversation and forbade a human
    # actor from continuing any thread but their own, so one outage reported in
    # #devops and discussed in #engineering became two episodes with two owners
    # that each investigated it separately.
    incident =
      episode!("routing:incident",
        channel_ref: "CDEVOPS",
        text: "Postgres primary pgsql-prod-01 is unreachable; replication is stalled"
      )

    entry =
      record!(
        channel_ref: "CENGINEERING",
        actor: %{kind: :user, ref: "UALICE"},
        text: "Is pgsql-prod-01 still unreachable? Replication looks stalled to me too.",
        ts: "1789000100.000100"
      )

    {:ok, context} = context!(entry)
    candidate = Enum.find(context.candidates, &(&1.episode.id == incident.id))

    assert candidate, "the matching incident in another channel was not offered"
    assert :same_work in candidate.allowed_relations
    refute candidate.same_thread
    assert candidate.first_input_preview["text"] =~ "pgsql-prod-01"
    assert candidate.match["direct_references"] >= 0
    assert candidate.match["topic_fit"] > 0.0

    decision = decision!(:continue_episode, candidate.ref, :same_work)
    {:ok, result} = Admission.commit(context, decision, "routing-test:#{entry.id}")

    assert result.episode.id == incident.id
    assert result.episode.destination_conversation_ref == "slack:#{@workspace}:CDEVOPS"

    assert Origins.participating_conversations(incident.id) == [
             "slack:#{@workspace}:CDEVOPS",
             "slack:#{@workspace}:CENGINEERING"
           ]
  end

  test "one thread holds several episodes and each message joins the right one" do
    database =
      episode!("routing:database",
        channel_ref: "CENGINEERING",
        text: "The reporting database is unavailable and queries are timing out",
        thread_ref: "1789001000.000100"
      )

    review =
      episode!("routing:review",
        channel_ref: "CENGINEERING",
        text: "Please review pull request 4120 for the billing rename",
        thread_ref: "1789001000.000100"
      )

    entry =
      record!(
        channel_ref: "CENGINEERING",
        actor: %{kind: :user, ref: "UCAROL"},
        text: "The reporting database replica recovered and queries are fast again",
        ts: "1789001100.000100",
        thread_ref: "1789001000.000100"
      )

    {:ok, context} = context!(entry)
    refs = Map.new(context.candidates, &{&1.episode.id, &1})

    assert refs[database.id].same_thread
    assert refs[review.id].same_thread
    assert refs[database.id].match["topic_fit"] > refs[review.id].match["topic_fit"]

    decision = decision!(:continue_episode, refs[database.id].ref, :same_work)
    {:ok, result} = Admission.commit(context, decision, "routing-test:#{entry.id}")
    assert result.episode.id == database.id
  end

  test "many same-thread episodes no longer stall the thread and the owner still survives" do
    owner =
      episode!("routing:owner", channel_ref: "CDEVOPS", text: "The original alert card")

    native_input_id =
      Repo.one!(
        from(origin in Origin,
          where: origin.episode_id == ^owner.id,
          select: origin.native_input_id
        )
      )

    for index <- 1..30 do
      episode!("routing:thread-noise-#{index}",
        channel_ref: "CDEVOPS",
        text: "Active work #{index}",
        thread_ref: "1789002000.000100"
      )
    end

    entry =
      record!(
        channel_ref: "CDEVOPS",
        text: "The original alert card, edited",
        ts: owner_message_ref(owner),
        thread_ref: "1789002000.000100",
        event_kind: :edit,
        revision: 2
      )

    assert entry.native_input_id == native_input_id

    {:ok, context} = context!(entry)
    assert length(context.candidates) <= 20
    assert hd(context.candidates).episode.id == owner.id
    assert hd(context.candidates).source_owner
    assert context.routing_receipt["offered"] == length(context.candidates)
    assert context.routing_receipt["omitted"] > 0
  end

  test "the frozen context carries the local backdrop, its manifest and the routing receipt" do
    record!(channel_ref: "CDEVOPS", text: "Earlier channel message", ts: "1789003000.000100")

    entry =
      record!(channel_ref: "CDEVOPS", text: "A new question", ts: "1789003001.000100")

    {:ok, context} = context!(entry)

    assert context.conversation_context["current"]["content"]["text"] == "A new question"

    assert Enum.map(context.conversation_context["messages"], & &1["content"]["text"]) == [
             "Earlier channel message"
           ]

    assert context.context_manifest["kind"] == "channel_root"
    assert context.context_manifest["included"] == 1
    assert context.context_manifest["channel_summary"]["reason"] == "absent"
    assert context.routing_receipt["scope"] == "workspace_public"
    assert context.routing_receipt["lanes"]["thread"]["returned"] >= 0

    request = Prompt.build(context)

    # The frozen bundle keeps the current message; the router reads it once, as
    # the input itself, not again inside the conversation.
    assert request["context"]["input"]["content"]["text"] == "A new question"
    refute Map.has_key?(request["context"]["conversation_context"], "current")

    assert Enum.map(request["context"]["conversation_context"]["messages"], & &1["text"]) == [
             "Earlier channel message"
           ]

    assert request["context"]["context_manifest"]["cutoff"]
    refute Map.has_key?(request["context"], "routing_receipt")

    snapshot = Context.snapshot(context)

    assert {:ok, restored} =
             Context.restore(snapshot, context.input, entry, episodes_by_id(context))

    assert Context.for_model(restored) == Context.for_model(context)
    assert restored.routing_receipt == context.routing_receipt
  end

  test "a follow-up routed late can still continue work that finished just before it arrived" do
    # Continuation was judged at routing time. A message sent five minutes after
    # a reply but routed an hour later (a provider outage, then a retry) found
    # that work 65 minutes idle, past the 30-minute window, and could only link
    # it as background.
    finished_at = DateTime.add(@now, -60 * 60, :second)
    thread = "#{DateTime.to_unix(DateTime.add(finished_at, -600, :second))}.000100"

    work =
      episode!("routing:late-follow-up",
        channel_ref: "CDEVOPS",
        text: "Checkout returns 502 on every request",
        thread_ref: thread
      )

    # Finished: no owner and no inputs left, as the kernel leaves completed work.
    Repo.update_all(from(episode in Ryker.Episodes.Episode, where: episode.id == ^work.id),
      set: [
        state: :complete,
        owner_kind: nil,
        owner_ref: nil,
        active_input_refs: [],
        queued_input_refs: [],
        queued_input_order_keys: [],
        updated_at: finished_at
      ]
    )

    entry =
      record!(
        channel_ref: "CDEVOPS",
        actor: %{kind: :user, ref: "UALICE"},
        text: "And is the rollback done?",
        thread_ref: thread,
        ts: "#{DateTime.to_unix(DateTime.add(finished_at, 5 * 60, :second))}.000100"
      )

    {:ok, context} = context!(entry)
    candidate = Enum.find(context.candidates, &(&1.episode.id == work.id))

    assert candidate, "the work in this thread was not offered"
    assert :same_work in candidate.allowed_relations
    assert candidate.idle_minutes == 5
  end

  test "a candidate carries what that work last replied" do
    # Routing chose between earlier work it knew only by its opening message and
    # the state "complete"; recorded reasons show same-thread follow-ups routed
    # as unrelated because nothing said what the earlier work had answered.
    incident =
      episode!("routing:outcome",
        channel_ref: "CDEVOPS",
        text: "Checkout returns 502 on every request"
      )

    {:ok, _session} =
      Custody.pin_episode(incident.id, "routing-outcome", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("routing-outcome:#{incident.id}", 60, :work)

    # An accepted, delivered answer as custody leaves it.
    Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id),
      set: [
        candidate: "{}",
        candidate_sha256: String.duplicate("c", 64),
        candidate_attempt: 1,
        validation_intent: %{"result" => nil, "verdict" => "accept", "violations" => []},
        validation_intent_fingerprint: String.duplicate("f", 64),
        validation_receipt: "validation-receipt",
        result_ref: "result:#{claim.turn.id}",
        continuation: %{"kind" => "complete"},
        accepted_at: @now,
        delivery_ref: "delivery:#{claim.turn.id}",
        delivery_fingerprint: String.duplicate("d", 64),
        external_receipt: %{"message_ref" => "1789000150.000100"},
        external_receipt_fingerprint: String.duplicate("e", 64),
        delivered_at: @now,
        delivery_document: %{
          "delivery" => "reply",
          "message" => "Checkout is back.\r\nThe deploy was rolled back."
        }
      ]
    )

    entry =
      record!(
        channel_ref: "CDEVOPS",
        text: "Is checkout 502 back again?",
        ts: "1789000200.000100"
      )

    {:ok, context} = context!(entry)
    candidate = Enum.find(context.candidates, &(&1.episode.id == incident.id))
    assert candidate, "the earlier checkout work was not offered"

    assert Candidate.for_model(candidate)["outcome"] ==
             "Replied: Checkout is back. The deploy was rolled back."

    # The host applies the continuation window to each candidate's allowed
    # relations; the router is not sent the window or the routing time.
    refute Map.has_key?(Context.for_model(context), "continuation_window_minutes")
    refute Map.has_key?(Context.for_model(context), "now")
  end

  defp episodes_by_id(context) do
    context.candidates |> Enum.map(& &1.episode) |> Map.new(&{&1.id, &1})
  end

  defp context!(entry) do
    Admission.context(Inbox.ref(entry),
      now: @now,
      continuation_window: 30 * 60,
      history_window: 30 * 24 * 60 * 60,
      candidate_limit: 20
    )
  end

  defp decision!(action, episode_ref, relation) do
    {:ok, decision} =
      Decision.parse(%{
        "action" => Atom.to_string(action),
        "episode_ref" => episode_ref,
        "reaction" => nil,
        "relation" => Atom.to_string(relation),
        "reason" => "The evidence names the same unreachable primary.",
        "repository_source" => nil,
        "work_class" => "standard"
      })

    decision
  end

  defp record!(options) do
    {:ok, %{entry: entry}} = Inbox.record(input!(options))
    entry
  end

  defp input!(options) do
    ts = Keyword.fetch!(options, :ts)

    {:ok, input} =
      SlackInput.new(%{
        actor: Keyword.get(options, :actor, %{kind: :app, ref: "A123"}),
        channel_ref: Keyword.fetch!(options, :channel_ref),
        content: %{"text" => Keyword.fetch!(options, :text)},
        event_kind: Keyword.get(options, :event_kind, :message),
        event_ref: "Ev-#{ts}-#{System.unique_integer([:positive])}",
        message_ref: ts,
        occurred_at: slack_time(ts),
        revision: Keyword.get(options, :revision, 1),
        thread_ref: Keyword.get(options, :thread_ref),
        workspace_ref: @workspace
      })

    input
  end

  defp episode!(key, options) do
    ts =
      Keyword.get(options, :thread_ref) ||
        "#{1_789_000_000 + System.unique_integer([:positive])}.000100"

    input = input!(Keyword.merge(options, ts: ts, thread_ref: Keyword.get(options, :thread_ref)))
    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    transition.episode
  end

  defp owner_message_ref(episode) do
    Repo.one!(
      from(origin in Origin,
        where: origin.episode_id == ^episode.id,
        select: origin.source_item_ref
      )
    )
  end

  defp joined!(channel_ref) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: channel_ref,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end

  defp slack_time(ts) do
    {seconds, _rest} = Float.parse(ts)
    seconds |> Kernel.*(1_000_000) |> round() |> DateTime.from_unix!(:microsecond)
  end
end
