defmodule Responder.ControlPlane.EpisodeTraceTest do
  alias Responder.ControlPlane.EpisodeTrace
  alias Responder.ControlPlane.ModelRequests
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.ControlPlane.HTML
  alias Responder.Work.Custody
  alias Responder.Work.Turn

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.Projection
  alias Responder.Episodes
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input

  @received ~U[2026-09-04 22:51:44.000000Z]

  # The reported Lab greeting hid 57 seconds of admission behind a 1.4-minute
  # elapsed label and could not link its source because command and inbox hashes
  # were treated as the same identity.
  test "the source is resolved through the admitted input rather than the command hash" do
    {entry, episode} = admitted_input!()
    assert {:ok, detail} = Projection.episode(episode.key)

    assert detail.trace.source == %{
             href: "https://slack.com/archives/C456/p1788562304000100",
             label: "Open source message",
             transport: "Slack"
           }

    step = Enum.find(detail.trace.steps, &(&1.title == "Input admitted"))
    assert %{label: "Actor", value: "user:U123"} in step.details
    assert %{label: "Event", value: "message"} in step.details
    refute String.starts_with?(entry.dedupe_key, "admit_input:")
  end

  test "elapsed includes admission before the episode was created" do
    {_entry, episode} = admitted_input!()
    assert {:ok, detail} = Projection.episode(episode.key)
    metric = Enum.find(detail.trace.metrics, &(&1.label == "Elapsed"))
    assert metric.value == "2.3m"
  end

  test "expired request content names its expiry instead of looking like a deleted episode" do
    {entry, episode} = admitted_input!()

    Repo.update_all(from(i in Entry, where: i.id == ^entry.id),
      set: [content: %{"retention" => "pruned"}, operational_pruned_at: @received]
    )

    {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.expired_at == @received
  end

  test "an input request addresses the episode it joined without a redirect" do
    {entry, episode} = admitted_input!()
    {:ok, detail} = Projection.episode("ingress-input:#{entry.id}")
    assert detail.episode.ref == episode.key
    assert {:ok, _} = ModelRequests.timeline("ingress-input:#{entry.id}", %{})
  end

  test "preparing an input question is work, not proof a question was sent" do
    # The real infrastructure trace jumped answer -> work -> answer before its first delivery.
    {_entry, episode} = admitted_input!()

    record = %Responder.State.Record{
      id: Ecto.UUID.generate(),
      kind: "input_request",
      status: :answered,
      inserted_at: @received,
      payload: %{
        "reason" => "Available cloud service diagnostics require an explicit project ID.",
        "questions" => [%{"question" => "Which Google Cloud project ID should I check?"}]
      }
    }

    trace = EpisodeTrace.project(episode, [], [record])
    step = Enum.find(trace.steps, &String.starts_with?(&1.id, "record-"))
    assert step.band == :work
    assert step.title == "Question prepared"
    refute step.summary =~ "Reply below"
  end

  test "admission links resolve to the episode they actually joined" do
    {entry, episode} = admitted_input!()

    assert {:ok, %{episode_ref: ref}} =
             ModelRequests.project_input(entry.id, %{})

    assert ref == episode.key
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    assert Enum.all?(timeline.items, fn request ->
             request.source_kind != :admission ||
               (request.href =~ "/requests?" && request.href =~ "kind=admission" &&
                  request.href =~ entry.id)
           end)
  end

  test "a follow-up turn cannot erase an earlier delivered answer" do
    # An active follow-up used to replace a confirmed answer with 'No visible answer yet'.
    {_entry, episode} = admitted_input!()

    {:ok, _session} =
      Custody.pin_episode(episode.id, "trace-test", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("trace-test", 60, :work)

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [
        delivery_document: %{"delivery" => "reply", "message" => "The first confirmed answer"},
        delivery_ref: "reply:trace-test",
        delivery_fingerprint: String.duplicate("a", 64),
        external_receipt: %{"message_ref" => "1788562304.000100"},
        external_receipt_fingerprint: String.duplicate("b", 64),
        delivered_at: @received
      ]
    )

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      session_id: claim.session.id,
      turn_ref: "follow-up",
      status: :pending,
      inserted_at: DateTime.add(DateTime.utc_now(), 1)
    })

    assert {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.reply == "The first confirmed answer"
    assert detail.trace.case_file.reply_status == "Delivery confirmed"
    assert detail.trace.case_file.reply_request_id == claim.turn.id
  end

  test "editing or deleting an admitted message updates its case file without rewriting history" do
    {entry, episode} = admitted_input!()

    for {revision, kind, text} <- [{2, :edit, "Corrected request"}, {3, :delete, ""}] do
      {:ok, input} =
        Input.new(%{
          actor: %{kind: :user, ref: "U123"},
          channel_ref: "C456",
          content: %{"text" => text},
          event_kind: kind,
          event_ref: "Ev-revised-#{revision}",
          message_ref: "1788562304.000100",
          occurred_at: DateTime.add(@received, revision),
          revision: revision,
          thread_ref: nil,
          workspace_ref: "T123"
        })

      {:ok, _} = Inbox.record(input)
      {:ok, detail} = Projection.episode(episode.key)

      assert detail.trace.case_file.title ==
               if(kind == :delete, do: "Message deleted", else: text)

      assert length(detail.trace.case_file.messages) == 1
      assert Repo.get!(Entry, entry.id).content["text"] == "Hello"
    end
  end

  test "the episode leads with the actual conversation and safely escapes untrusted source text" do
    {entry, episode} = admitted_input!()
    text = "Investigate <script>steal()</script> token=ghp_abcdefghijklmnopqrstuvwxyz"

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [content: %{"text" => text}]
    )

    assert {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.title =~ "Investigate"
    refute detail.trace.case_file.title =~ "ghp_abcdefghijklmnopqrstuvwxyz"
    html = detail |> HTML.episode() |> IO.iodata_to_binary()
    assert html =~ "case-conversation"
    assert html =~ "Investigate &lt;script&gt;"
    assert html =~ "Identity and timestamps"
    assert html =~ "Inspect admission request"
    refute html =~ "<script>steal()"
    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz"
  end

  defp admitted_input! do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Hello"},
        event_kind: :message,
        event_ref: "Ev-trace-#{Ecto.UUID.generate()}",
        message_ref: "1788562304.000100",
        occurred_at: @received,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:U123",
          destination: %{
            conversation_ref: "slack:T123:C456",
            thread_ref: "1788562304.000100",
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @received,
          payload: Responder.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "A direct conversational reply.",
      "work_class" => "conversational"
    }

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        inserted_at: @received,
        status: :decided,
        updated_at: DateTime.add(@received, 57, :second)
      ]
    )

    Repo.update_all(from(saved in Episode, where: saved.id == ^episode.id),
      set: [
        inserted_at: DateTime.add(@received, 57, :second),
        updated_at: DateTime.add(@received, 139, :second)
      ]
    )

    {entry, episode}
  end
end
