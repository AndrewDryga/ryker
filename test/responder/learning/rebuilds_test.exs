defmodule Responder.Learning.RebuildsTest do
  use Responder.DataCase, async: false
  alias Responder.CanonicalJSON
  alias Responder.Fixtures.DatabaseClock
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Fixtures.Learning, as: Fixtures

  alias Responder.Learning.{
    Batch,
    Batches,
    Dispatcher,
    FleetSession,
    InputMembership,
    Operator,
    Rebuilds
  }

  alias Responder.Operator.Actions

  alias Responder.State.{
    ConversationKnowledge,
    KnowledgeRevision,
    Learning,
    LearningRun,
    LearningSources
  }

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  setup do
    previous = Application.get_env(:responder, :learning)

    Application.put_env(:responder, :learning, %{
      api: __MODULE__,
      client: %{},
      worker_ref: "rebuild-test",
      policy: @settings.policy,
      policy_digest: @settings.policy_digest
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :learning, previous),
        else: Application.delete_env(:responder, :learning)
    end)

    :ok
  end

  test "immediate rebuild fixtures stay eligible when the database clock trails the host" do
    # Nine unrelated gate failures came from receipt timestamps lying ahead of
    # PostgreSQL's queue clock, not from the rebuild contract being exercised.
    DatabaseClock.behind_host!()
    {_topic, _old, current} = unavailable_topic!()
    next = additional_input!(current)

    assert {:ok, %{batch: %Batch{}, inputs: [input]}} =
             Batches.claim("clock-aligned-fixture", @settings)

    assert input.id == next.id
  end

  test "explicit rebuilding can select a new original after every old support was withdrawn" do
    assert {:ok, _} =
             Responder.Instructions.save(
               :global,
               "Keep original attribution.",
               0,
               "operator:test"
             )

    {topic, old, current} = unavailable_topic!()
    before_history = Repo.all(KnowledgeRevision)
    memberships = Repo.all(InputMembership)

    assert {:ok, preview} = Rebuilds.preview(topic.id, %{page: 1, q: ""})
    assert preview.available? == false
    assert preview.eligible?
    assert Enum.map(preview.entries, & &1.input_id) == [current.id]
    refute Enum.any?(preview.entries, &(&1.input_id == old.id))

    assert {:ok, receipt} = rebuild(topic, current, "rebuild:first")
    assert {:ok, repeated} = rebuild(topic, current, "rebuild:second-click")
    assert receipt.outcome["batch_id"] == repeated.outcome["batch_id"]
    assert Repo.all(KnowledgeRevision) == before_history
    assert Repo.all(InputMembership) == memberships

    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    prompt = Jason.decode!(run.prompt)
    assert prompt["custom_instructions"]["global"]["text"] == "Keep original attribution."
    assert prompt["knowledge"] == []
    assert Enum.map(prompt["inputs"], & &1["content"]) == [current.content]
    refute run.prompt =~ topic.state["summary"]
    refute run.prompt =~ topic.topic_key
    assert prompt["rebuild_target"]["topic_id"] == topic.id
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    # Deliberately different proposed key: an operator authorizes the identity
    # association; this structural host-contract response cannot rename it.
    assert {:ok, _} = Fixtures.accept(run.id, result(current), %{})
    after_rebuild = Repo.get!(ConversationKnowledge, topic.id)
    assert after_rebuild.topic_key == topic.topic_key
    assert after_rebuild.version == topic.version + 1
    assert after_rebuild.source_generation == topic.source_generation + 1
    assert Repo.aggregate(ConversationKnowledge, :count) == 1
    assert Repo.aggregate(KnowledgeRevision, :count) == 2

    assert Enum.map(
             LearningSources.expand(after_rebuild.source_dependencies),
             & &1["source_input_id"]
           ) == [current.id]
  end

  test "source reselection grants one start on the same batch and never reuses an applied no-change attempt" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, receipt} = rebuild(topic, current, "rebuild:empty")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, first} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, first.id)
    empty = Jason.encode!(%{"updates" => [], "reason" => "Insufficient evidence to rebuild."})
    assert {:ok, _} = Fixtures.accept(first.id, empty, %{})
    assert {:ok, _} = stop(first, claim)
    assert {:ok, _} = Batches.finish(claim, :no_change)
    assert Repo.get!(ConversationKnowledge, topic.id) == topic

    assert {:ok, selection} =
             Operator.reselect(
               receipt.outcome["batch_id"],
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:reselect"
             )

    assert selection.outcome["start_count"] == 1
    assert selection.outcome["start_limit"] == 2
    assert selection.outcome["budget_version"] == 1
    assert {:ok, again} = Batches.claim("rebuild-test", @settings)
    assert Batches.latest(again.batch.id) == nil
    assert {:ok, next} = Batches.prepare(again)
    refute next.id == first.id
    refute next.batch_key == first.batch_key
    assert {:ok, _} = Batches.begin_execution(again, next.id)
    assert Repo.get!(Batch, again.batch.id).start_count == 2

    assert {:error, :learning_retry_conflict} =
             Operator.reselect(
               again.batch.id,
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:old-selection"
             )
  end

  @tag :policy_recovery
  test "reselecting a rebuild adopts the current policy but preserves its previous execution and spent start" do
    # Rebuild recovery must not remain pinned to an account whose quota is exhausted.
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, _} = rebuild(topic, current, "rebuild:old-policy")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, first} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, first.id)

    captured =
      "testdata/learning/recorded-no-change-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, _} =
             Fixtures.accept(
               first.id,
               captured["result"],
               %{}
             )

    assert {:ok, _} = stop(first, claim)
    assert {:ok, _} = Batches.finish(claim, :no_change)
    previous = Repo.get!(LearningRun, first.id)

    configuration = Application.fetch_env!(:responder, :learning)

    configuration = %{
      configuration
      | policy: "available-account",
        policy_digest: String.duplicate("b", 64)
    }

    Application.put_env(:responder, :learning, configuration)

    assert {:ok, receipt} =
             Operator.reselect(
               claim.batch.id,
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:new-policy"
             )

    changed = Repo.get!(Batch, claim.batch.id)
    assert changed.policy == configuration.policy
    assert changed.policy_digest == configuration.policy_digest
    assert {changed.start_count, changed.start_limit, changed.budget_version} == {1, 2, 1}
    assert receipt.outcome["policy"] == configuration.policy
    assert {:ok, audit} = Actions.fetch("rebuild:new-policy")
    assert audit.previous["policy"] == @settings.policy
    assert Repo.get!(LearningRun, first.id) == previous
    assert Batches.latest(claim.batch.id) == nil
    assert {:ok, again} = Batches.claim("rebuild-test", @settings)
    assert {:ok, next} = Batches.prepare(again)
    assert next.policy == configuration.policy
    assert {:ok, _} = Batches.begin_execution(again, next.id)
    assert Repo.get!(Batch, claim.batch.id).start_count == 2
  end

  test "an unresolved old remote blocks reselection before any new budget or source association" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, _} = rebuild(topic, current, "rebuild:unresolved")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, _} = Batches.release(claim, :learning_remote_unresolved, 0)
    before = Repo.get!(Batch, claim.batch.id)

    assert {:error, :learning_remote_outstanding} =
             Operator.reselect(
               before.id,
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:unsafe"
             )

    assert Repo.get!(Batch, before.id) == before
  end

  test "a rebuild version conflict does not pause unrelated ordinary learning in its conversation" do
    # A zero-start CAS conflict used the execution-failure cooldown, silencing
    # passive learning in the entire conversation for an hour.
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, _} = rebuild(topic, current, "rebuild:conflict-cooldown")
    Repo.update!(Ecto.Changeset.change(topic, version: topic.version + 1))

    assert {:ok, %{status: :deferred, start_count: 0} = failed} =
             Dispatcher.run_once(Map.put(@settings, :worker_ref, "rebuild-test"))

    assert failed.error_code == "knowledge_rebuild_conflict"
    next = additional_input!(current)
    assert next.destination_conversation_ref == current.destination_conversation_ref

    assert {:ok, %{batch: %Batch{}, inputs: [_]} = claim} =
             Batches.claim("ordinary-after-conflict", @settings)

    assert claim.batch.rebuild_target_id == nil
    assert Enum.map(claim.inputs, & &1.id) == [next.id]
    assert Repo.get!(Batch, failed.id).start_count == 0
  end

  test "reselecting originals retains static contract feedback without copying the old prompt" do
    {topic, current, claim, first} = failed_rebuild!()

    assert {:ok, _} =
             Operator.reselect(
               claim.batch.id,
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:same-original-feedback"
             )

    assert {:ok, again} = Batches.claim("rebuild-test", @settings)
    assert {:ok, second} = Batches.prepare(again)
    refute first.batch_key == second.batch_key

    assert %{"code" => "output_contract_failed", "instruction" => instruction} =
             Jason.decode!(second.prompt)["previous_attempt_error"]

    assert instruction =~ "required JSON shape"
    refute second.prompt =~ first.prompt
    assert Repo.get!(Batch, again.batch.id).start_count == 1
    assert Repo.get!(Batch, again.batch.id).start_limit == 2
  end

  @tag :retry_manifest_feedback
  test "a withdrawn never-started rebuild manifest cannot erase the last actual contract failure" do
    # Source retirement between two operator selections used to erase the only
    # actionable correction, buying another blind attempt on the same lifetime job.
    {topic, current, claim, first} = failed_rebuild!()
    again = reselect_and_claim!(topic, current, claim.batch.id, 0)
    assert {:ok, unstarted} = Batches.prepare(again)
    assert unstarted.started_at == nil

    KnowledgeFixtures.revoke!(current)
    assert {:ok, %{inputs: []}} = Batches.retire_unavailable(again)
    retired = Repo.get!(Responder.State.LearningRun, unstarted.id)
    assert retired.status == :stale
    assert retired.error_code == "learning_source_stale"
    assert retired.started_at == nil
    assert retired.prompt == unstarted.prompt
    assert {:ok, _} = Batches.finish(again, :superseded, "source_unavailable")

    fresh = additional_input!(current)
    selected = reselect_and_claim!(topic, fresh, claim.batch.id, 1)
    assert {:ok, next} = Batches.prepare(selected)
    prompt = Jason.decode!(next.prompt)
    assert %{"code" => "output_contract_failed"} = prompt["previous_attempt_error"]
    assert Enum.map(prompt["inputs"], & &1["source_input_id"]) == [fresh.id]
    assert next.source_dependencies == LearningSources.for_entry(fresh)
    assert prompt["knowledge"] == []
    refute next.prompt =~ topic.state["summary"]
    assert Repo.get!(Responder.State.LearningRun, first.id).prompt == first.prompt
    assert Repo.get!(Batch, selected.batch.id).start_count == 1
    assert Repo.get!(Batch, selected.batch.id).start_limit == 2
    assert Repo.get!(Batch, selected.batch.id).budget_version == 2
  end

  @tag :retry_manifest_feedback
  test "same-key local retirement cannot mask the prior executed failure with an unstarted manifest" do
    {topic, current, claim, _first} = failed_rebuild!()
    again = reselect_and_claim!(topic, current, claim.batch.id, 0)
    assert {:ok, unstarted} = Batches.prepare(again)

    # Structural local invalidation through the owned retirement API; neither a
    # model result nor a provider stop receipt is invented for an unstarted run.
    assert {:ok, %{status: :stale, started_at: nil}} =
             Learning.end_attempt(unstarted.id, :learning_context_stale, again)

    assert {:ok, next} = Batches.prepare(again)
    assert next.batch_key == unstarted.batch_key
    assert next.generation == unstarted.generation + 1

    assert %{"code" => "output_contract_failed"} =
             Jason.decode!(next.prompt)["previous_attempt_error"]

    assert Repo.get!(Batch, again.batch.id).start_count == 1
    assert Repo.get!(Batch, again.batch.id).start_limit == 2
  end

  @tag :retry_manifest_feedback
  test "a later accepted no-change judgment clears an older contract correction" do
    {topic, current, claim, _first} = failed_rebuild!()
    again = reselect_and_claim!(topic, current, claim.batch.id, 0)
    assert {:ok, second} = Batches.prepare(again)
    assert {:ok, _} = Batches.begin_execution(again, second.id)

    # Exact accepted result reused for its host protocol shape, not a claim that
    # the unrelated original chatter judgment applies to these selected sources.
    empty =
      "testdata/learning/recorded-no-change-result.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("result")

    assert {:ok, _} = Fixtures.accept(second.id, empty, %{})
    assert {:ok, _} = stop(second, again)
    assert {:ok, _} = Batches.finish(again, :no_change)
    selected = reselect_and_claim!(topic, current, claim.batch.id, 1)
    assert {:ok, next} = Batches.prepare(selected)
    assert Jason.decode!(next.prompt)["previous_attempt_error"] == nil
    assert Repo.get!(Batch, selected.batch.id).start_count == 2
    assert Repo.get!(Batch, selected.batch.id).start_limit == 3
  end

  test "an empty search does not hide the picker when other eligible originals exist" do
    {topic, _old, _current} = unavailable_topic!()
    assert {:ok, preview} = Rebuilds.preview(topic.id, %{page: 1, q: "no-such-retained-phrase"})
    assert preview.eligible?
    assert preview.entries == []
    assert preview.total == 0
  end

  test "a stale selected revision cannot queue an action or spend a new lifetime budget" do
    {topic, _old, current} = unavailable_topic!()
    stale = %{selection(current) | "revision" => current.revision + 1}

    assert {:error, :learning_source_stale} =
             Operator.rebuild(topic.id, 1, 1, [stale], "operator:andrew", "rebuild:stale-source")

    assert Repo.aggregate(Responder.Operator.Action, :count) == 0
    assert Repo.aggregate(Batch, :count) == 1
    assert Repo.get!(ConversationKnowledge, topic.id) == topic
  end

  test "the narrow schema and host both reject multiple proposals without changing the old topic" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, _} = rebuild(topic, current, "rebuild:cardinality")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    schema = JSV.build!(run.output_schema)
    one = Jason.decode!(result(current))
    assert {:ok, ^one} = JSV.validate(one, schema, cast: false)
    second = %{proposal(current) | "topic_key" => "another-unrequested-topic"}
    invalid = %{one | "updates" => [proposal(current), second]}
    assert {:error, _} = JSV.validate(invalid, schema, cast: false)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    assert {:error, :invalid_learning_result} =
             Fixtures.accept(run.id, Jason.encode!(invalid), %{})

    assert Repo.get!(ConversationKnowledge, topic.id) == topic
    assert Repo.aggregate(KnowledgeRevision, :count) == 1
  end

  test "withdrawal after selection settles the request without a remote start and allows explicit reselection" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, receipt} = rebuild(topic, current, "rebuild:selection-withdrawn")
    KnowledgeFixtures.revoke!(current)
    settings = Map.put(@settings, :worker_ref, "rebuild-test")
    assert {:ok, %{status: :superseded, start_count: 0}} = Dispatcher.run_once(settings)
    batch = Repo.get!(Batch, receipt.outcome["batch_id"])
    assert batch.error_code == "source_unavailable"
    assert Repo.get!(ConversationKnowledge, topic.id) == topic

    assert {:error, :learning_source_stale} =
             Operator.reselect(
               batch.id,
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:still-withdrawn"
             )

    assert Repo.get!(Batch, batch.id).start_count == 0
  end

  test "explicit same-generation retargeting cannot be authorized by the old head version" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, receipt} = rebuild(topic, current, "rebuild:retarget")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :no_change)

    # Structural head advancement exercises the operator CAS, not a claimed
    # model answer. A permission-restored topic can advance normally and later
    # become unavailable again within the same generation.
    advanced = Repo.update!(Ecto.Changeset.change(topic, version: topic.version + 1))

    assert {:error, :knowledge_rebuild_conflict} =
             Operator.reselect(
               receipt.outcome["batch_id"],
               0,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:old-head"
             )

    assert {:ok, granted} =
             Operator.reselect(
               receipt.outcome["batch_id"],
               0,
               target(advanced),
               [selection(current)],
               "operator:andrew",
               "rebuild:current-head"
             )

    assert granted.outcome["batch_id"] == receipt.outcome["batch_id"]
    assert granted.outcome["start_count"] == 0
    assert granted.outcome["start_limit"] == 1
    assert Repo.get!(Batch, claim.batch.id).rebuild_target_version == advanced.version

    assert {:ok, repeated} =
             Operator.reselect(
               receipt.outcome["batch_id"],
               0,
               target(advanced),
               [selection(current)],
               "operator:andrew",
               "rebuild:current-head"
             )

    assert repeated.status == :duplicate

    assert {:error, :learning_retry_conflict} =
             Operator.reselect(
               receipt.outcome["batch_id"],
               0,
               target(advanced),
               [selection(current)],
               "operator:andrew",
               "rebuild:old-budget"
             )
  end

  @tag :rebuild_mode
  test "explicit reselection changes one execution mode without replacing the batch or its spent budget" do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, receipt} = rebuild(topic, current, "rebuild:mode")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :no_change)
    previous = Repo.get!(Batch, claim.batch.id)

    # Structural execution-mode wrapper over an unchanged retained original.
    # This tests scope reassignment, not a newly captured source event.
    live = Repo.update!(Ecto.Changeset.change(current, execution_mode: :live))

    assert {:ok, changed} =
             Operator.reselect(
               previous.id,
               0,
               target(topic),
               [selection(live)],
               "operator:andrew",
               "rebuild:live-selection"
             )

    assert changed.outcome["batch_id"] == receipt.outcome["batch_id"]
    assert changed.outcome["execution_mode"] == "live"
    current_batch = Repo.get!(Batch, previous.id)
    assert current_batch.execution_mode == :live
    refute current_batch.scope_key == previous.scope_key
    assert current_batch.start_count == previous.start_count
    assert current_batch.start_limit == previous.start_count + 1
    assert {:ok, next} = Batches.claim("rebuild-live-test", @settings)
    assert {:ok, run} = Batches.prepare(next)
    assert [input] = run.inputs
    assert input["execution_mode"] == "live"
  end

  for busy_mode <- [:shadow, :live] do
    test "mode reassignment respects an active #{busy_mode} scope before granting a new start" do
      {topic, _old, current} = unavailable_topic!()
      assert {:ok, _} = rebuild(topic, current, "rebuild:busy-mode")
      assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
      assert {:ok, previous} = Batches.finish(claim, :no_change)
      live = Repo.update!(Ecto.Changeset.change(current, execution_mode: :live))
      mode = unquote(busy_mode)

      scope = %{
        "transport" => previous.transport,
        "conversation_ref" => previous.conversation_ref,
        "repository_ref" => previous.repository_ref,
        "execution_mode" => Atom.to_string(mode)
      }

      # Structural active-assignment row: no provider or extra source content.
      Repo.insert!(%{
        previous
        | id: Ecto.UUID.generate(),
          scope_key: CanonicalJSON.digest(scope),
          status: :queued,
          execution_mode: mode,
          rebuild_target_id: nil,
          rebuild_target_version: nil,
          rebuild_target_generation: nil,
          rebuild_selection: nil,
          completed_at: nil
      })

      assert {:error, :learning_scope_busy} =
               Operator.reselect(
                 previous.id,
                 0,
                 target(topic),
                 [selection(live)],
                 "operator:andrew",
                 "rebuild:cross-busy"
               )

      assert Repo.get!(Batch, previous.id) == previous
    end
  end

  test "mixed-mode originals are rejected with an actionable reason before any batch grant" do
    {topic, _old, current} = unavailable_topic!()

    raw =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    id = Ecto.UUID.generate()
    # Only source identity and execution-mode wrappers are structural; the
    # harvested original body and occurred_at are unchanged.
    raw =
      Map.merge(raw, %{
        "id" => id,
        "dedupe_key" => "structural:#{id}",
        "event_ref" => "structural:#{id}",
        "native_input_id" => id
      })

    extra = Fixtures.retained_input!(raw, @settings)
    extra = Repo.update!(Ecto.Changeset.change(extra, execution_mode: :live))

    assert {:error, :learning_mixed_execution_modes} =
             Operator.rebuild(
               topic.id,
               1,
               1,
               [selection(current), selection(extra)],
               "operator:andrew",
               "rebuild:mixed"
             )

    assert Repo.aggregate(Responder.Operator.Action, :count) == 0
    assert Repo.aggregate(Batch, :count) == 1
  end

  defp failed_rebuild! do
    {topic, _old, current} = unavailable_topic!()
    assert {:ok, _} = rebuild(topic, current, "rebuild:contract-feedback")
    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    assert {:ok, first} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, first.id)

    # Harvested terminal failure; only host-owned request/session identities are
    # rebound. The actual dispatcher-to-failure recorder has its own regression.
    terminal =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("remote_error")

    receipt =
      terminal
      |> Map.take(~w(state error_code finished_at))
      |> Map.merge(%{
        "session_id" => "host-contract-session:#{first.id}",
        "turn_id" => "host-contract-turn:#{first.id}",
        "target" => "host-contract-test-provider",
        "prompt_sha256" => first.prompt_sha256
      })

    assert {:ok, _} = FleetSession.ensure(first)
    assert {:ok, _} = FleetSession.bind(first, receipt["session_id"])

    assert {:ok, _} =
             Learning.bind_turn(first.id, receipt["session_id"], receipt["turn_id"], claim)

    assert {:ok, _} = Learning.fail(first.id, :output_contract_failed, receipt, claim)
    assert {:ok, _} = Batches.finish(claim, :deferred, "output_contract_failed")
    {topic, current, claim, first}
  end

  defp reselect_and_claim!(topic, current, batch_id, budget_version) do
    assert {:ok, _} =
             Operator.reselect(
               batch_id,
               budget_version,
               target(topic),
               [selection(current)],
               "operator:andrew",
               "rebuild:feedback-selection:#{budget_version}"
             )

    assert {:ok, claim} = Batches.claim("rebuild-test", @settings)
    claim
  end

  defp unavailable_topic! do
    [old, current] = Fixtures.inputs!()

    proposal =
      proposal(old)
      |> Map.drop(~w(action source_input_ids))
      |> Map.put("topic_key", "original-historical-topic")

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(old, proposal, []) end)

    topic = Repo.one!(ConversationKnowledge)
    KnowledgeFixtures.revoke!(old)
    [old, current] = Fixtures.normalize_queue_timestamps!([old, current])
    assert {:ok, claim} = Batches.claim("ack-existing-inputs", @settings)
    assert {:ok, _} = Batches.finish(claim, :no_change)
    {topic, old, current}
  end

  defp additional_input!(original) do
    id = Ecto.UUID.generate()

    # Structural identity wrapper over an unchanged original; no invented body.
    original
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{
      "id" => id,
      "dedupe_key" => "structural:#{id}",
      "event_ref" => "structural:#{id}",
      "native_input_id" => id,
      "actor_kind" => Atom.to_string(original.actor_kind),
      "occurred_at" => original.occurred_at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    })
    |> Fixtures.retained_input!(@settings)
    |> List.wrap()
    |> Fixtures.normalize_queue_timestamps!()
    |> hd()
  end

  defp rebuild(topic, current, action),
    do:
      Operator.rebuild(
        topic.id,
        topic.version,
        topic.source_generation,
        [selection(current)],
        "operator:andrew",
        action
      )

  defp target(topic), do: %{version: topic.version, generation: topic.source_generation}

  defp selection(entry),
    do: %{
      "source_input_id" => entry.id,
      "revision" => entry.revision,
      "fingerprint" => entry.event_fingerprint
    }

  defp result(entry),
    do:
      Jason.encode!(%{
        "updates" => [proposal(entry)],
        "reason" => "Rebuild using the selected original only."
      })

  defp proposal(entry) do
    %{
      "action" => "create",
      "source_input_ids" => [entry.id],
      "topic_key" => "selected-original-haproxy",
      "title" => "HAProxy alert history",
      "summary" =>
        "This selected message reports a historical HAProxy memory-limit alert; current service health is unverified.",
      "topics" => ["HAProxy"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }
  end

  defp stop(run, claim),
    do:
      Learning.record_stop(
        run.id,
        %{
          "id" => "host-contract-turn:#{run.id}",
          "session_id" => "host-contract-session:#{run.id}",
          "state" => "completed"
        },
        claim
      )
end
