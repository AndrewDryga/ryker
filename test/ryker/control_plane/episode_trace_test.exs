defmodule Ryker.ControlPlane.EpisodeTraceTest do
  alias Ryker.ControlPlane.EpisodeTrace
  alias Ryker.ControlPlane.ModelRequests
  alias Ryker.ControlPlane.SlackNames
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{EpisodePage, SlackNames}
  alias Ryker.Work.Custody
  alias Ryker.Work.Turn

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.Projection
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input

  @received ~U[2026-09-04 22:51:44.000000Z]

  test "a task stopped before starting shows its request and remedy instead of an empty model briefing" do
    # Harvested from the second runner request, not the older Docker-blocked task.
    source = "testdata/work/hosted-runner-not-started.json" |> File.read!() |> Jason.decode!()
    {:ok, %{episode: parent}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Custody.pin_episode(parent.id, "trace-test", String.duplicate("a", 64))
    {:ok, parent_claim} = Custody.claim_next("trace-test", 60, :work)
    {:ok, _} = Episodes.apply(EpisodeFixtures.accept_result())
    {:ok, _} = Episodes.apply(EpisodeFixtures.confirm_delivery())
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: source["episode_ref"],
          native_input_id: id,
          turn_ref: id,
          linked_episode_id: parent.id
        })
      )

    {:ok, session} = Custody.pin_episode(episode.id, "trace-test", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("trace-test", 60, :work)
    payload = %{"title" => source["title"]}

    Repo.insert!(%Ryker.State.Record{
      id: Ecto.UUID.generate(),
      episode_id: parent.id,
      turn_id: parent_claim.turn.id,
      ref: String.replace_prefix(source["episode_ref"], "task-offer:", ""),
      operation_id: "propose-runner-upgrade",
      kind: "task_offer",
      status: :confirmed,
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      confirmed_episode_id: episode.id,
      confirmation_ref: "confirmation:runner-upgrade",
      confirmed_by_actor_ref: "slack:user:U1",
      confirmed_at: DateTime.from_iso8601(source["confirmed_at"]) |> elem(1),
      inserted_at: DateTime.from_iso8601(source["proposed_at"]) |> elem(1)
    })

    Repo.update_all(from(s in Ryker.Work.Session, where: s.id == ^session.id),
      set: [workspace_task: %{"title" => source["title"]}, repository_ref: "emisar"]
    )

    block_before_start!(claim.turn, session, source)

    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    html =
      render_component(&EpisodePage.render/1,
        snapshot: detail,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    document = LazyHTML.from_document(html)
    assert LazyHTML.text(LazyHTML.query(document, "h1")) == source["title"]

    assert LazyHTML.text(LazyHTML.query(document, ".episode-title-row .ui-status")) ==
             "Couldn’t start"

    assert html =~ "No files changed. No checks ran."
    assert html =~ "No task reply was sent."
    assert html =~ "View required setup"
    assert html =~ "What happened"
    assert html =~ "Your confirmation was received."
    history = LazyHTML.query(document, ".task-start-history") |> LazyHTML.text()
    assert history =~ "Task proposed"
    assert history =~ "Task approved"
    refute history =~ "Completed"
    assert Repo.get!(Episode, parent.id).state == :complete
    refute html =~ "Run again"
    refute html =~ "Model briefing"
    refute html =~ "Open recovery"
    refute html =~ "lacks Docker"
    assert LazyHTML.query(document, ".episode-metrics") |> Enum.empty?()
    assert LazyHTML.query(document, ".story-wait") |> Enum.empty?()
    assert timeline.items == []

    # A later configuration failure must not erase earlier work on this episode.
    Repo.update_all(from(s in Ryker.Work.Session, where: s.id == ^session.id),
      set: [coop_session_id: "previously-started-session"]
    )

    {:ok, with_session} = Projection.episode(episode.key)
    assert with_session.trace.startup == nil

    Repo.update_all(from(s in Ryker.Work.Session, where: s.id == ^session.id),
      set: [coop_session_id: nil]
    )

    # Real close changes the turn's status and error. It must not invent a model
    # briefing for this never-submitted attempt, nor show startup recovery again.
    assert {:ok, %{status: :settled}} =
             Custody.request_cancel(
               episode.id,
               episode.key,
               claim.turn.turn_ref,
               "close-runner-request",
               "No longer needed"
             )

    assert Repo.get!(Turn, claim.turn.id).status == :superseded
    {:ok, closed} = Projection.episode(episode.key)
    assert closed.trace.startup == nil
    assert closed.trace.stopped.headline == "Episode cancelled"
    refute Enum.any?(closed.trace.actions, &String.ends_with?(&1.href, "/retry"))
    {:ok, closed_timeline} = ModelRequests.timeline(episode.key, %{})
    assert closed_timeline.items == []

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    {:ok, pruned_timeline} = ModelRequests.timeline(episode.key, %{})
    assert pruned_timeline.items != []
  end

  test "retrying a task that never started does not invent a briefing for its old attempt" do
    # Retry replaces the stopped disposition, not the retained proof that no
    # model was called. The broken projection resurrected a phantom briefing.
    source = "testdata/work/hosted-runner-not-started.json" |> File.read!() |> Jason.decode!()
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, session} = Custody.pin_episode(episode.id, "trace-test", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("trace-test", 60, :work)
    turn = block_before_start!(claim.turn, session, source)

    assert {:ok, retried} = Custody.retry_blocked(episode.key, Custody.recovery_fingerprint(turn))
    assert retried.owner_ref != turn.turn_ref
    assert Repo.get!(Turn, turn.id).status == :superseded
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    refute Enum.any?(timeline.items, &(&1.id == "request-#{turn.id}"))
  end

  test "kernel-only delivery history does not infer a transport from the current destination" do
    # Historical kernel events retain the delivery identity, not an external
    # receipt. A Slack destination alone cannot distinguish delivery from replay.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Episodes.apply(EpisodeFixtures.accept_result())
    {:ok, _} = Episodes.apply(EpisodeFixtures.confirm_delivery())
    {:ok, detail} = Projection.episode(episode.key)
    receipt = Enum.find(detail.trace.steps, &(&1.state == "delivery confirmed"))
    assert receipt.summary == "Delivery was confirmed."
    refute receipt.summary =~ "Slack"
    refute receipt.summary =~ "bound transport"
  end

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

  test "preparation events do not acquire later admission and cleanup state" do
    # The replay showed admission 'decided' before routing and 'Settled' on turn preparation.
    {_entry, episode} = admitted_input!()
    {:ok, session} = Custody.pin_episode(episode.id, "trace-test", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("trace-test", 60, :work)
    {:ok, before} = Projection.episode(episode.key)

    Repo.update_all(from(s in Ryker.Work.Session, where: s.id == ^session.id),
      set: [cleanup_status: :blocked, retained_reason: "Later cleanup failure"]
    )

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [status: :blocked, lease_ref: nil, lease_owner: nil, lease_expires_at: nil]
    )

    {:ok, after_update} = Projection.episode(episode.key)

    earlier = fn trace ->
      Enum.filter(trace.steps, &(&1.band in [:input, :ready] and &1.stage != "Work setup"))
    end

    assert earlier.(before.trace) == earlier.(after_update.trace)
    input_step = Enum.find(before.trace.steps, &(&1.stage == "Input"))
    refute Enum.any?(input_step.details, &(&1.label in ["Admission", "Decision"]))

    # Work setup reports the turn's own preparation outcome, and only that:
    # a blocked turn is blocked, but the session's later cleanup failure
    # belongs to Maintenance and never reaches this card.
    setup = fn trace -> Enum.find(trace.steps, &(&1.stage == "Work setup")) end
    assert setup.(before.trace).setup.kind == :preparing
    assert setup.(after_update.trace).setup.kind == :blocked
    refute inspect(setup.(after_update.trace)) =~ "cleanup"
  end

  for error <- ~w(timer_deadline poll_after),
      {shape, deadline} <- [
        {"string", "password=retained-secret<script>"},
        {"object", %{"password" => "retained-secret"}}
      ] do
    test "the episode safely renders a #{error} warning with a malformed #{shape} deadline" do
      # The Lab fallback validated this field, but the timeline's direct warning
      # path leaked retained text and crashed the whole page on JSON objects.
      {_entry, episode} = admitted_input!()
      {:ok, detail} = Projection.episode(episode.key)

      record = %Ryker.State.Record{
        id: Ecto.UUID.generate(),
        ref: "record:event_wait:malformed-deadline",
        kind: "event_wait",
        status: :open,
        inserted_at: @received,
        wait_error: unquote(error),
        payload: %{"deadline_at" => unquote(Macro.escape(deadline))}
      }

      trace = EpisodeTrace.project(episode, [], [record])
      step = Enum.find(trace.steps, &(&1.record_ref == record.ref))
      assert step.current_warning == "Wait scheduling failed: its saved deadline is invalid."
      assert step.title == "Wait prepared"
      assert step.at == @received
      refute inspect(step) =~ "retained-secret"

      html =
        render_component(&EpisodePage.render/1,
          snapshot: %{detail | trace: trace},
          requests: nil,
          params: %{}
        )

      assert html =~ "Current scheduling status:"
      assert html =~ "saved deadline is invalid"
      assert html =~ "Wait prepared"
      refute html =~ "retained-secret"
      refute html =~ "<script>"
    end
  end

  test "expired request content names its expiry instead of looking like a deleted episode" do
    {entry, episode} = admitted_input!()

    Repo.update_all(from(i in Entry, where: i.id == ^entry.id),
      set: [content: %{"retention" => "pruned"}, operational_pruned_at: @received]
    )

    {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.expired_at == @received
  end

  test "accepting a reply records the decision without repeating the response body" do
    # The OOM reply appeared in candidate, acceptance and delivery cards.
    {_entry, episode} = admitted_input!()
    {:ok, _session} = Custody.pin_episode(episode.id, "trace-test", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("trace-test", 60, :work)
    document = %{"delivery" => "reply", "message" => "Unique reply body"}
    digest = CanonicalJSON.digest(document)

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [
        accepted_at: @received,
        candidate: Jason.encode!(document),
        candidate_sha256: digest,
        candidate_attempt: 1,
        validation_intent: %{},
        validation_intent_fingerprint: digest,
        validation_receipt: "receipt:trace",
        result_ref: "result:trace",
        continuation: %{},
        delivery_document: document,
        delivery_ref: "delivery:trace",
        delivery_fingerprint: digest
      ]
    )

    {:ok, detail} = Projection.episode(episode.key)
    accepted = Enum.find(detail.trace.steps, &(&1.id == "turn-#{claim.turn.id}-accepted"))
    refute accepted.summary =~ "Unique reply body"
    refute Enum.any?(accepted.details, &(&1.label == "Reply preview"))
  end

  test "an attachment-only source remains visible instead of looking erased" do
    # Blitz's Traefik alert retained its payload but rendered an empty heading and message.
    {entry, episode} = admitted_input!()

    Repo.update_all(from(i in Entry, where: i.id == ^entry.id),
      set: [
        content: %{
          "text" => "",
          "attachments" => [
            %{
              "title" => "[VA1 FIRING:1] WARNING | Traefik config reload frequency high",
              "text" =>
                "*FIRING - 1 alert*\n\n*Traefik completed more than 10 configuration reloads in 10 minutes*\nA normal app rollout should settle quickly. Sustained successful reloads can drive retained-memory growth even when every configuration applies successfully."
            }
          ]
        }
      ]
    )

    {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.title =~ "Traefik config reload frequency high"
    [message] = Enum.filter(detail.trace.case_file.conversation, &(&1.actor != "Ryker"))
    assert message.available
    assert message.text =~ "Traefik completed more than 10 configuration reloads in 10 minutes"
    assert is_nil(detail.trace.case_file.expired_at)
  end

  test "an input request addresses the episode it joined without a redirect" do
    {entry, episode} = admitted_input!()
    {:ok, detail} = Projection.episode("ingress-input:#{entry.id}")
    assert detail.episode.ref == episode.key
    assert {:ok, _} = ModelRequests.timeline("ingress-input:#{entry.id}", %{})
  end

  test "recorded BlockKit incident facts remain readable beside the answer" do
    # This real alert's 45,840 errors were hidden behind its attachment fallback.
    fixture =
      File.stream!("testdata/elixir-eval/work.jsonl")
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["eval_id"] == "automated_alert_controls_do_not_replace_the_incident"))

    content = fixture["context"]["inputs"]["items"] |> hd() |> get_in(["content", "content"])
    {entry, episode} = admitted_input!()
    Repo.update_all(from(i in Entry, where: i.id == ^entry.id), set: [content: content])
    {:ok, detail} = Projection.episode(episode.key)
    [message] = Enum.filter(detail.trace.case_file.conversation, &(&1.actor != "Ryker"))
    assert message.text =~ "45,840 errors over 2.0h"
    refute message.text =~ "[no preview available]"
  end

  test "the case file's title names who the message mentions, never a raw Slack id" do
    # The first Slack episode after the rename was headed "<@U0BL8MNPUSY> post-rename
    # check…" while the message under it read "@Emisar": the title took the
    # message text verbatim. The case message already knows its workspace;
    # the title resolves the same way the body does.
    start_supervised!(
      {SlackNames, workspace: "TC9F5B40D364C", fetch: fn _ref -> {:ok, "emisar"} end}
    )

    {entry, episode} = admitted_input!()
    SlackNames.name("TC9F5B40D364C", "U1")
    assert :ok = GenServer.call(SlackNames, :refresh)

    Repo.update_all(from(i in Entry, where: i.id == ^entry.id),
      set: [content: %{"text" => "<@U1> is checkout healthy?"}]
    )

    assert {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.title == "@emisar is checkout healthy?"
  end

  test "arbitrary source metadata cannot hide valid message text or crash its preview" do
    {entry, episode} = admitted_input!()

    for content <- [
          %{"text" => "Check health", "attachments" => "not Slack attachments", "blocks" => nil},
          %{"text" => "Check health", "payload" => %{"result" => "ready"}}
        ] do
      Repo.update_all(from(i in Entry, where: i.id == ^entry.id), set: [content: content])
      assert {:ok, detail} = Projection.episode(episode.key)
      assert detail.trace.case_file.title == "Check health"
    end
  end

  test "preparing an input question is work, not proof a question was sent" do
    # The real infrastructure trace jumped answer -> work -> answer before its first delivery.
    {_entry, episode} = admitted_input!()

    record = %Ryker.State.Record{
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
               (request.href =~ "/model-calls?" && request.href =~ "kind=admission" &&
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
    assert detail.trace.case_file.reply_status == "Response sent"
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
          workspace_ref: "TC9F5B40D364C"
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
    html = render_component(&EpisodePage.render/1, snapshot: detail, requests: nil, params: %{})
    assert html =~ "execution-timeline"
    assert html =~ "Investigate &lt;script&gt;"
    assert html =~ "Model calls"
    assert html =~ "Technical details"
    assert html =~ "Created"
    assert html =~ URI.encode_www_form(episode.key)
    refute html =~ "<script>steal()"
    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz"
  end

  test "operator correction notes remain visible without becoming executable markup" do
    # Historical audit corrections must be discoverable without rewriting accepted model records.
    {_entry, episode} = admitted_input!()
    {:ok, detail} = Projection.episode(episode.key)

    detail =
      put_in(
        detail,
        [:trace, :review, :note],
        "Correction: backup citation retained. <script>bad()</script>"
      )

    html = render_component(&EpisodePage.render/1, snapshot: detail, requests: nil, params: %{})
    assert html =~ "Correction: backup citation retained."
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>bad()"
  end

  defp block_before_start!(turn, session, source) do
    # Only rebind the harvested receipt's host identity to this test's session.
    # The absent-session outcome and original configuration failure stay intact.
    receipt =
      Map.put(
        source["cancellation_receipt"],
        "create_operation_ref",
        "ryker:work:create:#{session.id}:g#{session.create_generation}"
      )

    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [
        status: :blocked,
        last_error_code: source["last_error_code"],
        last_error_detail: source["last_error_detail"],
        cancellation_intent: source["cancellation_intent"],
        cancellation_intent_fingerprint: CanonicalJSON.digest(source["cancellation_intent"]),
        cancellation_receipt: receipt,
        cancellation_receipt_fingerprint: CanonicalJSON.digest(receipt),
        cancelled_at: DateTime.utc_now(),
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    Repo.get!(Turn, turn.id)
  end

  test "the trace says where cross-conversation evidence came from and how membership was corrected" do
    # A merged episode used to look like it had simply lost its messages, and
    # an episode gathering evidence from three channels looked like one thread.
    # An operator has to be able to read both from the trace itself.
    {_entry, episode} = admitted_input!()

    Repo.insert!(%Ryker.Episodes.Origin{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      input_ref: "admit_input:joined",
      sequence: 2,
      native_input_id: "slack-message:joined",
      revision: 1,
      source_kind: "slack",
      source_ref: "TC9F5B40D364C",
      source_item_ref: "1788562400.000100",
      actor_ref: "slack:user:U999",
      transport: "slack",
      conversation_ref: "slack:TC9F5B40D364C:CENGINEERING",
      thread_ref: "1788562400.000100",
      origin_kind: :channel_root,
      root_ref: "1788562400.000100",
      occurred_at: @received,
      effective: true
    })

    correction =
      Repo.insert!(%Ryker.Episodes.AssociationCorrection{
        actor_ref: "slack:user:UOPERATOR",
        applied_at: @received,
        confirmation_ref: "operator-confirmation:trace",
        input_refs: ["admit_input:joined"],
        kind: :reassign,
        reason: "The database question belongs to the outage, not the release.",
        source_episode_id: Ecto.UUID.generate(),
        target_episode_id: episode.id
      })

    trace = EpisodeTrace.project(episode, [], [])

    gathered = Enum.find(trace.steps, &(&1.id == "origins-#{episode.id}"))
    assert gathered.title == "Evidence joined from 2 conversations"
    assert inspect(gathered.details) =~ "CENGINEERING"
    assert inspect(gathered.details) =~ "slack:TC9F5B40D364C:C456"

    moved = Enum.find(trace.steps, &(&1.id == "association-#{correction.id}"))
    assert moved.title == "Messages moved into this episode by an audited correction"
    assert moved.summary == correction.reason
    assert inspect(moved.details) =~ "operator-confirmation:trace"
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
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:U123",
          destination: %{
            conversation_ref: "slack:TC9F5B40D364C:C456",
            thread_ref: "1788562304.000100",
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @received,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
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
