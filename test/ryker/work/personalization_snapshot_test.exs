defmodule Ryker.Work.PersonalizationSnapshotTest do
  use Ryker.DataCase, async: false
  alias Ryker.Behaviors
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Personalization
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.People
  alias Ryker.Records
  alias Ryker.Records.DerivedContext
  alias Ryker.Slack
  alias Ryker.Work.Custody
  alias Ryker.Work.Session

  # A current lookup can forget personal context while a saved briefing or
  # reused native transcript still sends it. Use harvested correction bytes
  # as opaque profile text: these host fences do not depend on its meaning.
  test "forgotten personal facts invalidate an unsent saved briefing" do
    {claim, fact} = Personalization.personal_context!()
    expected_digest = CanonicalJSON.digest(fact.fact)
    assert People.forget_fact(fact.id, expected_digest) == {:ok, 1}
    assert People.about(fact.person_ref, claim.episode.destination_conversation_ref) == []

    assert KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ) ==
             {:error, :work_knowledge_context_stale}
  end

  test "forgotten personal facts invalidate the native transcript that read them" do
    {claim, fact} = Personalization.personal_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    expected_digest = CanonicalJSON.digest(fact.fact)
    assert People.forget_fact(fact.id, expected_digest) == {:ok, 1}

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  test "stopped response preferences invalidate an unsent saved briefing" do
    {claim, preference} = Personalization.preference_context!()
    assert {:ok, _} = Behaviors.set_status(preference.ref, :disabled)
    assert Behaviors.model_context(claim.episode, nil, nil)["preferences"] == %{}

    assert KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ) ==
             {:error, :work_knowledge_context_stale}
  end

  test "stopped response preferences invalidate the native transcript that read them" do
    {claim, preference} = Personalization.preference_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    assert {:ok, _} = Behaviors.set_status(preference.ref, :disabled)

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  test "current personal facts and preferences remain authorized" do
    for {claim, _source} <- [
          Personalization.personal_context!(),
          Personalization.preference_context!()
        ] do
      assert KnowledgeSnapshot.authorize_submission(
               claim.episode,
               claim.session,
               claim.turn.submission
             ) == :ok

      assert KnowledgeSnapshot.expose_submission(claim) == :ok
      assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
    end
  end

  for change <- [:deleted, :expired, :changed] do
    test "#{change} response preferences invalidate saved and native context" do
      {claim, preference} = Personalization.preference_context!()
      assert KnowledgeSnapshot.expose_submission(claim) == :ok
      change_preference!(preference, unquote(change))
      assert_stale(claim)
    end
  end

  test "a replaced personal fact invalidates the earlier native transcript" do
    {claim, fact} = Personalization.personal_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok

    fact
    |> Ecto.Changeset.change(private: true, conversation_ref: "chat:another-place")
    |> Repo.update!()

    assert_stale(claim)
  end

  test "a new fact does not invalidate a transcript's unchanged existing facts" do
    {claim, fact} = Personalization.personal_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok

    fact
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id])
    |> Map.put(:key, "another-kind")
    |> then(&struct!(People.PersonFact, &1))
    |> Repo.insert!()

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
  end

  test "personalization custody contains identifiers and digests without personal text" do
    {claim, fact} = Personalization.personal_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    ledger = Repo.get!(Session, claim.session.id).personalization_exposures
    assert Map.keys(ledger["facts"]) == [fact.id]
    assert Ryker.Crypto.sha256_hex?(ledger["facts"][fact.id])
    refute Jason.encode!(ledger) =~ fact.fact
    refute Jason.encode!(ledger) =~ fact.person_ref
  end

  test "unproven older native custody never becomes an empty personal history" do
    {claim, _fact} = Personalization.personal_context!()

    claim.session
    |> Ecto.Changeset.change(
      personalization_exposures: nil,
      coop_session_id: "old-profile:#{claim.session.id}"
    )
    |> Repo.update!()

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}

    assert KnowledgeSnapshot.expose(claim, []) == {:error, :work_knowledge_context_stale}
  end

  test "changed personal context cannot borrow a valid source's identity" do
    {claim, fact} = Personalization.personal_context!()

    submission =
      put_in(
        claim.turn.submission,
        ["context", "operator_context", "person_asking", "use"],
        fact.fact
      )

    assert KnowledgeSnapshot.authorize_submission(claim.episode, claim.session, submission) ==
             {:error, :work_knowledge_context_stale}

    {claim, _preference} = Personalization.preference_context!()

    submission =
      put_in(
        claim.turn.submission,
        ["context", "operator_context", "preferences", "response_detail", "value"],
        "brief"
      )

    assert KnowledgeSnapshot.authorize_submission(claim.episode, claim.session, submission) ==
             {:error, :work_knowledge_context_stale}
  end

  test "public facts stay in their source workspace" do
    {claim, fact} = Personalization.personal_context!()

    assert People.about(fact.person_ref, claim.episode.destination_conversation_ref) == [
             fact.fact
           ]

    assert People.about(fact.person_ref, "slack:TANOTHER:C1") == []
  end

  test "a source made private stops sharing its personal facts with other channels" do
    {claim, fact} = Personalization.personal_context!()

    {:ok, workspace, _channel} =
      Ryker.ConversationRef.parse_slack(claim.episode.destination_conversation_ref)

    destination = "slack:#{workspace}:C2"
    assert People.about(fact.person_ref, destination) == [fact.fact]

    workspace
    |> Slack.ChannelMembership.Query.by_channel("C1")
    |> Repo.fetch!()
    |> Ecto.Changeset.change(private: true)
    |> Repo.update!()

    assert People.about(fact.person_ref, destination) == []

    assert People.about(fact.person_ref, claim.episode.destination_conversation_ref) == [
             fact.fact
           ]
  end

  for {fixture, source} <- [personal_context!: :facts, preference_context!: :preferences] do
    test "inherited records retain the withdrawal fence for #{source}" do
      {claim, saved} = apply(Personalization, unquote(fixture), [])
      assert KnowledgeSnapshot.expose_submission(claim) == :ok

      payload = %{
        "expires_in" => "90d",
        "key" => "response_detail",
        "repository" => nil,
        "scope" => "conversation",
        "value" => "detailed"
      }

      assert {:ok, record} =
               Records.create(
                 Records.token(claim.turn),
                 "personal-history",
                 "preference_offer",
                 payload
               )

      document = record |> Records.Record.document() |> DerivedContext.record()

      assert {:ok, _session} =
               Custody.bind_session(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 claim.session.generation,
                 claim.session.create_generation,
                 "personal-history:#{claim.session.id}"
               )

      receiver = next_turn!(claim)
      refute receiver.session.id == claim.session.id
      assert KnowledgeSnapshot.expose(receiver, [document]) == :ok
      withdraw!(unquote(source), saved)

      assert KnowledgeSnapshot.authorize_session(receiver.episode, receiver.session) ==
               {:error, :work_knowledge_context_stale}

      ledger = Repo.get!(Session, receiver.session.id).personalization_exposures
      assert map_size(ledger[Atom.to_string(unquote(source))]) == 1
      assert Repo.get!(Records.Record, record.id).payload == record.payload
    end
  end

  defp withdraw!(:facts, source) do
    expected_digest = CanonicalJSON.digest(source.fact)
    People.forget_fact(source.id, expected_digest)
  end

  defp withdraw!(:preferences, source), do: Behaviors.set_status(source.ref, :deleted)

  test "a changed asker cannot reuse the earlier person's personal context" do
    {claim, _source} = Personalization.personal_context!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    later = next_turn!(claim, "slack:user:UANOTHER")

    assert KnowledgeSnapshot.authorize_session(later.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  test "a confirmed workspace preference survives its source channel while its destination stays live" do
    {claim, preference} = Personalization.preference_context!()

    {:ok, workspace, _channel} =
      Ryker.ConversationRef.parse_slack(claim.episode.destination_conversation_ref)

    source = Ryker.ConversationRef.slack(workspace, "C2")

    Repo.insert!(%Slack.ChannelMembership{
      workspace_ref: workspace,
      channel_ref: "C2",
      status: :deleted,
      generation: 1,
      private: false,
      external_shared: false,
      deleted_at: Repo.now!()
    })

    preference
    |> Ecto.Changeset.change(
      scope_kind: :workspace,
      scope_ref: preference.workspace_ref,
      source_conversation_ref: source
    )
    |> Repo.update!()

    submission =
      put_in(
        claim.turn.submission,
        ["context", "operator_context", "preferences", "response_detail", "scope"],
        "workspace"
      )

    claim = %{claim | turn: %{claim.turn | submission: submission}}
    assert KnowledgeSnapshot.authorize_submission(claim.episode, claim.session, submission) == :ok
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
  end

  defp next_turn!(claim, actor \\ nil) do
    actor = actor || claim.episode |> Episodes.Event.Query.select_asking_actor() |> Repo.one()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 episode_key: claim.episode.key,
                 expected_turn_ref: claim.episode.owner_ref,
                 delivery: :none,
                 delivery_ref: nil,
                 decision_reason: "Saved context.",
                 occurred_at: Repo.now!(),
                 result_ref: "personal-result:#{claim.turn.id}"
               })
             )

    payload =
      "testdata/learning/retained-rollout-correction.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["notification", "content"])

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: actor,
                 destination: %{
                   transport: claim.episode.destination_transport,
                   conversation_ref: claim.episode.destination_conversation_ref,
                   thread_ref: claim.episode.destination_thread_ref
                 },
                 episode_id: claim.episode.id,
                 episode_key: claim.episode.key,
                 native_input_id: "personal-followup:#{claim.turn.id}",
                 occurred_at: Repo.now!(),
                 payload: payload,
                 turn_ref: "personal-followup:#{claim.turn.id}"
               })
             )

    assert {:ok, later} = Custody.claim_next("personal-followup:#{claim.turn.id}", 60, :work)
    assert later.episode.id == claim.episode.id
    refute later.turn.id == claim.turn.id
    later
  end

  defp assert_stale(claim) do
    assert KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ) == {:error, :work_knowledge_context_stale}

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  defp change_preference!(preference, :deleted),
    do: Behaviors.set_status(preference.ref, :deleted)

  defp change_preference!(preference, :expired) do
    confirmed = DateTime.add(Repo.now!(), -120, :second)
    expires = DateTime.add(Repo.now!(), -1, :second)

    preference
    |> Ecto.Changeset.change(
      confirmed_at: confirmed,
      expires_at: expires
    )
    |> Repo.update!()
  end

  defp change_preference!(preference, :changed) do
    payload = Map.put(preference.payload, "value", "brief")
    revision = preference.revision + 1

    preference
    |> Ecto.Changeset.change(
      payload: payload,
      revision: revision
    )
    |> Repo.update!()
  end
end
