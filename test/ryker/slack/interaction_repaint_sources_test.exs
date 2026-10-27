defmodule Ryker.Slack.InteractionRepaintSourcesTest do
  # The confirmed-post projection uses the workspace-scoped Slack name cache.
  use Ryker.DataCase, async: false
  alias Ryker.Behaviors.Behavior
  alias Ryker.{CanonicalJSON, Episodes, Repo}
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.Observations
  alias Ryker.Records
  alias Ryker.Slack.{InteractionAudit, InteractionAudits, InteractionRepaint}
  alias Ryker.Slack.{Monitoring, Renderer}
  alias Ryker.StateTools.FixedTools
  alias Ryker.Waits
  alias Ryker.Work.{Custody, Session, Turn}

  @captured Jason.decode!(File.read!("testdata/learning/recorded-private-source-citation.json"))

  defmodule API do
    def update_message(observer, channel, message, document, delivery) do
      assert_renderable(document)
      send(observer, {:updated, channel, message, document, delivery})
      :ok
    end

    defp assert_renderable(document) do
      {:ok, _} = Renderer.render(document)
    end
  end

  test "captured repaint fixtures isolate lock identities while preserving the original reply" do
    # These source-first fixtures otherwise deadlock conversation-first retention
    # and admission fixtures in concurrent sandbox transactions.
    raw =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    fixture = fixture!(:structured)
    source = fixture.source
    refute source.id == raw["id"]
    refute source.dedupe_key == raw["dedupe_key"]
    refute source.native_input_id == raw["native_input_id"]
    refute source.source_ref == raw["source_ref"]
    refute source.destination_conversation_ref == raw["destination_conversation_ref"]

    assert fixture.claim.episode.destination_conversation_ref ==
             source.destination_conversation_ref

    assert fixture.audit.workspace_ref == source.source_ref
    assert source.content == raw["content"]

    assert DateTime.to_naive(source.occurred_at) ==
             NaiveDateTime.from_iso8601!(raw["occurred_at"])

    assert fixture.record.payload["source_id"] == "observation:#{source.id}"
    assert fixture.record.payload["source_name"] == "observation:#{source.id}"
    assert fixture.record.payload["observation"] == @captured["arguments"]["observation"]
    assert fixture.turn.delivery_document["message"] == @captured["candidate"]["message"]
  end

  for shape <- [:simple, :structured] do
    test "repainting a withdrawn #{shape} reply replaces its old source text" do
      # Reuse the actual privacy-probe answer and citation, with an explicitly
      # structural delivered receipt. The live revoked answer was NOT sent.
      fixture = fixture!(unquote(shape))
      assert repaint(fixture.audit) == :ok
      assert_received {:updated, _, _, before, _}
      assert before["message"] == @captured["candidate"]["message"]

      KnowledgeFixtures.revoke!(fixture.source)
      assert repaint(fixture.audit) == :ok
      assert_received {:updated, _, _, after_withdrawal, _}
      assert_neutral(after_withdrawal)

      assert Repo.get!(Turn, fixture.turn.id).delivery_document == fixture.turn.delivery_document
    end
  end

  test "an untracked producer cannot republish an old reply" do
    fixture = fixture!(:simple)

    Session
    |> Repo.get!(fixture.claim.session.id)
    |> Ecto.Changeset.change(source_exposure_count: nil, knowledge_exposure_count: nil)
    |> Repo.update!()

    assert Repo.get!(Session, fixture.claim.session.id).source_exposure_count == nil

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert_neutral(document)
  end

  test "a crossed receipt cannot publish an episode reply to a different destination" do
    fixture = fixture!(:structured)

    fixture.claim.episode
    |> Ecto.Changeset.change(
      destination_conversation_ref: "slack:#{fixture.audit.workspace_ref}:COTHER"
    )
    |> Repo.update!()

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert_neutral(document)
  end

  test "a valid simple reply retains its exact content and delivery identity" do
    fixture = fixture!(:simple)
    assert repaint(fixture.audit) == :ok
    assert_received {:updated, "C0TENANTOPS", "1787832001.000200", document, delivery}
    assert document == %{"message" => @captured["candidate"]["message"]}
    assert delivery == fixture.turn.delivery_ref
  end

  test "a valid structured repaint keeps current record status without rewriting the reply" do
    fixture = fixture!(:structured)

    Repo.update!(
      Ecto.Changeset.change(fixture.record,
        status: :confirmed,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_actor_ref: "slack:user:fixture",
        confirmed_episode_id: fixture.claim.episode.id,
        confirmation_ref: "structural-repaint-status"
      )
    )

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert document["message"] == @captured["candidate"]["message"]
    assert [record] = document["records"]
    assert record["ref"] == fixture.record.ref
    assert record["status"] == "confirmed"
    assert record["payload"] == fixture.record.payload
  end

  test "a delivered post link does not withdraw its source-backed confirmation card" do
    # The fresh production confirmation posted successfully, then its link made the exact
    # source checker reject the host-enriched record and replace the entire reply (QA, 2026-10-11).
    captured = Jason.decode!(File.read!("testdata/slack/confirmed-post-repaint.json"))
    workspace = "T0TENANT001"
    fixture = fixture!(:structured, workspace)
    conversation = fixture.claim.episode.destination_conversation_ref
    [_slack, _workspace, channel] = String.split(conversation, ":")

    payload =
      captured["payload"]
      |> Map.put("conversation_ref", conversation)
      |> Map.put("destination_ref", "slack-source:v1:#{workspace}:#{channel}:channel")

    record =
      fixture.record
      |> Ecto.Changeset.change(
        kind: "slack_post_offer",
        payload: payload,
        payload_fingerprint: CanonicalJSON.digest(payload),
        status: :confirmed,
        confirmed_by_actor_ref: payload["requested_by_actor_ref"],
        confirmed_at: DateTime.utc_now(),
        confirmation_ref: "captured-confirmed-post"
      )
      |> Repo.update!()

    # Rebind opaque fixture custody only; keep the harvested decision and prose.
    candidate =
      captured["delivery_document"]
      |> put_in(["outcome", "record_refs"], [record.ref])
      |> Map.update!(
        "message",
        &String.replace(&1, captured["payload"]["conversation_ref"], conversation)
      )

    fixture.turn
    |> Ecto.Changeset.change(
      delivery_document: candidate,
      delivery_fingerprint: CanonicalJSON.digest(candidate)
    )
    |> Repo.update!()

    start_supervised!(
      {Ryker.Slack.Names,
       workspace: workspace,
       workspace_url: "https://tenant.slack.com",
       fetch: fn _ -> {:error, :unavailable} end}
    )

    message = "1791740759.096129"

    action =
      Repo.insert!(%PlatformAction{
        episode_id: fixture.claim.episode.id,
        turn_id: fixture.turn.id,
        action_ref: "platform-action:captured-confirmed-post",
        host_slot: Records.SlackPostOffers.host_slot(record),
        tool: :post_slack_message,
        kind: :message,
        transport: "slack",
        conversation_ref: payload["conversation_ref"],
        document: %{"message" => payload["message"]},
        intent_fingerprint: digest(),
        status: :delivered,
        delivered_at: DateTime.utc_now(),
        external_receipt: %{"message_ref" => message},
        external_receipt_fingerprint: digest()
      })

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert document["message"] == "Confirmed."
    assert [projected] = document["records"]

    assert projected["message_url"] ==
             "https://tenant.slack.com/archives/#{channel}/p1791740759096129"

    assert {:ok, rendered} = Renderer.render(document)
    assert inspect(rendered) =~ "Message posted"

    action
    |> Ecto.Changeset.change(
      status: :pending,
      delivered_at: nil,
      external_receipt: nil,
      external_receipt_fingerprint: nil
    )
    |> Repo.update!()

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, pending, _}
    assert pending["message"] == "Confirmed."
    refute hd(pending["records"])["message_url"]
    assert {:ok, waiting} = Renderer.render(pending)
    assert inspect(waiting) =~ "Message confirmed"
    refute inspect(waiting) =~ "Message posted"

    KnowledgeFixtures.revoke!(fixture.source)
    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, withdrawn, _}
    assert Map.keys(withdrawn) == ["message"]
    assert withdrawn["message"] =~ "source context"
    assert Repo.get!(Turn, fixture.turn.id).delivery_document == candidate
  end

  test "confirmation repaint removes obsolete proposal prose without rewriting the accepted answer" do
    # The real Terraform reply kept saying not yet active after its confirmation.
    # The historical answer stays immutable; only its live Slack projection changes.
    captured = Jason.decode!(File.read!("testdata/work/terraform-automation-recovery.json"))
    fixture = fixture!(:structured)
    record = fixture.record
    proposal = hd(captured["automation_arguments"]["proposals"])

    payload = %{
      "context_channel" => fixture.claim.episode.destination_conversation_ref,
      "delivery_channel" => fixture.claim.episode.destination_conversation_ref,
      "expires_at" => nil,
      "filter" => proposal["trigger"]["filter"],
      "hold" => nil,
      "repository" => nil,
      "source_kind" => proposal["trigger"]["source_kind"],
      "task" => proposal["prompt"],
      "title" => proposal["title"]
    }

    # Structural replay: retain the recorded model content, rebind only fixture custody.
    record =
      record
      |> Ecto.Changeset.change(
        kind: "standing_assignment_offer",
        payload: payload,
        payload_fingerprint: CanonicalJSON.digest(payload),
        status: :confirmed,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_actor_ref: "slack:user:fixture",
        confirmation_ref: "interaction:recorded-confirmation"
      )
      |> Repo.update!()

    # The confirmation created the standing rule this offer now renders as.
    behavior_id = Ecto.UUID.generate()

    Repo.insert!(%Behavior{
      id: behavior_id,
      ref: "behavior:#{behavior_id}",
      offer_record_id: record.id,
      kind: :standing_assignment,
      status: :active,
      workspace_ref: "slack:T0TENANT001",
      scope_kind: :conversation,
      scope_ref: fixture.claim.episode.destination_conversation_ref,
      identity_key: proposal["trigger"]["source_kind"],
      payload: payload,
      confirmed_by_actor_ref: "slack:user:fixture",
      confirmation_ref: "interaction:recorded-confirmation",
      confirmed_at: DateTime.utc_now(),
      source_transport: "slack",
      source_conversation_ref: fixture.claim.episode.destination_conversation_ref,
      source_thread_ref: fixture.claim.episode.destination_thread_ref,
      source_message_ref: "1787832001.000200",
      expires_at: nil
    })

    candidate = put_in(captured["accepted_candidate"], ["outcome", "record_refs"], [record.ref])

    turn =
      fixture.turn
      |> Ecto.Changeset.change(
        delivery_document: candidate,
        delivery_fingerprint: CanonicalJSON.digest(candidate)
      )
      |> Repo.update!()

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    # The reply said "Confirmation saved. The confirmed items are shown
    # below." (Slack as Andrew, 2026-10-09); the card below says what.
    assert document["message"] == "Saved."
    refute document["message"] =~ "not yet active"
    assert {:ok, rendered} = Renderer.render(document)
    assert inspect(rendered) =~ "Standing rule saved"
    assert inspect(rendered) =~ proposal["prompt"]
    assert inspect(rendered) =~ "ryker_delete_behavior"
    refute inspect(rendered) =~ "Enable automation"
    assert Repo.get!(Turn, turn.id).delivery_document == candidate
  end

  # The publisher adds the delivery's mention authority to a reply that names
  # someone, and until 2026-09-28 a repaint did not: once a person answered a
  # reply's question, every name in it turned back into its raw typed link.
  test "a repainted reply still names whom it named" do
    workspace = "T" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.upcase())
    fixture = fixture!(:simple, workspace)
    conversation = fixture.claim.episode.destination_conversation_ref
    [_slack, _workspace, channel] = String.split(conversation, ":")

    delivery = %{
      "message" => "The rollout notes are in [this channel](slack-channel:#{conversation})."
    }

    fixture.turn
    |> Ecto.Changeset.change(
      delivery_document: delivery,
      delivery_fingerprint: CanonicalJSON.digest(delivery)
    )
    |> Repo.update!()

    assert repaint(fixture.audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert {:ok, rendered} = Renderer.render(document)
    assert rendered["text"] == "The rollout notes are in <##{channel}>."
  end

  test "unsupported retained reply shapes still fail without publishing" do
    fixture = fixture!(:simple)

    fixture.turn
    |> Ecto.Changeset.change(delivery_document: %{"unsupported" => true})
    |> Repo.update!()

    assert repaint(fixture.audit) == {:error, :slack_interaction_repaint_document_invalid}
    refute_received {:updated, _, _, _, _}
  end

  test "an interaction in another thread cannot find the retained reply" do
    fixture = fixture!(:structured)
    assert repaint(%{fixture.audit | thread_ref: "another-thread"}) == :ok
    refute_received {:updated, _, _, _, _}
  end

  test "quiet follow-ups durably repaint the original reply and never rewrite its answer" do
    # The three real accepted results left this footer stale for hours. Rebind
    # only identities to this test's source-authorized delivered reply.
    fixture = fixture!(:structured, nil, true)
    captured = Jason.decode!(File.read!("testdata/slack/quiet-followups.json"))
    episode = Repo.get!(Episodes.Episode, fixture.claim.episode.id)
    wait = fixture.wait
    next_wait = fixture.next_wait

    events =
      Enum.map(captured["events"], fn event ->
        event
        |> Jason.encode!()
        |> String.replace(captured["wait_ref"], wait.ref)
        |> String.replace("record:event_wait:fourth", next_wait.ref)
        |> Jason.decode!()
      end)

    for {event, index} <- Enum.with_index(events, episode.next_sequence) do
      at = DateTime.from_iso8601(event["payload"]["occurred_at"]) |> elem(1)
      kind = if event["kind"] == "wait_resumed", do: :wait_resumed, else: :result_accepted

      %Episodes.Event{
        sequence: index,
        kind: kind,
        dedupe_key: "monitoring:#{index}",
        fingerprint: CanonicalJSON.digest(event),
        payload: event["payload"],
        occurred_at: at
      }
      |> Episodes.Event.Changeset.insert(episode.id)
      |> Repo.insert!()
    end

    Episodes.Episode
    |> Repo.get!(episode.id)
    |> Ecto.Changeset.change(
      state: :waiting_for_event,
      owner_kind: :event,
      owner_ref: next_wait.ref,
      active_input_refs: [],
      owner_deadline_at: DateTime.from_iso8601(next_wait.payload["deadline_at"]) |> elem(1),
      next_sequence: episode.next_sequence + length(events)
    )
    |> Repo.update!()

    assert {:ok, {:ok, subscription}} =
             Repo.transaction(fn ->
               Waits.EventSubscriptions.ensure_in_transaction(
                 Repo.get!(Episodes.Episode, episode.id)
               )
             end)

    assert {:ok, status} = Monitoring.snapshot(fixture.turn)
    assert status["checks"] == 3
    assert status["state"] == "waiting"
    assert status["last_check_at"] == "2026-10-26T18:46:19.501343Z"
    assert status["next_check_at"] == DateTime.to_iso8601(subscription.poll_after)

    # A failed owner is not a completed check and must not retain the previous
    # successful check's "No new reply needed" label.
    episode = Repo.get!(Episodes.Episode, episode.id)

    blocked_turn =
      fixture.turn
      |> Ecto.Changeset.change(status: :blocked, turn_ref: "turn:followup:3")
      |> Repo.update!()

    checking_episode =
      episode
      |> Ecto.Changeset.change(
        state: :working,
        owner_kind: :turn,
        owner_ref: "turn:followup:3",
        owner_deadline_at: nil,
        next_sequence: episode.next_sequence - 1
      )
      |> Repo.update!()

    assert {:ok, failed} = Monitoring.snapshot(fixture.turn)
    assert failed["checks"] == 2
    assert failed["state"] == "failed"
    assert failed["next_check_at"] == nil

    blocked_turn
    |> Ecto.Changeset.change(status: fixture.turn.status, turn_ref: fixture.turn.turn_ref)
    |> Repo.update!()

    checking_episode
    |> Ecto.Changeset.change(
      state: episode.state,
      owner_kind: episode.owner_kind,
      owner_ref: episode.owner_ref,
      owner_deadline_at: episode.owner_deadline_at,
      next_sequence: episode.next_sequence
    )
    |> Repo.update!()

    assert Monitoring.reconcile_episode(episode.id) == :ok
    assert Monitoring.reconcile_episode(episode.id) == :ok
    assert [audit] = Repo.all(InteractionAudit)
    assert audit.actor_ref == "system:monitoring"
    assert audit.action_id == "monitoring_status"
    assert audit.repaint_status == :pending
    assert audit.message_ref == fixture.audit.message_ref

    assert repaint(audit) == :ok
    assert_received {:updated, _, _, document, _}
    assert document["message"] == fixture.turn.delivery_document["message"]
    projected = Enum.find(document["records"], &(&1["kind"] == "event_wait"))
    assert projected["presentation"] == %{"monitoring" => status}
    assert Repo.get!(Turn, fixture.turn.id).delivery_document == fixture.turn.delivery_document

    # Old queue entries are only targets, never saved footer content. Even a
    # retry of the original event reloads the current cancelled state.
    episode = Repo.get!(Episodes.Episode, episode.id)

    episode
    |> Ecto.Changeset.change(
      state: :cancelled,
      owner_kind: nil,
      owner_ref: nil,
      owner_deadline_at: nil
    )
    |> Repo.update!()

    assert repaint(audit) == :ok
    assert_received {:updated, _, _, cancelled, _}
    latest = Enum.find(cancelled["records"], &(&1["kind"] == "event_wait"))
    assert latest["presentation"]["monitoring"]["state"] == "cancelled"
    assert latest["presentation"]["monitoring"]["next_check_at"] == nil
    assert Monitoring.reconcile_episode(episode.id) == :ok
    assert Repo.aggregate(InteractionAudit, :count) == 2
    # Returning to a previously shown state still needs a repaint: deduping
    # forever by content hash would leave a failed check visible after retry.
    Episodes.Episode
    |> Repo.get!(episode.id)
    |> Ecto.Changeset.change(
      state: :waiting_for_event,
      owner_kind: :event,
      owner_ref: next_wait.ref,
      owner_deadline_at: DateTime.from_iso8601(next_wait.payload["deadline_at"]) |> elem(1)
    )
    |> Repo.update!()

    assert Monitoring.reconcile_episode(episode.id) == :ok
    assert Repo.aggregate(InteractionAudit, :count) == 3
    assert {:ok, claim} = InteractionAudits.claim_next("monitoring-test", 30)
    assert claim.message_ref == fixture.audit.message_ref

    # A controller offline through the cancellation must still repair the
    # footer on restart, not abandon terminal requests after one day.
    Episodes.Episode
    |> Repo.get!(episode.id)
    |> Ecto.Changeset.change(
      state: :cancelled,
      owner_kind: nil,
      owner_ref: nil,
      owner_deadline_at: nil,
      updated_at: DateTime.add(Enum.min([Repo.now!(), DateTime.utc_now()], DateTime), -2, :day)
    )
    |> Repo.update!()

    assert DateTime.compare(
             Repo.get!(Episodes.Episode, episode.id).updated_at,
             DateTime.add(Repo.now!(), -1, :day)
           ) == :lt

    assert Monitoring.reconcile() == :ok
    assert Repo.aggregate(InteractionAudit, :count) == 4
    assert Enum.any?(Repo.all(Turn.Query.monitoring_replies(nil)), &(&1.id == fixture.turn.id))
  end

  defp repaint(audit), do: InteractionRepaint.repaint(audit, %{api: API, client: self()})

  defp assert_neutral(document) do
    refute document["message"] == @captured["candidate"]["message"]
    # The allocation the captured answer named. The 2026-10-01 substitution replaced it in the
    # fixture but not here, so this checked for an id the fixture no longer held until 2026-10-04.
    refute document["message"] =~ "7abc3462"
    assert Map.keys(document) == ["message"]
    assert document["message"] =~ "source context"
  end

  defp fixture!(shape, workspace \\ nil, monitoring? \\ false) do
    raw =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()
      |> LearningFixtures.isolate_retained_input(workspace)

    source = LearningFixtures.retained_input!(raw, %{policy: "fixture", policy_digest: digest()})

    assert Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end) ==
             {:ok, :ok}

    claim = claim!(source.destination_conversation_ref)

    document =
      source.id |> then(&Repo.get!(ConversationObservation, &1)) |> Observations.document()

    assert KnowledgeSnapshot.expose(claim, [document]) == :ok

    # Rebind the host-issued source identity, not the recorded model's evidence
    # or reply. Each concurrent replay owns a separate Slack lock namespace.
    arguments = Map.put(@captured["arguments"], "source_ref", "observation:#{source.id}")

    assert {:ok, %{"record_ref" => ref}} =
             FixedTools.call("cite_source", arguments, %{
               binding: Map.put(claim, :state_token, Records.token(claim.turn))
             })

    assert {:ok, [record]} = Records.fetch_for_episode(claim.episode.id, [ref])

    {wait, next_wait} =
      if monitoring? do
        payload = %{
          "kind" => "backup_progress",
          # The retained check times are evidence; this newly created wait is
          # test setup and must not expire as the wall clock passes the capture.
          "deadline_at" => Repo.now!() |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
          "event_matcher" => %{
            "type" => "after",
            "delay" => "30m",
            "on_timeout" => "Report what is known."
          },
          "verification" => "Check the replacement backup."
        }

        {:ok, first} =
          Records.create(Records.token(claim.turn), "original-wait", "event_wait", payload)

        {:ok, next} =
          Records.create(Records.token(claim.turn), "next-wait", "event_wait", payload)

        {first, next}
      else
        {nil, nil}
      end

    refs = if wait, do: [record.ref, wait.ref], else: [record.ref]
    candidate = put_in(@captured["candidate"], ["outcome", "record_refs"], refs)
    delivery = if shape == :simple, do: Map.take(candidate, ["message"]), else: candidate
    turn = delivered_turn!(claim.turn, candidate, delivery, source.destination_conversation_ref)

    turn =
      if wait do
        turn
        |> Ecto.Changeset.change(
          continuation: %{
            "kind" => "wait",
            "wait_kind" => "event",
            "wait_ref" => wait.ref,
            "deadline_at" => wait.payload["deadline_at"]
          }
        )
        |> Repo.update!()
      else
        turn
      end

    %{
      claim: claim,
      source: source,
      record: record,
      turn: turn,
      wait: wait,
      next_wait: next_wait,
      audit: %InteractionAudit{
        workspace_ref: source.source_ref,
        channel_ref: "C0TENANTOPS",
        thread_ref: "repaint-source",
        message_ref: "1787832001.000200"
      }
    }
  end

  defp delivered_turn!(turn, candidate, delivery, conversation) do
    turn
    |> Ecto.Changeset.change(
      status: :settled,
      candidate: Jason.encode!(candidate),
      candidate_sha256: CanonicalJSON.digest(candidate),
      candidate_attempt: 1,
      validation_intent: %{"verdict" => "accept"},
      validation_intent_fingerprint: digest(),
      validation_receipt: "captured-validation",
      continuation: %{"kind" => "complete"},
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil,
      result_ref: "captured-result:#{turn.id}",
      delivery_ref: "captured-delivery:#{turn.id}",
      delivery_document: delivery,
      delivery_fingerprint: CanonicalJSON.digest(delivery),
      external_receipt: %{
        "transport" => "slack",
        "conversation_ref" => conversation,
        "thread_ref" => "repaint-source",
        "message_ref" => "1787832001.000200"
      },
      external_receipt_fingerprint: digest(),
      delivered_at: DateTime.utc_now(),
      accepted_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp claim!(conversation) do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "repaint-source:#{id}",
                 native_input_id: "source:#{id}",
                 turn_ref: "turn:#{id}",
                 payload: %{"text" => "Continue the investigation."},
                 destination: %{
                   transport: "slack",
                   conversation_ref: conversation,
                   thread_ref: "repaint-source"
                 }
               })
             )

    assert {:ok, _} =
             WorkSessions.pin_episode(id, "fixture", digest(), repository_ref: "tenant-infra")

    assert {:ok, claim} = Custody.claim_next("worker:#{id}", 60, :work)
    claim
  end

  defp digest, do: String.duplicate("a", 64)
end
