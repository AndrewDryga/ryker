defmodule Responder.Admission.RoutingContractTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.{Context, Decision, Prompt}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Origin, Origins}
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership
  alias Responder.Slack.Input, as: SlackInput

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
    assert candidate.digest["objective"] =~ "pgsql-prod-01"
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

    assert request["context"]["conversation_context"]["current"]["content"]["text"] ==
             "A new question"

    assert request["context"]["context_manifest"]["cutoff"]
    refute Map.has_key?(request["context"], "routing_receipt")

    snapshot = Context.snapshot(context)

    assert {:ok, restored} =
             Context.restore(snapshot, context.input, entry, episodes_by_id(context))

    assert Context.for_model(restored) == Context.for_model(context)
    assert restored.routing_receipt == context.routing_receipt
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
