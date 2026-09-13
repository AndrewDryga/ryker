defmodule Ryker.Slack.InteractionRepaintSourcesTest do
  use Ryker.DataCase, async: true

  alias Ryker.{CanonicalJSON, Episodes, Repo}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Slack.{InteractionAudit, InteractionRepaint, Renderer}

  alias Ryker.State.{
    Behavior,
    ConversationObservation,
    KnowledgeSnapshot,
    Observations,
    Records
  }

  alias Ryker.StateTools.FixedTools
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
      assert :ok = repaint(fixture.audit)
      assert_received {:updated, _, _, before, _}
      assert before["message"] == @captured["candidate"]["message"]

      KnowledgeFixtures.revoke!(fixture.source)
      assert :ok = repaint(fixture.audit)
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

    assert :ok = repaint(fixture.audit)
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

    assert :ok = repaint(fixture.audit)
    assert_received {:updated, _, _, document, _}
    assert_neutral(document)
  end

  test "a valid simple reply retains its exact content and delivery identity" do
    fixture = fixture!(:simple)
    assert :ok = repaint(fixture.audit)
    assert_received {:updated, "C08MMETA3U3", "1787832001.000200", document, delivery}
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

    assert :ok = repaint(fixture.audit)
    assert_received {:updated, _, _, document, _}
    assert document["message"] == @captured["candidate"]["message"]
    assert [record] = document["records"]
    assert record["ref"] == fixture.record.ref
    assert record["status"] == "confirmed"
    assert record["payload"] == fixture.record.payload
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
      workspace_ref: "slack:T08MMETA3U3",
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

    assert :ok = repaint(fixture.audit)
    assert_received {:updated, _, _, document, _}
    assert document["message"] =~ "Confirmation saved"
    refute document["message"] =~ "not yet active"
    assert {:ok, rendered} = Renderer.render(document)
    assert inspect(rendered) =~ "Standing rule saved"
    assert inspect(rendered) =~ proposal["prompt"]
    assert inspect(rendered) =~ "ryker_delete_behavior"
    refute inspect(rendered) =~ "Enable automation"
    assert Repo.get!(Turn, turn.id).delivery_document == candidate
  end

  test "unsupported retained reply shapes still fail without publishing" do
    fixture = fixture!(:simple)

    fixture.turn
    |> Ecto.Changeset.change(delivery_document: %{"unsupported" => true})
    |> Repo.update!()

    assert {:error, :slack_interaction_repaint_document_invalid} = repaint(fixture.audit)
    refute_received {:updated, _, _, _, _}
  end

  test "an interaction in another thread cannot find the retained reply" do
    fixture = fixture!(:structured)
    assert :ok = repaint(%{fixture.audit | thread_ref: "another-thread"})
    refute_received {:updated, _, _, _, _}
  end

  defp repaint(audit), do: InteractionRepaint.repaint(audit, %{api: API, client: self()})

  defp assert_neutral(document) do
    refute document["message"] == @captured["candidate"]["message"]
    refute document["message"] =~ "311e38f3"
    assert Map.keys(document) == ["message"]
    assert document["message"] =~ "source context"
  end

  defp fixture!(shape) do
    raw =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()
      |> LearningFixtures.isolate_retained_input()

    source = LearningFixtures.retained_input!(raw, %{policy: "fixture", policy_digest: digest()})

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)

    claim = claim!(source.destination_conversation_ref)

    document =
      source.id |> then(&Repo.get!(ConversationObservation, &1)) |> Observations.document()

    assert :ok = KnowledgeSnapshot.expose(claim, [document])

    # Rebind the host-issued source identity, not the recorded model's evidence
    # or reply. Each concurrent replay owns a separate Slack lock namespace.
    arguments = Map.put(@captured["arguments"], "source_ref", "observation:#{source.id}")

    assert {:ok, %{"record_ref" => ref}} =
             FixedTools.call("cite_source", arguments, %{
               binding: Map.put(claim, :state_token, Records.token(claim.turn))
             })

    assert {:ok, [record]} = Records.fetch_for_episode(claim.episode.id, [ref])
    candidate = put_in(@captured["candidate"], ["outcome", "record_refs"], [record.ref])
    delivery = if shape == :simple, do: Map.take(candidate, ["message"]), else: candidate
    turn = delivered_turn!(claim.turn, candidate, delivery, source.destination_conversation_ref)

    %{
      claim: claim,
      source: source,
      record: record,
      turn: turn,
      audit: %InteractionAudit{
        workspace_ref: source.source_ref,
        channel_ref: "C08MMETA3U3",
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

    assert {:ok, _} = Custody.pin_episode(id, "fixture", digest(), nil, "blitz-infra")
    assert {:ok, claim} = Custody.claim_next("worker:#{id}", 60, :work)
    claim
  end

  defp digest, do: String.duplicate("a", 64)
end
