defmodule Responder.State.ContinuityTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{HTML, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.{ChannelConfigurations, ChannelMembership}

  alias Responder.State.{
    Continuity,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    ConversationSummaryState
  }

  alias Responder.Work.{Custody, FinalPreflight, Result, Submission}

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "shadow work can publish derived summaries without creating a visible result" do
    # Observe-only work used to be unable to save its own conversation summary.
    joined!("T123", "CSHADOW")
    work = open_work!("shadow-memory", "slack:T123:CSHADOW", nil, "responder", "slack", :shadow)

    assert {:ok, _} =
             Continuity.stage(work.state_token, state("Observed a keep-service decision"))

    assert %{turn: %{delivery_document: nil}} = accept!(work)
    assert Repo.one!(ConversationSummary).state["situation"] == "Observed a keep-service decision"
    assert Repo.aggregate(Responder.Delivery.Reaction, :count) == 0
  end

  test "validated result acceptance atomically publishes the latest staged situation" do
    joined!("T123", "C111")
    work = open_work!("atomic", "slack:T123:C111", "1710000000.000001", "responder")
    state = state("Investigate delivery", ["deploy:receipt:1"])

    assert {:ok, first} = Continuity.stage(work.state_token, state)
    assert first.revision == 1
    assert {:ok, duplicate} = Continuity.stage(work.state_token, state)
    assert duplicate.revision == 1

    revised = %{state | "open_loops" => ["Verify production delivery"]}
    assert {:ok, staged} = Continuity.stage(work.state_token, revised)
    assert staged.revision == 2
    assert Repo.aggregate(ConversationSummary, :count) == 0

    accept!(work)

    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert %ConversationSummary{} = summary = Repo.one!(ConversationSummary)
    assert summary.state == revised
    assert summary.repository_ref == "responder"
    assert summary.visibility == :public
    assert summary.source_result_ref == "result:#{work.claim.turn.id}"

    # Hundreds of saved summaries were invisible on Memory, making replay look empty.
    html =
      Projection.memory()
      |> HTML.memory("test-secret")
      |> IO.iodata_to_binary()

    assert html =~ "Conversation summaries"
    assert html =~ "Verify production delivery"

    recalled = Continuity.model_context(work.claim.episode, "responder")
    assert recalled["current"]["state"] == revised
    assert recalled["current"]["source_ref"] == summary.ref
    assert Repo.get!(ConversationSummary, summary.id).recall_count == 1

    assert Continuity.search_context(
             work.claim.episode,
             "responder",
             "does-not-match",
             "current_channel",
             20
           ) == []

    assert Repo.get!(ConversationSummary, summary.id).recall_count == 1

    assert [match] =
             Continuity.search_context(
               work.claim.episode,
               "responder",
               "verify production delivery",
               "current_channel",
               20
             )

    assert match["kind"] == "continuity"
    assert Repo.get!(ConversationSummary, summary.id).recall_count == 2

    assert [_workspace_match] =
             Continuity.search_context(
               work.claim.episode,
               "responder",
               "verify production delivery",
               "workspace",
               20
             )

    replacement =
      open_work!("atomic-replacement", "slack:T123:C111", "1710000000.000001", "responder")

    assert {:ok, _draft} =
             Continuity.stage(replacement.state_token, state("Replacement situation"))

    accept!(replacement)

    assert Repo.aggregate(ConversationSummary, :count) == 1
    assert Repo.one!(ConversationSummary).state["situation"] == "Replacement situation"

    assert Continuity.stage(replacement.state_token, state("Too late")) ==
             {:error, :conversation_summary_unauthorized}
  end

  test "invalid and unaccepted drafts never become conversation memory" do
    work = open_work!("rejected", "slack:T123:C222", "1710000000.000002", nil)

    assert {:error, {:invalid_conversation_summary, :fields}} =
             Continuity.stage(work.state_token, %{"goal" => "too little"})

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Unaccepted"))
    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 1

    assert {:error, :conversation_summary_unauthorized} =
             Continuity.stage("state:#{Ecto.UUID.generate()}", state("Unknown"))

    assert Continuity.stage("state:not-a-uuid", state("Invalid token")) ==
             {:error, :conversation_summary_unauthorized}

    assert Continuity.stage("invalid", state("Invalid prefix")) ==
             {:error, :conversation_summary_unauthorized}
  end

  test "public continuity boundaries fail closed outside their custody transaction" do
    work = open_work!("transaction-fences", "slack:T123:C223", nil, nil)

    assert Continuity.model_context(:invalid, nil) == %{
             "current" => nil,
             "related" => [],
             "rollups" => []
           }

    assert Continuity.search_context(:invalid, nil, "query", "workspace", 20) == []

    assert Continuity.compact_in_transaction(60, 3_600) ==
             {:error, :conversation_summary_transaction_required}

    assert Continuity.compact_in_transaction(0, 3_600) ==
             {:error, :invalid_conversation_summary_retention}

    assert Continuity.delete_slack_channel_in_transaction("T123", "C223") ==
             {:error, :conversation_summary_transaction_required}

    assert Continuity.delete_slack_channel_in_transaction(nil, nil) ==
             {:error, :conversation_summary_destination}

    assert Continuity.candidate_staged_in_transaction(
             work.claim.turn,
             String.duplicate("a", 64),
             1
           ) == {:error, :conversation_summary_transaction_required}

    assert Continuity.accept_staged_in_transaction(%{}, %{}, %{}, nil) ==
             {:error, :conversation_summary_invalid_acceptance}

    invalid_destination = %{work.claim.episode | destination_transport: nil}
    assert Continuity.model_context(invalid_destination, nil)["current"] == nil
    assert Continuity.search_context(invalid_destination, nil, "query", "workspace", 20) == []

    malformed_slack = %{
      work.claim.episode
      | destination_conversation_ref: "slack:T123",
        destination_transport: "slack"
    }

    assert Continuity.model_context(malformed_slack, nil)["current"] == nil

    malformed_github = %{
      work.claim.episode
      | destination_conversation_ref: "github:",
        destination_transport: "github"
    }

    assert Continuity.model_context(malformed_github, nil)["current"] == nil
  end

  test "a universal transport retains exact-conversation continuity without gaining cross-channel scope" do
    work =
      open_work!(
        "universal",
        "webhook:configured-route:item-1",
        "occurrence-1",
        nil,
        "webhook"
      )

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Universal input"))
    accept!(work)

    assert %ConversationSummary{visibility: :conversation} = Repo.one!(ConversationSummary)
    context = Continuity.model_context(work.claim.episode, nil)
    assert context["current"]["state"]["situation"] == "Universal input"
    assert context["related"] == []

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 3_600) end)

    assert %ConversationRollup{scope_kind: :conversation, visibility: :conversation} =
             Repo.one!(ConversationRollup)

    assert [rollup] =
             Continuity.search_context(
               work.claim.episode,
               nil,
               "universal input",
               "current_channel",
               20
             )

    assert rollup["kind"] == "continuity"
  end

  test "Slack direct-message continuity never crosses into another direct message" do
    source = open_work!("direct-source", "slack:T123:D111", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Direct state"))
    accept!(source)

    assert Repo.one!(ConversationSummary).visibility == :direct

    same_direct = open_work!("direct-same", "slack:T123:D111", "reply", "responder")
    other_direct = open_work!("direct-other", "slack:T123:D222", nil, "responder")

    assert [related] = Continuity.model_context(same_direct.claim.episode, "responder")["related"]
    assert related["state"]["situation"] == "Direct state"
    assert Continuity.model_context(other_direct.claim.episode, "responder")["related"] == []
  end

  test "cross-channel recall prefers the same repository and never crosses private boundaries" do
    joined!("T123", "C222")
    joined!("T123", "C333")
    joined!("T123", "C111")
    joined!("T123", "G444", true)

    public_same =
      open_work!("public-same", "slack:T123:C222", "1710000000.000010", "responder")

    public_other =
      open_work!("public-other", "slack:T123:C333", "1710000000.000011", "other")

    private = open_work!("private", "slack:T123:G444", "1710000000.000012", "responder")

    Enum.each(
      [
        {public_same, state("Same repository")},
        {public_other, state("Other repository")},
        {private, state("Private detail")}
      ],
      fn {work, summary} ->
        assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
        accept!(work)
      end
    )

    current = open_work!("current", "slack:T123:C111", "1710000000.000013", "responder")
    context = Continuity.model_context(current.claim.episode, "responder")

    assert Enum.map(context["related"], & &1["state"]["situation"]) == [
             "Same repository",
             "Other repository"
           ]

    refute inspect(context) =~ "Private detail"

    Repo.update_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == "T123" and membership.channel_ref == "C222"
      ),
      set: [status: :left, left_at: @now]
    )

    after_leave = Continuity.model_context(current.claim.episode, "responder")
    assert Enum.map(after_leave["related"], & &1["state"]["situation"]) == ["Other repository"]

    private_context = Continuity.model_context(private.claim.episode, "responder")
    assert private_context["current"]["state"]["situation"] == "Private detail"
  end

  test "retention compaction creates a durable sourced rollup before deleting summaries" do
    joined!("T123", "C555")
    joined!("T123", "C777")
    work = open_work!("rollup", "slack:T123:C555", "1710000000.000020", "responder")
    summary_state = state("Old situation", ["source:one"])
    assert {:ok, _draft} = Continuity.stage(work.state_token, summary_state)
    accept!(work)

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 3_600) end)

    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert %ConversationRollup{} = rollup = Repo.one!(ConversationRollup)
    assert rollup.scope_kind == :repository
    assert rollup.scope_ref == "responder"
    assert rollup.source_count == 1
    assert length(rollup.source_refs) == 1
    assert rollup.state["situation"] == "Old situation"
    assert DateTime.diff(rollup.expires_at, DateTime.add(old, 3_600, :second), :second) == 0

    current = open_work!("rollup-current", "slack:T123:C777", "1710000000.000021", "responder")
    context = Continuity.model_context(current.claim.episode, "responder")
    assert [recalled] = context["rollups"]
    assert recalled["source_refs"] == rollup.source_refs
    assert recalled["state"]["evidence_refs"] == ["source:one"]

    Repo.update_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == "T123" and membership.channel_ref == "C555"
      ),
      set: [status: :left, left_at: @now]
    )

    assert Continuity.model_context(current.claim.episode, "responder")["rollups"] == []

    assert {:ok, _deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "C555",
                 event_ref: "event:delete-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "responder", repository_refs: ["responder"]}
             )

    assert Repo.aggregate(ConversationRollup, :count) == 0
  end

  test "compaction never extends source content beyond its configured horizon" do
    joined!("T123", "C556")
    work = open_work!("expired-rollup", "slack:T123:C556", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Expired source"))
    accept!(work)

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 60) end)

    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert Repo.aggregate(ConversationRollup, :count) == 0
  end

  test "later summaries merge into an existing rollup without losing source custody" do
    joined!("T123", "C557")

    first = open_work!("rollup-first", "slack:T123:C557", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(first.state_token, state("First", ["source:first"]))
    accept!(first)

    # Term-order sorting ranked microseconds before the actual clock time,
    # letting an older conversation replace the newest situation in a rollup.
    now = DateTime.utc_now()
    first_time = %{DateTime.add(now, -180, :second) | microsecond: {900_000, 6}}
    Repo.update_all(ConversationSummary, set: [inserted_at: first_time, updated_at: first_time])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 3_600) end)

    first_rollup = Repo.one!(ConversationRollup)

    second = open_work!("rollup-second", "slack:T123:C557", nil, "responder")

    assert {:ok, _draft} =
             Continuity.stage(second.state_token, state("Second", ["source:second"]))

    accept!(second)

    second_time = %{DateTime.add(now, -120, :second) | microsecond: {100_000, 6}}
    Repo.update_all(ConversationSummary, set: [inserted_at: second_time, updated_at: second_time])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 3_600) end)

    rollup = Repo.one!(ConversationRollup)
    assert rollup.id == first_rollup.id
    assert rollup.source_count == 2
    assert length(rollup.source_refs) == 2
    assert rollup.state["evidence_refs"] == ["source:second", "source:first"]
    assert DateTime.compare(rollup.period_end, second_time) == :eq

    current = open_work!("rollup-search", "slack:T123:C557", nil, "responder")

    assert [match] =
             Continuity.search_context(
               current.claim.episode,
               "responder",
               "source:first",
               "repository",
               20
             )

    assert match["source_count"] == 2

    assert Continuity.search_context(current.claim.episode, "responder", "source", "invalid", 20) ==
             []
  end

  test "private continuity crosses threads only inside the same authenticated channel" do
    joined!("T123", "G555", true)
    joined!("T123", "G666", true)

    source = open_work!("private-source", "slack:T123:G555", "1710000000.000030", "responder")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Private channel state"))
    accept!(source)

    same_channel =
      open_work!("private-same", "slack:T123:G555", "1710000000.000031", "responder")

    other_channel =
      open_work!("private-other", "slack:T123:G666", "1710000000.000032", "responder")

    assert [related] =
             Continuity.model_context(same_channel.claim.episode, "responder")["related"]

    assert related["state"]["situation"] == "Private channel state"
    assert Continuity.model_context(other_channel.claim.episode, "responder")["related"] == []
  end

  test "Slack Connect continuity stays inside the externally shared channel" do
    joined!("T123", "CEXT", false, true)
    joined!("T123", "CINT")

    source = open_work!("connect-source", "slack:T123:CEXT", "1710000000.000040", "responder")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Partner-only state"))
    accept!(source)

    assert Repo.one!(ConversationSummary).visibility == :private

    same_channel =
      open_work!("connect-same", "slack:T123:CEXT", "1710000000.000041", "responder")

    internal = open_work!("connect-internal", "slack:T123:CINT", nil, "responder")

    assert [related] =
             Continuity.model_context(same_channel.claim.episode, "responder")["related"]

    assert related["state"]["situation"] == "Partner-only state"
    assert Continuity.model_context(internal.claim.episode, "responder")["related"] == []
  end

  test "an unknown Slack channel fails closed and first-seen deletion removes its continuity" do
    work = open_work!("unknown-private", "slack:T123:CSECRET", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Unknown visibility"))
    accept!(work)

    assert Repo.one!(ConversationSummary).visibility == :conversation

    assert {:ok, deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "CSECRET",
                 event_ref: "event:delete-unknown-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "responder", repository_refs: ["responder"]}
             )

    assert deleted.membership.status == :deleted
    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "channel deletion removes staged continuity and fences every later write" do
    joined!("T123", "CDELETED")
    work = open_work!("deleted-channel", "slack:T123:CDELETED", nil, "responder")
    summary = state("Delete before acceptance")

    assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 1

    assert {:ok, deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "CDELETED",
                 event_ref: "event:delete-staged-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "responder", repository_refs: ["responder"]}
             )

    assert deleted.membership.status == :deleted
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert Continuity.stage(work.state_token, summary) == {:error, :slack_channel_deleted}

    accepted = accept!(work)
    assert accepted.turn.result_ref == "result:#{work.claim.turn.id}"
    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "a replaced candidate cannot publish an earlier attempt's summary" do
    joined!("T123", "C888")
    work = open_work!("candidate-fence", "slack:T123:C888", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("First attempt only"))

    claim = bind_work!(work)
    first = ~s({"delivery":"none","decision_reason":"first"})
    second = ~s({"delivery":"none","decision_reason":"second"})
    first_sha = digest(first)
    second_sha = digest(second)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               first,
               first_sha,
               1
             )

    bound_turn = Repo.get!(Responder.Work.Turn, claim.turn.id)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Continuity.candidate_staged_in_transaction(bound_turn, first_sha, 1)
             end)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               first_sha,
               1,
               second,
               second_sha,
               2
             )

    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert {:ok, result} = Result.new(:none, nil, "second")

    assert {:ok, _turn} =
             Custody.prepare_validation(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               second_sha,
               2,
               :accept,
               result
             )

    assert {:ok, _accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               second_sha,
               2,
               "validation-receipt:candidate-fence"
             )

    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "final preflight rejects a summary changed after validation" do
    joined!("T123", "C999")
    work = open_work!("preflight-fence", "slack:T123:C999", nil, "responder")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Before validation"))
    candidate_sha = String.duplicate("b", 64)

    ledger_sha =
      FinalPreflight.ledger_sha256(
        work.episode.id,
        work.episode.semantic_version,
        [],
        work.claim.turn.id
      )

    assert {:ok, _turn} =
             Custody.record_final_preflight(
               work.episode.id,
               work.claim.turn.turn_ref,
               work.claim.lease_ref,
               candidate_sha,
               ledger_sha,
               work.episode.semantic_version
             )

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("After validation"))

    assert Custody.verify_final_preflight(
             work.episode.id,
             work.claim.turn.turn_ref,
             work.claim.lease_ref,
             candidate_sha,
             []
           ) == {:error, :work_final_preflight_required}
  end

  test "compaction applies one deterministic byte budget across merged summaries" do
    joined!("T123", "C901")
    joined!("T123", "C902")

    for {channel, suffix} <- [{"C901", "one"}, {"C902", "two"}] do
      work = open_work!("large-#{suffix}", "slack:T123:#{channel}", nil, "responder")
      summary = %{state("Large #{suffix}") | "decisions" => large_values(suffix)}
      assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
      accept!(work)
    end

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 2}} =
             Repo.transaction(fn -> Continuity.compact_in_transaction(60, 3_600) end)

    rollup = Repo.one!(ConversationRollup)
    assert byte_size(CanonicalJSON.encode!(rollup.state)) <= 32 * 1_024
    assert {:ok, _state} = ConversationSummaryState.prepare(rollup.state)
  end

  defp open_work!(
         suffix,
         conversation_ref,
         thread_ref,
         repository_ref,
         transport \\ "slack",
         mode \\ :live
       ) do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:continuity:#{suffix}:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: thread_ref,
                   transport: transport
                 },
                 episode_id: episode_id,
                 execution_mode: mode,
                 episode_key: "continuity:#{suffix}:#{episode_id}",
                 native_input_id: "slack-message:continuity:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(
               episode_id,
               "responder-read",
               String.duplicate("a", 64),
               repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("worker:continuity:#{suffix}", 60, :work)

    %{
      claim: claim,
      episode: transition.episode,
      state_token: "state:#{claim.turn.id}",
      suffix: suffix
    }
  end

  defp accept!(work) do
    candidate = ~s({"delivery":"none","decision_reason":"continuity updated"})
    sha256 = digest(candidate)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => work.episode.id},
               "Update continuity.",
               %{"type" => "object"},
               "work-final-v1"
             )

    claim = work.claim

    assert {:ok, _turn} =
             Custody.freeze_submission(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:continuity:#{work.suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:continuity:#{work.suffix}"
             )

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:none, nil, "continuity updated")

    assert {:ok, _turn} =
             Custody.prepare_validation(
               work.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:continuity:#{work.suffix}"
             )

    accepted
  end

  defp bind_work!(work) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => work.episode.id},
               "Update continuity.",
               %{"type" => "object"},
               "work-final-v1"
             )

    claim = work.claim

    assert {:ok, _turn} =
             Custody.freeze_submission(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:continuity:#{work.suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:continuity:#{work.suffix}"
             )

    %{claim | session: session, turn: turn}
  end

  defp joined!(workspace_ref, channel_ref, private \\ false, external_shared \\ false) do
    now = @now

    Repo.insert!(%ChannelMembership{
      channel_ref: channel_ref,
      external_shared: external_shared,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: now,
      private: private,
      status: :joined,
      workspace_ref: workspace_ref
    })
  end

  defp state(situation, evidence_refs \\ []) do
    %{
      "active_topics" => ["Responder"],
      "decisions" => ["Keep continuity derived"],
      "evidence_refs" => evidence_refs,
      "goal" => "Ship the requested behavior",
      "open_loops" => [],
      "participants" => ["operator"],
      "purpose" => "Product development",
      "situation" => situation,
      "topology" => ["Responder uses PostgreSQL"],
      "unresolved_questions" => []
    }
  end

  defp large_values(prefix) do
    Enum.map(1..20, fn index -> "#{prefix}-#{index}-#{String.duplicate("x", 1_350)}" end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
