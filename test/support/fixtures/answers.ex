defmodule Ryker.Fixtures.Answers do
  @moduledoc """
  Ryker's answers as the host records them once delivered, for the tests of
  what people say about them: a person's Slack message, the Work reply its
  request delivered (through the same custody steps Work takes), the quick
  reply routing sent for it, and an update the Work model posted.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Ryker.Admission.Decision
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{PlatformAction, RoutingResponse}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.{Entry, EntryChangeset}
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @doc """
  A person's Slack message, received. `:thread` is the thread it replies in;
  without one it starts its own. `:kind` and `:revision` make it an edit or a
  deletion of the message `:ts` names.
  """
  def slack_message!(options) do
    ts = Keyword.fetch!(options, :ts)

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{
                 kind: Keyword.get(options, :actor_kind, :user),
                 ref: Keyword.get(options, :actor, "UALICE")
               },
               channel_ref: Keyword.fetch!(options, :channel),
               content: %{"text" => Keyword.fetch!(options, :text)},
               event_kind: Keyword.get(options, :kind, :message),
               event_ref:
                 Keyword.get(
                   options,
                   :event_ref,
                   "Ev-#{ts}-#{Keyword.get(options, :revision, 1)}"
                 ),
               message_ref: ts,
               occurred_at: Keyword.get_lazy(options, :at, fn -> slack_time(ts) end),
               revision: Keyword.get(options, :revision, 1),
               thread_ref: Keyword.get(options, :thread),
               workspace_ref: Keyword.fetch!(options, :workspace)
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  @doc """
  The Work reply the message's request delivered at `at`, as Slack message
  `reply_ts` in the message's thread. The message starts that request.
  """
  def work_reply!(%Entry{} = entry, text, reply_ts, %DateTime{} = at) do
    id = Ecto.UUID.generate()
    key = "answers:#{id}"
    owner = "answers-worker:#{id}"

    assert {:ok, _admitted} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: entry.destination_conversation_ref,
                   thread_ref: entry.destination_thread_ref,
                   transport: entry.destination_transport
                 },
                 episode_id: id,
                 episode_key: key,
                 native_input_id: entry.native_input_id,
                 occurred_at: entry.occurred_at,
                 turn_ref: "turn:#{key}"
               })
             )

    decide!(entry, "start_episode", id)
    assert {:ok, _session} = Custody.pin_episode(id, "answers", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next(owner, 60, :work)
    assert claim.episode.id == id

    assert {:ok, submission} =
             Submission.new(
               %{},
               "Answer the person.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission,
               selected_input_refs: Enum.uniq(claim.episode.active_input_refs)
             )

    assert {:ok, session} =
             Custody.bind_session(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{key}"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{key}"
             )

    document = %{
      "message" => text,
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    }

    candidate = Jason.encode!(document)
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               id,
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
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               id,
               key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation:#{key}"
             )

    assert {:ok, delivery} = Custody.claim_next(owner, 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               entry.destination_transport,
               entry.destination_conversation_ref,
               entry.destination_thread_ref,
               reply_ts
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(id, key, claim.turn.turn_ref, delivery.lease_ref, receipt)

    Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id), set: [delivered_at: at])
    %{episode: Repo.get!(Ryker.Episodes.Episode, id), turn: Repo.get!(Turn, claim.turn.id)}
  end

  @doc "The message joins the request `episode_id`, as routing would add it."
  def join!(%Entry{} = entry, episode_id), do: decide!(entry, "continue_episode", episode_id)

  @doc "The quick reply routing sent for the message at `at`, as Slack message `reply_ts`."
  def quick_reply!(%Entry{} = entry, text, reply_ts, %DateTime{} = at) do
    decide!(entry, "quick_reply", nil, [text])
    document = %{"message" => text}

    receipt = %{
      "conversation_ref" => entry.destination_conversation_ref,
      "delivery_ref" => "ingress-message:#{entry.id}:1",
      "message_ref" => reply_ts,
      "thread_ref" => entry.destination_thread_ref,
      "transport" => entry.destination_transport
    }

    Repo.insert!(%RoutingResponse{
      id: Ecto.UUID.generate(),
      input_id: entry.id,
      position: 1,
      kind: :message,
      decision_ref: "decision:#{entry.id}",
      delivery_ref: "ingress-message:#{entry.id}:1",
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref,
      thread_ref: entry.destination_thread_ref,
      source_item_ref: entry.source_item_ref,
      document: document,
      document_fingerprint: CanonicalJSON.digest(document),
      status: :delivered,
      attempt_count: 1,
      external_receipt: receipt,
      external_receipt_fingerprint: CanonicalJSON.digest(receipt),
      delivered_at: at
    })
  end

  @doc "An update the Work model posted for `reply`'s request, as Slack message `post_ts`."
  def post!(%{episode: episode, turn: turn}, text, post_ts, %DateTime{} = at) do
    document = %{"message" => text}

    receipt = %{
      "conversation_ref" => episode.destination_conversation_ref,
      "message_ref" => post_ts,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }

    Repo.insert!(%PlatformAction{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      turn_id: turn.id,
      action_ref: "update:#{post_ts}",
      host_slot: "update:#{post_ts}",
      tool: :post_slack_message,
      kind: :message,
      transport: episode.destination_transport,
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      document: document,
      intent_fingerprint: CanonicalJSON.digest(document),
      status: :delivered,
      external_receipt: receipt,
      external_receipt_fingerprint: CanonicalJSON.digest(receipt),
      delivered_at: at
    })
  end

  @doc "The time a Slack message timestamp names."
  def slack_time(ts) do
    {seconds, _rest} = Float.parse(ts)
    seconds |> Kernel.*(1_000_000) |> round() |> DateTime.from_unix!(:microsecond)
  end

  defp decide!(entry, action, episode_id, messages \\ nil) do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => action,
               "episode_ref" => if(action == "continue_episode", do: "candidate:answers"),
               "messages" => messages,
               "reactions" => nil,
               "relation" => if(action == "continue_episode", do: "same_work", else: "unrelated"),
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Recorded for a feedback test.",
               "work_class" =>
                 case action do
                   "quick_reply" -> nil
                   "reply" -> "conversational"
                   _work -> "standard"
                 end
             })

    Repo.update!(EntryChangeset.decide(entry, decision, "decision:#{entry.id}", episode_id))
  end
end
