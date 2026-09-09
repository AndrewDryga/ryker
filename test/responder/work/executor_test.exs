defmodule Responder.Work.ExecutorTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Artifacts
  alias Responder.Artifacts.Outputs
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Repo
  alias Responder.State.{ConversationKnowledge, KnowledgeSnapshot, Record, Records}
  alias Responder.StateTools.FixedTools
  alias Responder.TestSupport.FakeWorkCoopAPI, as: FakeAPI

  alias Responder.Work.{
    Activity,
    Cancellation,
    Custody,
    DeliveryReceipt,
    Executor,
    Final,
    FinalPreflight,
    Result,
    StateBinding,
    SubmissionBuilder
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

  for origin <- [:automated, :human_followup, :human_followup_rotated] do
    test "an unchanged #{origin} notification settles into an event-only wait without a Slack delivery" do
      # The harvested TFC turn posted another unchanged-status reply at 11:16 UTC.
      # Exercise its approved silent equivalent through real validation and custody.
      claim =
        if unquote(origin) in [:human_followup, :human_followup_rotated],
          do: claim_after_human_reply!(),
          else: claim_episode!("quiet-tfc", nil, :live, nil, nil, nil, "slack:app:B0BHPQTBMA7")

      claim =
        if unquote(origin) == :human_followup_rotated do
          assert {:ok, rotated} =
                   Custody.rotate_session(
                     claim.episode.id,
                     claim.turn.turn_ref,
                     claim.lease_ref,
                     claim.session.generation
                   )

          %{claim | session: rotated.session, turn: rotated.turn}
        else
          claim
        end

      assert {:ok, wait} =
               Records.create(Records.token(claim.turn), "quiet-wait", "event_wait", %{
                 "kind" => "source_event",
                 "deadline_at" => nil,
                 "event_matcher" => %{
                   "type" => "source_event",
                   "source_kind" => "slack",
                   "match" => %{
                     "bot_id" => "B0BHPQTBMA7",
                     "attachments" => [%{"title" => "Run run-k9CpPp3nWjQrkCMG"}]
                   },
                   "poll_after" => nil,
                   "on_timeout" => nil
                 },
                 "verification" => "Verify the exact run outcome from its next notification."
               })

      harvested = "testdata/work/terraform-unchanged-wait.json" |> File.read!() |> Jason.decode!()

      candidate =
        harvested["candidate"]
        |> Map.merge(%{
          "delivery" => "none",
          "message" => nil,
          "decision_reason" => "No lifecycle change."
        })
        |> put_in(["outcome", "record_refs"], [wait.ref])
        |> Jason.encode!()

      visible_fallback =
        candidate
        |> Jason.decode!()
        |> Map.merge(%{
          "delivery" => "reply",
          "message" => "Still pending.",
          "decision_reason" => nil
        })
        |> Jason.encode!()

      {:ok, fake} = fake_for(claim, [candidate, visible_fallback])
      FakeAPI.update(fake, fn state -> %{state | submit_count: 1} end)

      assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
      assert turn.status == :settled

      if unquote(origin) == :human_followup_rotated,
        do: assert(turn.submission["context"]["mode"] == "full")

      assert turn.delivery_ref == nil
      assert turn.delivery_document == nil
      episode = Repo.get!(Responder.Episodes.Episode, claim.episode.id)
      assert episode.state == :waiting_for_event
      assert episode.owner_ref == wait.ref
      assert episode.owner_deadline_at == nil
      subscription = Repo.get_by!(Responder.State.EventSubscription, record_id: wait.id)
      assert subscription.status == :active
      assert subscription.poll_after == nil
      assert {:ok, nil} = Custody.claim_next("quiet-wait-proof", 60, :work)
      assert FakeAPI.state(fake).validations |> Enum.map(& &1.verdict) == [:accept]
    end
  end

  test "a follow-up cannot reuse knowledge hidden in the previous native session" do
    # Empty current recall does not erase the transcript of a warm provider session.
    claim = claim_with_bound_empty_session!("withdrawn-session-knowledge")
    {source, document} = KnowledgeFixtures.learn!(claim.episode)
    assert :ok = KnowledgeSnapshot.expose(claim, [document])
    KnowledgeFixtures.revoke!(source)
    {:ok, fake} = fake_for(claim, [reply("Continue without withdrawn memory.")])

    create_session = fn fallback ->
      FakeAPI.update(fake, fn state ->
        %{state | session: Map.put(state.session, "id", "remote:knowledge-replacement")}
      end)

      fallback.()
    end

    assert {:ok, %{status: :accepted}} =
             Executor.run(claim, protocol_options(fake, %{create_session: create_session}))

    turn = Repo.get!(Responder.Work.Turn, claim.turn.id)
    refute turn.session_id == claim.session.id
    assert turn.submission["context"]["mode"] == "full"

    assert get_in(turn.submission, ["context", "operator_context", "continuity", "knowledge"]) in [
             nil,
             []
           ]
  end

  for memory_kind <- [:knowledge, :observation] do
    test "tool-recalled #{memory_kind} is rechecked even when absent from the frozen briefing" do
      claim = accepted_intent_turn!("withdrawn-tool-knowledge")
      {source, _document} = KnowledgeFixtures.learn!(claim.episode)
      if unquote(memory_kind) == :observation, do: Repo.delete_all(ConversationKnowledge)
      binding = Map.put(claim, :state_token, "test-token")

      expected_kind = "conversation_#{unquote(memory_kind)}"

      assert {:ok, %{"memories" => memories}} =
               FixedTools.call(
                 "search_memory",
                 %{
                   "query" => "draft-ai-suggestions",
                   "scope" => "current_channel",
                   "limit" => 10,
                   "kinds" => ["continuity"],
                   "after" => nil,
                   "before" => nil,
                   "time_basis" => "source",
                   "cursor" => nil
                 },
                 %{binding: binding, cursor_secret: "work-executor-search-cursor-test"}
               )

      assert Enum.any?(memories, &(&1["kind"] == expected_kind))

      KnowledgeFixtures.revoke!(source)

      result =
        Custody.accept_result(
          claim.episode.id,
          claim.episode.key,
          claim.turn.turn_ref,
          claim.lease_ref,
          claim.turn.candidate_sha256,
          claim.turn.candidate_attempt,
          "validation:tool-memory"
        )

      assert Repo.get!(Responder.Work.Turn, claim.turn.id).result_ref == nil
      assert {:error, :work_knowledge_context_stale} = result
    end
  end

  test "a source withdrawn by the final session read never reaches model submission" do
    # The early check passed, then the remote revision read raced source deletion.
    claim = claim_with_bound_empty_session!("late-knowledge-revocation-draft-ai-suggestions")
    {source, _document} = KnowledgeFixtures.learn!(claim.episode)
    {:ok, submission} = SubmissionBuilder.build(claim)
    assert [_] = get_in(submission, ["context", "operator_context", "continuity", "knowledge"])

    {:ok, turn} =
      Custody.freeze_submission(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission
      )

    claim = %{claim | turn: turn}
    {:ok, fake} = fake_for(claim, [reply("Must not use withdrawn memory.")])
    counter = make_ref()

    get_session = fn fallback ->
      reads = Process.get(counter, 0) + 1
      Process.put(counter, reads)
      if reads == 2, do: KnowledgeFixtures.revoke!(source)
      fallback.()
    end

    result = Executor.run(claim, protocol_options(fake, %{get_session: get_session}))
    assert FakeAPI.state(fake).submissions == []
    assert {:error, :work_knowledge_context_stale} = result
    assert Process.get(counter) >= 2
  end

  test "withdrawn frozen knowledge cannot reach the model" do
    # A queued retry can outlive the source that supplied its briefing.
    claim = claim_with_bound_empty_session!("withdrawn-knowledge")
    {:ok, submission} = SubmissionBuilder.build(claim)

    context =
      put_in(submission["context"], ["operator_context", "continuity", "knowledge"], [
        %{"source_ref" => "knowledge:#{Ecto.UUID.generate()}", "version" => 1}
      ])

    submission = %{submission | "context" => context}

    {:ok, turn} =
      Custody.freeze_submission(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission
      )

    claim = %{claim | turn: turn}
    {:ok, fake} = fake_for(claim, [reply("Must not use withdrawn memory.")])
    assert {:error, :work_knowledge_context_stale} = Executor.run(claim, options(fake))
    assert FakeAPI.state(fake).submissions == []
  end

  test "withdrawn knowledge is rechecked inside result acceptance before delivery is created" do
    # Provider execution may finish after a source is withdrawn; acceptance is a separate fence.
    claim = accepted_intent_turn!("withdrawn-acceptance")

    context =
      Map.put(claim.turn.submission["context"], "operator_context", %{
        "continuity" => %{
          "knowledge" => [%{"source_ref" => "knowledge:#{Ecto.UUID.generate()}", "version" => 1}]
        }
      })

    claim.turn
    |> Ecto.Changeset.change(submission: %{claim.turn.submission | "context" => context})
    |> Repo.update!()

    assert {:error, :work_knowledge_context_stale} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.turn.candidate_sha256,
               claim.turn.candidate_attempt,
               "validation:withdrawn"
             )

    unchanged = Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert unchanged.status == claim.turn.status
    assert unchanged.result_ref == nil
  end

  defmodule ProtocolAPI do
    @moduledoc false
    @behaviour Responder.Coop.API

    alias Responder.TestSupport.FakeWorkCoopAPI, as: FakeAPI

    def capabilities(client),
      do:
        dispatch(client, :capabilities, fn ->
          {:ok, %{"repository_freshness_receipt_versions" => [2]}}
        end)

    def capabilities(client, session) do
      case Map.fetch(client.overrides, :session_capabilities) do
        {:ok, function} when is_function(function, 1) -> function.(session)
        {:ok, response} -> response
        :error -> capabilities(client)
      end
    end

    def operation_by_key(client, key),
      do:
        dispatch(client, :operation_by_key, fn -> FakeAPI.operation_by_key(client.fake, key) end)

    def create_session(client, key, policy, task),
      do:
        dispatch(client, :create_session, fn ->
          FakeAPI.create_session(client.fake, key, policy, task)
        end)

    def fence_create_session(client, key, policy, task),
      do:
        dispatch(client, :fence_create_session, fn ->
          FakeAPI.fence_create_session(client.fake, key, policy, task)
        end)

    def get_session(client, session_id),
      do: dispatch(client, :get_session, fn -> FakeAPI.get_session(client.fake, session_id) end)

    def get_changes(client, session_id),
      do: dispatch(client, :get_changes, fn -> FakeAPI.get_changes(client.fake, session_id) end)

    def get_changes_page(client, session_id, patch_offset, patch_limit),
      do:
        dispatch(client, :get_changes_page, fn ->
          FakeAPI.get_changes_page(client.fake, session_id, patch_offset, patch_limit)
        end)

    def close_session(client, session_id, key, revision),
      do:
        dispatch(client, :close_session, fn ->
          FakeAPI.close_session(client.fake, session_id, key, revision)
        end)

    def submit_turn(client, session_id, key, revision, prompt, schema),
      do:
        dispatch(client, :submit_turn, fn ->
          FakeAPI.submit_turn(client.fake, session_id, key, revision, prompt, schema)
        end)

    def fence_submit_turn(client, session_id, key, revision, prompt, schema),
      do:
        dispatch(client, :fence_submit_turn, fn ->
          FakeAPI.fence_submit_turn(client.fake, session_id, key, revision, prompt, schema)
        end)

    def submit_turn_with_artifacts(client, session_id, key, revision, prompt, schema, artifacts),
      do:
        dispatch(client, :submit_turn, fn ->
          FakeAPI.submit_turn_with_artifacts(
            client.fake,
            session_id,
            key,
            revision,
            prompt,
            schema,
            artifacts
          )
        end)

    def fence_submit_turn_with_artifacts(
          client,
          session_id,
          key,
          revision,
          prompt,
          schema,
          artifacts
        ),
        do:
          dispatch(client, :fence_submit_turn, fn ->
            FakeAPI.fence_submit_turn_with_artifacts(
              client.fake,
              session_id,
              key,
              revision,
              prompt,
              schema,
              artifacts
            )
          end)

    def submit_frozen_turn(
          client,
          session_id,
          key,
          revision,
          submission,
          binding,
          artifacts
        ),
        do:
          dispatch(client, :submit_turn, fn ->
            FakeAPI.submit_frozen_turn(
              client.fake,
              session_id,
              key,
              revision,
              submission,
              binding,
              artifacts
            )
          end)

    def fence_frozen_turn(
          client,
          session_id,
          key,
          revision,
          submission,
          binding,
          artifacts
        ),
        do:
          dispatch(client, :fence_submit_turn, fn ->
            FakeAPI.fence_frozen_turn(
              client.fake,
              session_id,
              key,
              revision,
              submission,
              binding,
              artifacts
            )
          end)

    def get_turn(client, session_id, turn_id),
      do:
        dispatch(client, :get_turn, fn -> FakeAPI.get_turn(client.fake, session_id, turn_id) end)

    def get_output_artifact(client, session_id, turn_id, artifact_id),
      do:
        dispatch(client, :get_output_artifact, fn ->
          FakeAPI.get_output_artifact(client.fake, session_id, turn_id, artifact_id)
        end)

    def validate_candidate(client, session_id, turn_id, key, sha256, verdict),
      do:
        dispatch(client, :validate_candidate, fn ->
          FakeAPI.validate_candidate(
            client.fake,
            session_id,
            turn_id,
            key,
            sha256,
            verdict
          )
        end)

    def cancel_turn(client, session_id, turn_id, key, revision),
      do:
        dispatch(client, :cancel_turn, fn ->
          FakeAPI.cancel_turn(client.fake, session_id, turn_id, key, revision)
        end)

    defp dispatch(client, name, fallback) do
      case Map.fetch(client.overrides, name) do
        :error -> fallback.()
        {:ok, function} when is_function(function, 1) -> function.(fallback)
        {:ok, response} -> response
      end
    end
  end

  test "one frozen turn reaches a validated durable delivery intent" do
    claim = claim_episode!("valid")

    activity = [
      %{
        "id" => "event:valid:1",
        "occurred_at" => DateTime.to_iso8601(@now),
        "payload" => %{"text" => "Checking the requested evidence."},
        "sequence" => 1,
        "session_id" => "remote_work",
        "turn_id" => "work_turn_remote_work_1",
        "type" => "model.thought",
        "version" => 1
      }
    ]

    {:ok, fake} =
      FakeAPI.start_link([reply("Investigation complete.")], activity_events: activity)

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.turn.status == :delivery_pending
    assert execution.episode.owner_kind == :delivery

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.submissions |> hd() |> Map.fetch!(:schema) == Final.json_schema()
    refute state.submissions |> hd() |> Map.fetch!(:prompt) =~ ~s("$schema")
    assert [{"remote_work", 0, 1_000} | _rest] = state.activity_requests

    assert [%{kind: "model.thought"}] = Activity.list_for_episode(claim.episode.id)
  end

  test "activity narration failure never costs the accepted answer" do
    claim = claim_episode!("activity-unavailable")

    {:ok, fake} =
      FakeAPI.start_link([reply("The answer still completes.")],
        activity_error: {:coop_unavailable, :activity_stream}
      )

    assert {:ok, %{status: :accepted, turn: %{status: :delivery_pending}}} =
             Executor.run(claim, options(fake))

    assert [{"remote_work", 0, 1_000} | _rest] = FakeAPI.state(fake).activity_requests
    assert Activity.list_for_episode(claim.episode.id) == []
  end

  test "accepted writable work is checkpointed before local delivery custody is released" do
    claim = claim_episode!("writable-checkpoint")

    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:writable-checkpoint",
      "prompt" => "Change the parser without losing the workspace.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Checkpoint writable work"
    }

    session =
      claim.session
      |> Ecto.Changeset.change(repository_ref: "responder", workspace_task: workspace_task)
      |> Repo.update!()

    claim = %{claim | session: session}

    {:ok, fake} =
      FakeAPI.start_link([reply("Writable milestone complete.")],
        changes: [
          workspace_changes(
            committed: [%{"path" => "lib/parser.ex", "status" => "modified"}],
            fork_head: "task-commit",
            fork_tree: "task-tree"
          )
        ]
      )

    assert {:ok, %{status: :accepted, turn: %{status: :delivery_pending}}} =
             Executor.run(claim, options(fake))

    assert [key] = FakeAPI.state(fake).checkpoint_keys
    assert key =~ "responder:work:checkpoint:#{claim.turn.id}:a1:"

    offer =
      Repo.get_by!(Record,
        episode_id: claim.episode.id,
        kind: "publication_offer",
        operation_id: "host:publication:ready"
      )

    assert offer.turn_id == claim.turn.id
    assert offer.status == :open

    assert offer.payload == %{
             "body" => "Writable milestone complete.",
             "title" => "Checkpoint writable work"
           }

    settled = Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert get_in(settled.delivery_document, ["outcome", "record_refs"]) == []
  end

  test "writable work cannot settle when its worker cannot produce a checkpoint" do
    claim = claim_episode!("writable-checkpoint-required")

    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:writable-checkpoint-required",
      "prompt" => "Change the parser without losing the workspace.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Checkpoint writable work"
    }

    session =
      claim.session
      |> Ecto.Changeset.change(repository_ref: "responder", workspace_task: workspace_task)
      |> Repo.update!()

    claim = %{claim | session: session}

    {:ok, fake} =
      FakeAPI.start_link([reply("Writable milestone complete.")],
        changes: [
          workspace_changes(
            committed: [%{"path" => "lib/parser.ex", "status" => "modified"}],
            fork_head: "task-commit",
            fork_tree: "task-tree"
          )
        ]
      )

    executor_options =
      fake
      |> options()
      |> Keyword.merge(api: ProtocolAPI, client: %{fake: fake, overrides: %{}})

    assert Executor.run(claim, executor_options) ==
             {:error, {:invalid_work_executor, :workspace_checkpoint_api}}

    refute Repo.get_by(Record,
             episode_id: claim.episode.id,
             kind: "publication_offer",
             operation_id: "host:publication:ready"
           )

    assert Repo.get!(Responder.Work.Turn, claim.turn.id).status == :pending
  end

  test "a completed turn retains exact measured usage timing and effective target" do
    claim = claim_episode!("usage")

    {:ok, fake} =
      FakeAPI.start_link([reply("Measured investigation complete.")],
        session_target: "claude:opus/high@work",
        turn_queued_at: "2026-08-28T11:59:50Z",
        turn_started_at: "2026-08-28T11:59:55Z",
        turn_finished_at: "2026-08-28T12:00:00Z",
        turn_usage: %{
          "cached_input_tokens" => 800,
          "cost_recorded" => true,
          "cost_usd" => 0.0125,
          "input_tokens" => 1_200,
          "output_tokens" => 300,
          "reasoning_tokens" => 25
        }
      )

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert turn.execution_target == "claude:opus/high@work"
    assert turn.usage_input_tokens == 1_200
    assert turn.usage_cached_input_tokens == 800
    assert turn.usage_output_tokens == 300
    assert turn.usage_reasoning_tokens == 25
    assert Decimal.equal?(turn.usage_cost_usd, Decimal.new("0.0125"))
    assert turn.usage_cost_recorded
    assert turn.usage_queued_ms == 5_000
    assert turn.usage_provider_ms == 5_000
    assert turn.usage_host_ms >= 0
    assert turn.remote_queued_at == ~U[2026-08-28 11:59:50.000000Z]
    assert turn.remote_started_at == ~U[2026-08-28 11:59:55.000000Z]
    assert turn.remote_finished_at == ~U[2026-08-28 12:00:00.000000Z]
  end

  test "a provider that reports no usage remains explicitly unmeasured" do
    claim = claim_episode!("usage-unmeasured")
    {:ok, fake} = FakeAPI.start_link([reply("Unmeasured investigation complete.")])

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert is_nil(turn.usage_input_tokens)
    assert is_nil(turn.usage_cost_recorded)
    assert is_nil(turn.usage_queued_ms)
  end

  test "one Work session freezes and sends its dedicated state-tools binding" do
    claim = claim_episode!("state-tools-binding")
    candidate = reply("Bound work complete.")

    assert {:ok, _turn} =
             Custody.record_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               FinalPreflight.candidate_sha256(Jason.decode!(candidate)),
               FinalPreflight.ledger_sha256(
                 claim.episode.id,
                 claim.episode.semantic_version,
                 []
               ),
               claim.episode.semantic_version
             )

    {:ok, fake} = FakeAPI.start_link([candidate])

    run_options =
      options(fake)
      |> Keyword.put(:state_tool_capabilities, [:schedules])
      |> Keyword.put(:state_tools_endpoint, "https://responder.example/v1/state-tools/mcp")
      |> Keyword.put(:state_tools_secret, "controller-state-tools-secret")

    assert {:ok, %{status: :accepted}} = Executor.run(claim, run_options)

    state = FakeAPI.state(fake)
    assert [binding] = state.bindings
    assert binding["endpoint"] == "https://responder.example/v1/state-tools/mcp"
    assert Regex.match?(~r/\A[0-9a-f]{64}[A-Za-z0-9_-]{43}\z/, binding["token"])
    assert StateBinding.scope_matches?(binding["token"], StateBinding.local_scope(claim.session))

    persisted = Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted.state_tools_endpoint == binding["endpoint"]

    assert persisted.state_tools_token_sha256 ==
             StateBinding.sha256(binding["token"])

    [submitted] = state.submissions
    assert submitted.responder_binding == binding
    tool_names = submitted.prompt |> Jason.decode!() |> get_in(["work", "responder_state_tools"])
    refute "wait_for" in tool_names
    assert "propose_automation" in tool_names
  end

  test "a product-bound final is repaired in the same Coop turn until exact preflight exists" do
    claim = claim_episode!("state-tools-preflight-repair")
    candidate = reply("This final was checked through the owning state tool.")

    record_preflight = fn ->
      assert {:ok, _turn} =
               Custody.record_final_preflight(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 FinalPreflight.candidate_sha256(Jason.decode!(candidate)),
                 FinalPreflight.ledger_sha256(
                   claim.episode.id,
                   claim.episode.semantic_version,
                   []
                 ),
                 claim.episode.semantic_version
               )
    end

    {:ok, fake} =
      FakeAPI.start_link([candidate, candidate], on_validation_reject: record_preflight)

    run_options =
      options(fake)
      |> Keyword.put(:state_tools_endpoint, "https://responder.example/v1/state-tools/mcp")
      |> Keyword.put(:state_tools_secret, "controller-state-tools-secret")

    assert {:ok, %{status: :accepted}} = Executor.run(claim, run_options)

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             "Call validate_final"
  end

  test "the exact authenticated input artifact reaches Coop from durable custody" do
    data = "Slack attachment bytes"

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: data,
               media_type: "text/plain",
               name: "diagnostic.txt",
               source_kind: "slack",
               source_ref: "T123:F-executor"
             })

    claim =
      claim_episode!("artifact-submit", %{
        "files" => [
          %{
            "artifact_ref" => artifact.ref,
            "media_type" => artifact.media_type,
            "name" => artifact.name,
            "sha256" => artifact.sha256,
            "status" => "available"
          }
        ],
        "text" => "Inspect this diagnostic."
      })

    {:ok, fake} = fake_for(claim, [reply("The diagnostic is healthy.")])
    assert {:ok, %{status: :accepted}} = Executor.run(claim, options(fake))

    assert [%{artifacts: [submitted]}] = FakeAPI.state(fake).submissions
    assert submitted["data"] == data
    assert submitted["sha256"] == artifact.sha256

    persisted = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted.submission["input_artifact_refs"] == [artifact.ref]
  end

  test "a referenced Coop output artifact is verified and retained before delivery custody" do
    data = <<137, 80, 78, 71, 13, 10, 26, 10, "generated-chart">>
    sha256 = digest(data)
    artifact_ref = "artifact_#{binary_part(sha256, 0, 24)}"

    metadata = %{
      "bytes" => byte_size(data),
      "id" => artifact_ref,
      "media_type" => "image/png",
      "name" => "service-load.png",
      "sha256" => sha256
    }

    remote = Map.put(metadata, "data", data)
    claim = claim_episode!("output-artifact")

    candidate =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The requested chart is attached.",
        "outcome" => %{
          "artifact_refs" => [artifact_ref],
          "record_refs" => [],
          "state" => "complete"
        }
      })

    {:ok, fake} =
      FakeAPI.start_link([candidate],
        output_artifact_metadata: [metadata],
        output_artifacts: %{artifact_ref => remote}
      )

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert turn.status == :delivery_pending

    assert {:ok, [stored]} =
             Outputs.fetch_many(turn.id, [artifact_ref])

    assert stored.data == data
    assert stored.name == "service-load.png"
    assert stored.sha256 == sha256
  end

  test "a generated filename is repaired to Coop's durable artifact reference in the same turn" do
    # A real image turn produced valid bytes, but the model only knew the saved
    # filename. Three generic semantic rejections then exhausted the turn even
    # though Coop had already issued the durable artifact identity.
    data = <<137, 80, 78, 71, 13, 10, 26, 10, "handoff-chart">>
    sha256 = digest(data)
    artifact_ref = "artifact_#{binary_part(sha256, 0, 24)}"

    metadata = %{
      "bytes" => byte_size(data),
      "id" => artifact_ref,
      "media_type" => "image/png",
      "name" => "handoff-summary.png",
      "sha256" => sha256
    }

    filename_candidate =
      reply("The requested chart is attached.")
      |> Jason.decode!()
      |> put_in(["outcome", "artifact_refs"], ["handoff-summary.png"])
      |> Jason.encode!()

    reference_candidate =
      reply("The requested chart is attached.")
      |> Jason.decode!()
      |> put_in(["outcome", "artifact_refs"], [artifact_ref])
      |> Jason.encode!()

    claim = claim_episode!("output-artifact-filename-repair")

    assert {:ok, _turn} =
             Custody.record_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               FinalPreflight.candidate_sha256(Jason.decode!(filename_candidate)),
               FinalPreflight.ledger_sha256(
                 claim.episode.id,
                 claim.episode.semantic_version,
                 ["handoff-summary.png"]
               ),
               claim.episode.semantic_version
             )

    {:ok, fake} =
      fake_for(claim, [filename_candidate, reference_candidate],
        output_artifact_metadata: [metadata],
        output_artifacts: %{artifact_ref => Map.put(metadata, "data", data)}
      )

    run_options =
      options(fake)
      |> Keyword.put(:state_tools_endpoint, "https://responder.example/v1/state-tools/mcp")
      |> Keyword.put(:state_tools_secret, "controller-state-tools-secret")

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, run_options)
    assert Enum.map(FakeAPI.state(fake).validations, & &1.verdict) == [:reject, :accept]

    assert FakeAPI.state(fake).validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             artifact_ref

    assert {:ok, [_stored]} = Outputs.fetch_many(turn.id, [artifact_ref])
  end

  test "output artifact custody rejects missing, malformed, and crossed remote bytes" do
    data = <<137, 80, 78, 71, 13, 10, 26, 10, "generated-chart">>
    sha256 = digest(data)
    artifact_ref = "artifact_#{binary_part(sha256, 0, 24)}"

    metadata = %{
      "bytes" => byte_size(data),
      "id" => artifact_ref,
      "media_type" => "image/png",
      "name" => "service-load.png",
      "sha256" => sha256
    }

    candidate =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The requested chart is attached.",
        "outcome" => %{
          "artifact_refs" => [artifact_ref],
          "record_refs" => [],
          "state" => "complete"
        }
      })

    cases = [
      {:crossed_identity, Map.put(Map.put(metadata, "data", data), "id", "artifact_other"),
       {:coop_protocol_error, :output_artifact_identity}},
      {:malformed_payload, Map.put(metadata, "data", 42),
       {:coop_protocol_error, :output_artifact}},
      {:missing_payload, nil, {:coop_error, 404, "artifact_not_found", "artifact not found"}}
    ]

    Enum.each(cases, fn {suffix, remote, expected_error} ->
      claim = claim_episode!("output-artifact-#{suffix}")
      artifacts = if is_nil(remote), do: %{}, else: %{artifact_ref => remote}

      {:ok, fake} =
        fake_for(claim, [candidate],
          output_artifact_metadata: [metadata],
          output_artifacts: artifacts
        )

      assert Executor.run(claim, options(fake)) == {:error, expected_error}

      assert Outputs.fetch_many(claim.turn.id, [artifact_ref]) ==
               {:error, :work_output_artifact_not_found}
    end)

    missing_metadata = claim_episode!("output-artifact-missing-metadata")

    {:ok, fake} =
      fake_for(missing_metadata, [candidate],
        output_artifact_metadata: [metadata],
        output_artifacts: %{artifact_ref => Map.put(metadata, "data", data)}
      )

    strip_metadata = fn fallback ->
      {:ok, response} = fallback.()
      {:ok, update_in(response, ["turn"], &Map.put(&1, "output_artifacts", []))}
    end

    assert Executor.run(
             missing_metadata,
             protocol_options(fake, %{validate_candidate: strip_metadata})
           ) == {:error, {:coop_protocol_error, :accepted_artifact_metadata}}
  end

  test "a semantic rejection repairs in the same Coop turn and keeps one accepted result" do
    # Production had 98 correction events across 41 recent episodes; the host
    # must return useful violations without starting another model session.
    claim = claim_episode!("same-turn-repair")

    {:ok, fake} =
      FakeAPI.start_link([
        silent("No reply is needed."),
        reply("I checked the request and here is the answer.")
      ])

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    assert execution.turn.delivery_document["message"] ==
             "I checked the request and here is the answer."

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             "explicit human request"
  end

  test "an unrenderable Slack result repairs in the same Coop turn before delivery custody" do
    claim = claim_episode!("slack-presentation-repair")

    refs =
      Enum.map(1..51, fn index ->
        assert {:ok, record} =
                 Records.create(
                   Records.token(claim.turn),
                   "presentation-progress-#{index}",
                   "progress",
                   %{
                     "next_due_at" => nil,
                     "phase" => "checking-#{index}",
                     "summary" => "Completed bounded check #{index}."
                   }
                 )

        record.ref
      end)

    {:ok, fake} =
      FakeAPI.start_link([
        reply_with_records("This result is too large for Slack.", refs),
        reply("The bounded result is ready.")
      ])

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert turn.delivery_document["message"] == "The bounded result is ready."

    state = FakeAPI.state(fake)
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    violation = state.validations |> hd() |> Map.fetch!(:violations) |> hd()
    assert violation =~ "cannot be rendered safely"
    assert violation =~ "invalid_slack_render"

    assert state.submit_count == 1
  end

  test "shadow execution repairs a visible answer and settles without delivery" do
    claim = claim_episode!("shadow-observe-only", nil, :shadow)

    {:ok, fake} =
      FakeAPI.start_link([
        reply("I would post this investigation result."),
        silent("Would retain the read-only assessment without posting.")
      ])

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.episode.execution_mode == :shadow
    assert execution.episode.state == :complete
    assert execution.turn.status == :settled
    assert execution.turn.delivery_ref == nil

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             "observe-only shadow"

    [submission] = state.submissions
    assert submission.prompt =~ ~s("execution_mode":"shadow")
  end

  test "an open required goal is corrected in the same turn instead of failing finalization" do
    # run_dab83e5b spent 43 finalization attempts because a required goal was
    # still open. The validator must give the model an actionable correction
    # before Coop accepts the result, while retaining the same logical turn.
    claim = claim_episode!("open-required-goal")
    token = Records.token(claim.turn)

    assert {:ok, _goal} =
             Records.create(token, "goal-check-workers", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "A current worker observation is recorded.",
               "id" => "check-workers",
               "kind" => "check",
               "requested_outcome" => "Check worker health",
               "required" => true
             })

    assert {:ok, question} =
             Records.create(token, "question-worker-signal", "input_request", %{
               "choices" => ["Provide metric source", "Stop"],
               "question" => "Which worker-health source should I inspect?"
             })

    waiting =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Which worker-health source should I inspect?",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [question.ref],
          "state" => "waiting_for_input"
        }
      })

    {:ok, fake} = FakeAPI.start_link([reply("Everything is complete."), waiting])

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert turn.delivery_document["outcome"]["state"] == "waiting_for_input"

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    violations = state.validations |> hd() |> Map.fetch!(:violations)
    assert Enum.any?(violations, &String.contains?(&1, "check-workers"))
    assert Enum.any?(violations, &String.contains?(&1, "update_goal"))
  end

  test "an omitted durable wait is repaired in the same Coop turn" do
    # A real model-world run created a wait and then returned complete without
    # its ref. Accepting that candidate completed the episode but left the wait
    # open forever, so retention could never discard the Coop workspace.
    claim = claim_episode!("omitted-durable-wait")

    assert {:ok, wait} =
             Records.create(Records.token(claim.turn), "verify-rollout", "event_wait", %{
               "deadline_at" => "2099-08-28T12:30:00.000000Z",
               "event_matcher" => %{"revision" => "99183465", "state" => "verification_due"},
               "kind" => "deployment_health",
               "verification" => "Verify Airflow revision 99183465."
             })

    waiting =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "I will verify revision 99183465 after the observation window.",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [wait.ref],
          "state" => "waiting_for_event"
        }
      })

    {:ok, fake} = FakeAPI.start_link([reply("The rollout is complete."), waiting])

    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, options(fake))
    assert turn.delivery_document["outcome"]["state"] == "waiting_for_event"
    assert turn.delivery_document["outcome"]["record_refs"] == [wait.ref]

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             "Open durable waits cannot be abandoned"
  end

  test "uncommitted engineering work is corrected and committed in the same Coop turn" do
    # A completion claim must not escape while intended repository changes are
    # still staged, unstaged, untracked, or conflicted. The correction belongs
    # to the same logical Coop turn so the workspace and accepted work survive.
    claim = claim_episode!("engineering-completion")
    token = Records.token(claim.turn)

    assert {:ok, _goal} =
             Records.create(token, "goal-engineering", "goal", %{
               "authority" => "repository_write",
               "completion_contract" => "The requested implementation is committed.",
               "id" => "implement-feature",
               "kind" => "engineering",
               "requested_outcome" => "Implement the requested feature",
               "required" => true,
               "writable_repository" => "responder"
             })

    assert {:ok, _goal_state} =
             Records.create(token, "goal-engineering-complete", "goal_state", %{
               "detail" => "Implementation completed in the workspace.",
               "goal_id" => "implement-feature",
               "state" => "completed"
             })

    dirty = workspace_changes(staged: [%{"path" => "lib/feature.ex", "status" => "modified"}])

    committed =
      workspace_changes(
        committed: [%{"path" => "lib/feature.ex", "status" => "modified"}],
        fork_head: "commit-feature",
        fork_tree: "tree-feature"
      )

    {:ok, fake} =
      FakeAPI.start_link(
        [reply("The implementation is complete."), reply("The implementation is committed.")],
        changes: [dirty, committed]
      )

    assert {:ok, %{status: :accepted}} = Executor.run(claim, options(fake))

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert state.changes_count == 2
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~ "uncommitted"
  end

  test "malformed workspace evidence cannot authorize an engineering completion" do
    invalid_changes = [
      :invalid,
      workspace_changes(base_commit: nil),
      workspace_changes(fork_head: <<0>>),
      workspace_changes(fork_tree: String.duplicate("x", 257)),
      workspace_changes(pull_request_tree: 42),
      workspace_changes(committed: :invalid),
      workspace_changes(staged: :invalid),
      workspace_changes(unstaged: :invalid),
      workspace_changes(untracked: :invalid),
      workspace_changes(conflicts: :invalid)
    ]

    for {changes, index} <- Enum.with_index(invalid_changes, 1) do
      claim = claim_episode!("malformed-workspace-#{index}")
      token = Records.token(claim.turn)

      assert {:ok, _goal} =
               Records.create(token, "goal-malformed-workspace-#{index}", "goal", %{
                 "authority" => "repository_write",
                 "completion_contract" => "The requested implementation is committed.",
                 "id" => "implement-feature-#{index}",
                 "kind" => "engineering",
                 "requested_outcome" => "Implement the requested feature",
                 "required" => true,
                 "writable_repository" => "responder"
               })

      {:ok, fake} =
        FakeAPI.start_link([reply("The implementation is complete.")], changes: [changes])

      FakeAPI.update(fake, fn state ->
        %{state | session: %{state.session | "id" => "remote_work_malformed_#{index}"}}
      end)

      assert Executor.run(claim, options(fake)) ==
               {:error, {:coop_protocol_error, :workspace_changes}}

      state = FakeAPI.state(fake)
      assert state.submit_count == 1
      assert state.validations == []
    end
  end

  test "one logical completion cannot combine different writable repositories" do
    claim = claim_episode!("repository-goal-conflict")
    token = Records.token(claim.turn)

    Enum.each([{"api", "responder"}, {"worker", "coop"}], fn {goal_id, repository} ->
      assert {:ok, _goal} =
               Records.create(token, "goal-#{goal_id}", "goal", %{
                 "authority" => "repository_write",
                 "completion_contract" => "The requested implementation is committed.",
                 "id" => goal_id,
                 "kind" => "engineering",
                 "requested_outcome" => "Implement #{goal_id}",
                 "required" => true,
                 "writable_repository" => repository
               })

      assert {:ok, _state} =
               Records.create(token, "goal-state-#{goal_id}", "goal_state", %{
                 "detail" => "Implementation completed in the workspace.",
                 "goal_id" => goal_id,
                 "state" => "completed"
               })
    end)

    {:ok, fake} =
      FakeAPI.start_link([reply("Both repository changes are complete.")],
        changes: [workspace_changes(committed: [%{"path" => "lib/change.ex"}])]
      )

    assert Executor.run(claim, options(fake)) ==
             {:error, {:invalid_work_state, :repository_write_goals}}

    assert FakeAPI.state(fake).validations == []
  end

  test "a lost validation response reconciles the exact candidate without another model turn" do
    claim = claim_episode!("validation-response-loss")

    {:ok, fake} =
      FakeAPI.start_link([reply("This answer survives the lost response.")],
        lose_first_validation_response: true
      )

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.turn.validation_receipt != nil

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert length(state.validation_keys) == 1
    assert state.operation_calls[hd(state.validation_keys)] >= 1
  end

  test "a lost submit response reconciles one remote turn from the frozen submission" do
    claim = claim_episode!("submit-response-loss")

    {:ok, fake} =
      FakeAPI.start_link([reply("The original turn was recovered.")],
        lose_first_submit_response: true
      )

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert length(Enum.uniq(state.turn_keys)) == 1
    assert state.operation_calls[hd(state.turn_keys)] >= 1
  end

  test "only the exact recoverable cleanup failure spends validation identity" do
    candidate = reply("Validation cleanup can be retried safely.")
    candidate_sha256 = digest(candidate)

    retry_claim = claim_episode!("validation-cleanup-retry")
    {:ok, retry_fake} = FakeAPI.start_link([candidate])

    retry_key =
      "responder:work:validate:#{retry_claim.turn.id}:a1:g1:#{candidate_sha256}:accept"

    FakeAPI.seed_operation(
      retry_fake,
      retry_key,
      failed_operation("session_cleanup_error", "ValidateTurnCandidate")
    )

    assert {:error,
            {:work_generation_spent, :validation,
             {:coop_operation_failed, "session_cleanup_error", _detail}}} =
             Executor.run(retry_claim, options(retry_fake))

    retried = Responder.Repo.get!(Responder.Work.Turn, retry_claim.turn.id)
    assert retried.validation_generation == 2

    blocked_claim = claim_episode!("validation-invalid-blocked")
    {:ok, blocked_fake} = FakeAPI.start_link([candidate])
    FakeAPI.seed_turn(blocked_fake, "remote_work_blocked", "unused", "running")

    blocked_key =
      "responder:work:validate:#{blocked_claim.turn.id}:a1:g1:#{candidate_sha256}:accept"

    failure = failed_operation("invalid_request", "ValidateTurnCandidate")
    FakeAPI.seed_operation(blocked_fake, blocked_key, failure)

    assert {:error,
            {:work_execution_blocked, {:coop_operation_failed, "invalid_request", _detail}}} =
             Executor.run(blocked_claim, options(blocked_fake))

    blocked = Responder.Repo.get!(Responder.Work.Turn, blocked_claim.turn.id)
    assert blocked.validation_generation == 1
  end

  test "a lost Coop cancel response is proven from the remote turn before the episode stops" do
    work = bound_turn!("cancel-response-loss")

    {:ok, fake} =
      fake_for(work, [], lose_first_cancel_response: true)

    FakeAPI.seed_turn(
      fake,
      work.session.coop_session_id,
      work.turn.coop_turn_id,
      "running"
    )

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:#{work.turn.id}",
               "Stopped by the operator."
             )

    assert requested.status == :pending
    assert {:ok, claim} = Custody.claim_next("worker:cancel-runtime", 60)

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled
    assert execution.turn.status == :superseded

    state = FakeAPI.state(fake)
    assert length(state.cancel_keys) == 1
    assert state.lost_cancel_response
    assert state.turn["state"] == "cancelled"
  end

  test "stop reconciles an admitted submit whose turn response was lost" do
    work = claim_with_bound_session!("cancel-lost-submit-binding")
    {:ok, fake} = fake_for(work, [])
    remote_turn_id = "remote-turn:lost-submit:#{work.turn.id}"

    assert {:ok, turn} =
             Custody.renew(work.episode.id, work.turn.turn_ref, work.lease_ref, 60)

    work = %{work | turn: turn}

    assert :ok =
             prepare_remote_operation(work, :submit_turn, turn_key(work), 1, fn ->
               FakeAPI.seed_operation(
                 fake,
                 turn_key(work),
                 succeeded_operation("SubmitTurn", "turn", remote_turn_id)
               )

               FakeAPI.seed_turn(fake, work.session.coop_session_id, remote_turn_id, "running")
               :ok
             end)

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:lost-submit:#{work.turn.id}",
               "Stopped while the submit response was unresolved."
             )

    assert requested.status == :pending
    assert requested.turn.status == :cancel_pending
    assert requested.turn.coop_turn_id == nil
    assert requested.turn.next_attempt_at == nil

    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-lost-submit", 60, :work)
    assert cancel_claim.turn.coop_turn_id == nil

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled
    assert execution.turn.coop_turn_id == remote_turn_id
    assert FakeAPI.state(fake).turn["state"] == "cancelled"
  end

  test "stop fences a frozen submit without creating work after authority was revoked" do
    work = claim_with_bound_session!("cancel-submit-before-operation-journal")
    {:ok, fake} = fake_for(work, [reply("This turn must be cancelled, not delivered.")])
    key = turn_key(work)

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :submit_turn,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: 1
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:pre-journal-submit:#{work.turn.id}",
               "Stop while Coop may still admit the frozen submit."
             )

    assert requested.turn.remote_operation_kind == "submit_turn"
    assert requested.turn.remote_operation_revision == 1
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-pre-journal-submit", 60)

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled

    state = FakeAPI.state(fake)
    assert state.submit_count == 0
    assert state.submissions == []
    assert state.fence_submit_keys == [key]
    assert state.turn == nil
  end

  test "stop fences a frozen create without creating a session after authority was revoked" do
    work = claim_episode!("cancel-create-before-operation-journal")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :create_session,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: nil
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:pre-journal-create:#{work.turn.id}",
               "Stop while Coop may still admit the frozen create."
             )

    assert requested.turn.remote_operation_kind == "create_session"
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-pre-journal-create", 60)

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled

    state = FakeAPI.state(fake)
    assert state.create_count == 0
    assert state.create_keys == []
    assert state.fence_create_keys == [key]
  end

  test "stop fences the exact create instead of trusting a present hashless lookup" do
    work = claim_episode!("cancel-create-fence-conflict")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)
    remote_session_id = FakeAPI.state(fake).session["id"]

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :create_session,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: nil
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:create-fence-conflict:#{work.turn.id}",
               "Stop must not adopt another create request that reused this key."
             )

    assert {:ok, cancel_claim} = Custody.claim_next("worker:create-fence-conflict", 60)

    wrong_operation =
      succeeded_operation("CreateRemoteSession", "session", remote_session_id)

    FakeAPI.seed_operation(fake, key, wrong_operation)

    overrides = %{
      fence_create_session:
        {:error, {:coop_error, 409, "idempotency_conflict", "the key belongs to another body"}}
    }

    assert {:error,
            {:work_cancellation_unresolved,
             {:fence_idempotency_conflict, {:coop_error, 409, "idempotency_conflict", _detail}}}} =
             Executor.run(cancel_claim, protocol_options(fake, overrides))

    assert Map.get(FakeAPI.state(fake).operation_calls, key, 0) == 0
    assert FakeAPI.state(fake).session["state"] == "open"
  end

  test "stop never trusts a hashless lookup after a lost submit fence response" do
    work = claim_with_bound_session!("cancel-submit-fence-conflict")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = turn_key(work)
    wrong_turn_id = "remote-turn:wrong-body:#{work.turn.id}"

    FakeAPI.seed_turn(fake, work.session.coop_session_id, wrong_turn_id, "running")

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :submit_turn,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: 1
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:submit-fence-conflict:#{work.turn.id}",
               "Stop must not adopt another submit request that reused this key."
             )

    assert {:ok, cancel_claim} = Custody.claim_next("worker:submit-fence-conflict", 60)
    {:ok, lookup_count} = Agent.start_link(fn -> 0 end)

    wrong_operation = succeeded_operation("SubmitTurn", "turn", wrong_turn_id)

    overrides = %{
      fence_submit_turn: {:error, {:coop_unavailable, :simulated_fence_response_loss}},
      operation_by_key: first_not_found_then(lookup_count, wrong_operation)
    }

    assert {:error,
            {:work_cancellation_unresolved,
             {:turn_submit_fence, {:error, {:coop_unavailable, :simulated_fence_response_loss}}}}} =
             Executor.run(cancel_claim, protocol_options(fake, overrides))

    assert Agent.get(lookup_count, & &1) == 0
    assert FakeAPI.state(fake).turn["state"] == "running"
    assert FakeAPI.state(fake).cancel_keys == []
  end

  test "stop reconciles a succeeded create journal before closing the proven session" do
    work = claim_episode!("cancel-succeeded-create-journal")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)

    assert {:ok, %{"operation" => operation, "session" => remote_session}} =
             prepare_remote_operation(work, :create_session, key, nil, fn ->
               FakeAPI.create_session(
                 fake,
                 key,
                 work.session.policy,
                 work.session.external_ref
               )
             end)

    assert operation["method"] == "CreateRemoteSession"
    assert remote_session["state"] == "open"

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:succeeded-create:#{work.turn.id}",
               "Stop after the create response was lost."
             )

    assert requested.turn.coop_turn_id == nil
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-succeeded-create", 60)
    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))

    assert execution.status == :cancelled
    assert execution.remote_session_id == remote_session["id"]
    assert execution.remote_turn_id == nil
    assert FakeAPI.state(fake).session["state"] == "closed"
  end

  test "stop distinguishes a failed create with no resource from an uncertain create" do
    failed = claim_episode!("cancel-failed-create-journal")
    {:ok, failed_fake} = fake_for(failed, [reply("unused")])

    assert :ok =
             prepare_remote_operation(failed, :create_session, create_key(failed), nil, fn ->
               FakeAPI.seed_operation(
                 failed_fake,
                 create_key(failed),
                 failed_operation("repository_unavailable", "CreateRemoteSession")
               )

               :ok
             end)

    assert {:ok, _requested} =
             Custody.request_cancel(
               failed.episode.id,
               failed.episode.key,
               failed.turn.turn_ref,
               "cancel:failed-create:#{failed.turn.id}",
               "Stop after Coop proved no session was created."
             )

    assert {:ok, failed_claim} = Custody.claim_next("worker:cancel-failed-create", 60)
    assert {:ok, failed_execution} = Executor.run(failed_claim, options(failed_fake))
    assert failed_execution.status == :cancelled
    assert failed_execution.remote_session_id == nil
    assert failed_execution.remote_turn_id == nil
    assert FakeAPI.state(failed_fake).create_count == 0

    uncertain = claim_episode!("cancel-uncertain-create-journal")
    {:ok, uncertain_fake} = fake_for(uncertain, [reply("unused")])
    uncertainty = uncertain_operation("operation_uncertain", "CreateRemoteSession")

    assert :ok =
             prepare_remote_operation(
               uncertain,
               :create_session,
               create_key(uncertain),
               nil,
               fn ->
                 FakeAPI.seed_operation(uncertain_fake, create_key(uncertain), uncertainty)
                 :ok
               end
             )

    assert {:ok, _requested} =
             Custody.request_cancel(
               uncertain.episode.id,
               uncertain.episode.key,
               uncertain.turn.turn_ref,
               "cancel:uncertain-create:#{uncertain.turn.id}",
               "Keep custody until Coop proves the create outcome."
             )

    assert {:ok, uncertain_claim} = Custody.claim_next("worker:cancel-uncertain-create", 60)

    assert Executor.run(uncertain_claim, options(uncertain_fake)) ==
             {:error,
              {:work_cancellation_unresolved,
               {:coop_operation_uncertain, "operation_uncertain", "simulated operation_uncertain"}}}
  end

  test "confirmed, uncertain, and still-running session creation have distinct custody" do
    failed_claim = claim_episode!("create-failed")
    {:ok, failed_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      failed_fake,
      create_key(failed_claim),
      failed_operation("no_capacity", "CreateRemoteSession")
    )

    assert {:error,
            {:work_generation_spent, :session_create,
             {:coop_operation_failed, "no_capacity", _detail}}} =
             Executor.run(failed_claim, options(failed_fake))

    assert Responder.Repo.get!(Responder.Work.Session, failed_claim.session.id).create_generation ==
             2

    uncertain_claim = claim_episode!("create-uncertain")
    {:ok, uncertain_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      uncertain_fake,
      create_key(uncertain_claim),
      uncertain_operation("operation_uncertain", "CreateRemoteSession")
    )

    assert {:error,
            {:work_execution_blocked, {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(uncertain_claim, options(uncertain_fake))

    running_claim = claim_episode!("create-running")
    {:ok, running_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      running_fake,
      create_key(running_claim),
      running_operation("CreateRemoteSession")
    )

    assert Executor.run(running_claim, Keyword.put(options(running_fake), :max_polls, 1)) ==
             {:error, {:work_poll_window_elapsed, :operation}}
  end

  test "a new logical turn rotates an exhausted Coop session before freezing its briefing" do
    claim = claim_with_bound_empty_session!("exhausted-session-rotation")
    {:ok, fake} = fake_for(claim, [reply("The replacement session completed the work.")])

    FakeAPI.update(fake, fn state ->
      %{state | session: Map.put(state.session, "state", "exhausted")}
    end)

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    sessions =
      Responder.Repo.all(
        from(session in Responder.Work.Session,
          where: session.episode_id == ^claim.episode.id,
          order_by: [asc: session.generation]
        )
      )

    assert Enum.map(sessions, & &1.generation) == [1, 2]
    assert List.last(sessions).coop_session_id =~ ":replacement:1"

    persisted_turn = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted_turn.session_id == List.last(sessions).id
    assert persisted_turn.submission["context"]["mode"] == "full"
  end

  test "a new repository session waits for freshness v2 before remote creation" do
    claim = claim_episode!("new-session-capability-wait")

    session =
      claim.session
      |> Ecto.Changeset.change(repository_ref: "responder")
      |> Repo.update!()

    claim = %{claim | session: session}
    {:ok, fake} = fake_for(claim, [reply("Run only with current repository evidence.")])

    incompatible =
      protocol_options(fake, %{
        session_capabilities: {:error, {:coop_error, 404, "not_found", "resource not found"}}
      })

    assert Executor.run(claim, incompatible) ==
             {:error, {:coop_upgrade_required, :repository_freshness_v2}}

    assert FakeAPI.state(fake).create_count == 0
    assert FakeAPI.state(fake).submit_count == 0

    malformed =
      protocol_options(fake, %{
        session_capabilities: {:ok, %{"repository_freshness_receipt_versions" => [2, 2]}}
      })

    assert Executor.run(claim, malformed) ==
             {:error, {:coop_upgrade_required, :repository_freshness_v2}}

    assert FakeAPI.state(fake).create_count == 0

    assert {:ok, %{status: :accepted}} = Executor.run(claim, protocol_options(fake, %{}))
    assert FakeAPI.state(fake).create_count == 1
    assert FakeAPI.state(fake).submit_count == 1
  end

  test "a new logical turn replaces an open legacy session before freezing freshness" do
    claim = claim_with_bound_empty_session!("legacy-session-rotation")
    {:ok, fake} = fake_for(claim, [reply("The replacement session has current evidence.")])

    current_session = FakeAPI.state(fake).session
    replacement_id = current_session["id"] <> ":fresh"

    FakeAPI.update(fake, fn state ->
      legacy =
        state.session
        |> Map.put("repository_freshness", [])
        |> Map.put("repository_freshness_status", "unavailable")

      %{state | session: legacy}
    end)

    create_session = fn fallback ->
      FakeAPI.update(fake, fn state ->
        fresh =
          current_session
          |> Map.put("external_ref", state.session["external_ref"])
          |> Map.put("id", replacement_id)

        %{state | session: fresh}
      end)

      fallback.()
    end

    assert {:ok, %{status: :accepted, turn: accepted}} =
             Executor.run(claim, protocol_options(fake, %{create_session: create_session}))

    sessions =
      Repo.all(
        from(session in Responder.Work.Session,
          where: session.episode_id == ^claim.episode.id,
          order_by: [asc: session.generation]
        )
      )

    assert Enum.map(sessions, & &1.generation) == [1, 2]
    assert List.last(sessions).coop_session_id == replacement_id

    assert get_in(accepted.submission, ["context", "workspace", "freshness", "status"]) ==
             "recorded"

    assert FakeAPI.state(fake).submit_count == 1
  end

  test "a legacy session waits in place until Coop advertises freshness v2" do
    claim = claim_with_bound_empty_session!("legacy-session-capability-wait")
    {:ok, fake} = fake_for(claim, [reply("Must not run on v1.")])

    FakeAPI.update(fake, fn state ->
      legacy = %{
        state.session
        | "repository_freshness" => [
            state.session["repository_freshness"]
            |> hd()
            |> Map.put("version", 1)
            |> Map.delete("workspace_base_revision")
          ]
      }

      %{state | session: legacy}
    end)

    options =
      protocol_options(fake, %{
        capabilities: {:error, {:coop_error, 404, "not_found", "resource not found"}}
      })

    for _attempt <- 1..2 do
      assert Executor.run(claim, options) ==
               {:error, {:coop_upgrade_required, :repository_freshness_v2}}
    end

    sessions =
      Repo.all(
        from(session in Responder.Work.Session, where: session.episode_id == ^claim.episode.id)
      )

    assert Enum.map(sessions, & &1.generation) == [1]
    assert FakeAPI.state(fake).create_count == 0
    assert FakeAPI.state(fake).submit_count == 0
  end

  test "an upgraded fleet placement rotates one legacy session exactly once" do
    claim = claim_with_bound_empty_session!("legacy-fleet-capability-upgrade")
    {:ok, fake} = fake_for(claim, [reply("The upgraded fleet session is current.")])
    {:ok, upgraded?} = Agent.start_link(fn -> false end)

    current_session = FakeAPI.state(fake).session
    replacement_id = current_session["id"] <> ":fleet-v2"

    FakeAPI.update(fake, fn state ->
      legacy = %{
        state.session
        | "repository_freshness" => [
            state.session["repository_freshness"]
            |> hd()
            |> Map.put("version", 1)
            |> Map.delete("workspace_base_revision")
          ]
      }

      %{state | session: legacy}
    end)

    session_capabilities = fn session ->
      send(self(), {:freshness_capability_session, session.id})

      versions = if Agent.get(upgraded?, & &1), do: [2], else: []
      {:ok, %{"repository_freshness_receipt_versions" => versions}}
    end

    create_session = fn fallback ->
      FakeAPI.update(fake, fn state ->
        fresh =
          current_session
          |> Map.put("external_ref", state.session["external_ref"])
          |> Map.put("id", replacement_id)

        %{state | session: fresh}
      end)

      fallback.()
    end

    options =
      protocol_options(fake, %{
        create_session: create_session,
        session_capabilities: session_capabilities
      })

    assert Executor.run(claim, options) ==
             {:error, {:coop_upgrade_required, :repository_freshness_v2}}

    assert_receive {:freshness_capability_session, session_id}
    assert session_id == claim.session.id

    Agent.update(upgraded?, fn _current -> true end)

    assert {:ok, %{status: :accepted}} = Executor.run(claim, options)

    sessions =
      Repo.all(
        from(session in Responder.Work.Session,
          where: session.episode_id == ^claim.episode.id,
          order_by: [asc: session.generation]
        )
      )

    assert Enum.map(sessions, & &1.generation) == [1, 2]
    assert List.last(sessions).coop_session_id == replacement_id
    assert FakeAPI.state(fake).create_count == 1
    assert FakeAPI.state(fake).submit_count == 1
  end

  test "a lost fleet placement rotates the immutable Work session before reconstruction" do
    claim = claim_with_bound_empty_session!("fleet-placement-rotation")
    candidate = reply("The reconstructed session completed the work.")

    assert {:ok, _turn} =
             Custody.record_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               FinalPreflight.candidate_sha256(Jason.decode!(candidate)),
               FinalPreflight.ledger_sha256(
                 claim.episode.id,
                 claim.episode.semantic_version,
                 []
               ),
               claim.episode.semantic_version
             )

    {:ok, fake} = fake_for(claim, [candidate])

    FakeAPI.update(fake, fn state ->
      %{state | session: Map.put(state.session, "state", "discarded")}
    end)

    replacement_error =
      {:error, {:coop_session_replacement_required, claim.session.id, claim.session.generation}}

    {:ok, replacement_seen} = Agent.start_link(fn -> false end)

    get_session = fn fallback ->
      first? = Agent.get_and_update(replacement_seen, &{not &1, true})
      if first?, do: replacement_error, else: fallback.()
    end

    client = %{
      fake: fake,
      overrides: %{get_session: get_session}
    }

    run_options =
      fake
      |> options()
      |> Keyword.merge(api: ProtocolAPI, client: client)
      |> Keyword.put(:state_tools_endpoint, "https://responder.example/v1/state-tools/mcp")
      |> Keyword.put(:state_tools_secret, "controller-state-tools-secret")

    assert {:ok, %{status: :accepted}} = Executor.run(claim, run_options)

    sessions =
      Repo.all(
        from(session in Responder.Work.Session,
          where: session.episode_id == ^claim.episode.id,
          order_by: [asc: session.generation]
        )
      )

    assert Enum.map(sessions, & &1.generation) == [1, 2]
    replacement = List.last(sessions)
    assert replacement.coop_session_id != claim.session.coop_session_id

    persisted_turn = Repo.get!(Responder.Work.Turn, claim.turn.id)

    assert {:ok, expected_binding} =
             StateBinding.derive(
               replacement,
               persisted_turn,
               StateBinding.local_scope(replacement),
               "https://responder.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    assert [submitted_binding] = FakeAPI.state(fake).bindings
    assert submitted_binding["token"] == expected_binding.token

    assert {:ok, stale_binding} =
             StateBinding.derive(
               claim.session,
               persisted_turn,
               StateBinding.local_scope(claim.session),
               "https://responder.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    refute stale_binding.token == expected_binding.token
  end

  test "a bound turn remains pollable after its immutable session becomes exhausted" do
    claim = bound_turn!("bound-turn-exhausted-session")
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      session = Map.put(state.session, "state", "exhausted")

      turn = %{
        "id" => claim.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => claim.session.coop_session_id,
        "state" => "running"
      }

      %{state | session: session, turn: turn}
    end)

    assert Executor.run(claim, Keyword.put(options(fake), :max_polls, 1)) ==
             {:error, {:work_poll_window_elapsed, :turn}}

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "remote session and turn resources must match their pinned local identity" do
    wrong_session = claim_with_bound_empty_session!("wrong-session-identity")
    {:ok, wrong_session_fake} = fake_for(wrong_session, [reply("unused")])

    change_session_id = fn fallback ->
      {:ok, session} = fallback.()
      {:ok, Map.put(session, "id", "remote:another-episode")}
    end

    assert Executor.run(
             wrong_session,
             protocol_options(wrong_session_fake, %{get_session: change_session_id})
           ) == {:error, {:coop_protocol_error, :session_identity}}

    wrong_authority = claim_with_bound_empty_session!("wrong-session-authority")
    {:ok, wrong_authority_fake} = fake_for(wrong_authority, [reply("unused")])

    change_policy_digest = fn fallback ->
      {:ok, session} = fallback.()
      {:ok, Map.put(session, "policy_digest", String.duplicate("f", 64))}
    end

    assert Executor.run(
             wrong_authority,
             protocol_options(wrong_authority_fake, %{get_session: change_policy_digest})
           ) == {:error, {:coop_protocol_error, :session_authority}}

    expected_authority = String.duplicate("d", 64)

    wrong_execution_authority =
      claim_with_bound_empty_session!("wrong-session-execution-authority", expected_authority)

    {:ok, wrong_execution_authority_fake} = fake_for(wrong_execution_authority, [reply("unused")])

    change_authority_digest = fn fallback ->
      {:ok, session} = fallback.()
      {:ok, Map.put(session, "authority_digest", String.duplicate("e", 64))}
    end

    assert Executor.run(
             wrong_execution_authority,
             protocol_options(wrong_execution_authority_fake, %{
               get_session: change_authority_digest
             })
           ) == {:error, {:coop_protocol_error, :session_authority}}

    wrong_turn_session = bound_turn!("wrong-turn-session")
    {:ok, wrong_turn_session_fake} = fake_for(wrong_turn_session, [])

    FakeAPI.seed_turn(
      wrong_turn_session_fake,
      wrong_turn_session.session.coop_session_id,
      wrong_turn_session.turn.coop_turn_id,
      "running"
    )

    change_turn_session = fn fallback ->
      {:ok, turn} = fallback.()
      {:ok, Map.put(turn, "session_id", "remote:another-session")}
    end

    assert Executor.run(
             wrong_turn_session,
             protocol_options(wrong_turn_session_fake, %{get_turn: change_turn_session})
           ) == {:error, {:coop_protocol_error, :turn_session_identity}}

    wrong_turn = bound_turn!("wrong-turn-identity")
    {:ok, wrong_turn_fake} = fake_for(wrong_turn, [])

    FakeAPI.seed_turn(
      wrong_turn_fake,
      wrong_turn.session.coop_session_id,
      wrong_turn.turn.coop_turn_id,
      "running"
    )

    change_turn_id = fn fallback ->
      {:ok, turn} = fallback.()
      {:ok, Map.put(turn, "id", "remote:another-turn")}
    end

    assert Executor.run(
             wrong_turn,
             protocol_options(wrong_turn_fake, %{get_turn: change_turn_id})
           ) == {:error, {:coop_protocol_error, :turn_identity}}

    wrong_binding = bound_turn!("wrong-turn-binding")

    assert {:ok, binding} =
             StateBinding.derive(
               wrong_binding.session,
               wrong_binding.turn,
               StateBinding.local_scope(wrong_binding.session),
               "https://responder.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    assert {:ok, bound_binding_turn} =
             Custody.bind_state_tools(
               wrong_binding.episode.id,
               wrong_binding.turn.turn_ref,
               wrong_binding.lease_ref,
               binding.endpoint,
               binding.token_sha256
             )

    wrong_binding = %{wrong_binding | turn: bound_binding_turn}
    {:ok, wrong_binding_fake} = fake_for(wrong_binding, [])

    FakeAPI.seed_turn(
      wrong_binding_fake,
      wrong_binding.session.coop_session_id,
      wrong_binding.turn.coop_turn_id,
      "running"
    )

    change_binding_digest = fn fallback ->
      {:ok, turn} = fallback.()
      {:ok, Map.put(turn, "responder_binding_digest", String.duplicate("f", 64))}
    end

    binding_options =
      wrong_binding_fake
      |> protocol_options(%{get_turn: change_binding_digest})
      |> Keyword.put(:state_tools_endpoint, binding.endpoint)
      |> Keyword.put(:state_tools_secret, "controller-state-tools-secret")

    assert Executor.run(wrong_binding, binding_options) ==
             {:error, {:coop_protocol_error, :turn_authority}}
  end

  test "an evaluation turn cannot start in a repository-writable Coop session" do
    claim = claim_with_bound_empty_session!("eval-session-must-be-read-only")
    {:ok, fake} = fake_for(claim, [reply("must not run")])

    FakeAPI.update(fake, fn state ->
      %{state | session: Map.put(state.session, "repository_read_only", false)}
    end)

    assert Executor.run(
             claim,
             Keyword.put(options(fake), :require_repository_read_only, true)
           ) == {:error, {:coop_protocol_error, :session_repository_write_authority}}

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "an evaluation turn cannot inherit Coop project environment or MCP authority" do
    for field <- ["project_env", "project_mcp"] do
      claim = claim_with_bound_empty_session!("eval-session-isolated-#{field}")
      {:ok, fake} = fake_for(claim, [reply("must not run")])

      FakeAPI.update(fake, fn state ->
        %{state | session: Map.put(state.session, field, true)}
      end)

      assert Executor.run(
               claim,
               Keyword.put(options(fake), :require_project_isolation, true)
             ) == {:error, {:coop_protocol_error, :session_project_authority}}

      assert FakeAPI.state(fake).submit_count == 0
    end
  end

  test "an evaluation freezes the exact trusted Coop workspace map before model submission" do
    claim =
      claim_with_bound_repository_context!(
        "eval-workspace-map",
        "responder",
        ["blitz-rivals-scraper"]
      )

    {:ok, fake} = fake_for(claim, [reply("The repository is available.")])

    companion = %{
      "base_commit" => "41af103a96d71c93887fe2b4dc9eed2d75f8fcb7",
      "name" => "blitz-rivals-scraper",
      "path" => "/coop/repositories/blitz-rivals-scraper"
    }

    freshness = [
      %{
        "fetched_at" => "2026-09-04T08:00:00Z",
        "name" => "primary",
        "remote_identity" => "origin",
        "requested_revision" => "refs/heads/main",
        "resolved_revision" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
        "stale_base_revision" => "31aa07bf02fa06445e4032980cfa6f66fd31290a",
        "stale_base_status" => "stale",
        "version" => 2,
        "workspace_base_revision" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f"
      },
      %{
        "fetched_at" => "2026-09-04T08:00:01Z",
        "name" => "blitz-rivals-scraper",
        "remote_identity" => "origin",
        "requested_revision" => "refs/heads/main",
        "resolved_revision" => "41af103a96d71c93887fe2b4dc9eed2d75f8fcb7",
        "stale_base_status" => "unknown",
        "version" => 2
      }
    ]

    FakeAPI.update(fake, fn state ->
      session =
        state.session
        |> Map.put("base_commit", "5d1fa43d2efe46e8409dde0e93e79af93fb6622f")
        |> Map.put("companions", [companion])
        |> Map.put("repository_freshness", freshness)
        |> Map.put("repository_freshness_status", "recorded")

      %{state | session: session}
    end)

    run_options =
      options(fake)
      |> Keyword.put(:require_project_isolation, true)
      |> Keyword.put(:require_repository_read_only, true)
      |> Keyword.put(:workspace_requirements, [
        Map.take(companion, ["base_commit", "name"])
      ])

    assert {:ok, %{status: :accepted, turn: accepted}} = Executor.run(claim, run_options)

    assert get_in(accepted.submission, ["context", "workspace"]) == %{
             "companions" => [Map.put(companion, "read_only", true)],
             "context_ref" => "platform",
             "freshness" => %{
               "owner" => "coop",
               "repositories" => [
                 Enum.at(freshness, 0),
                 freshness
                 |> Enum.at(1)
                 |> Map.put("stale_base_revision", nil)
                 |> Map.put("workspace_base_revision", nil)
               ],
               "status" => "recorded"
             },
             "parallel_goal_limit" => 2,
             "primary" => %{
               "base_commit" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
               "name" => "responder",
               "path" => ".",
               "read_only" => true
             }
           }

    assert accepted.submission_fingerprint ==
             Responder.CanonicalJSON.digest(accepted.submission)

    missing = claim_with_bound_empty_session!("eval-workspace-map-missing")
    {:ok, missing_fake} = fake_for(missing, [reply("Must not run.")])

    assert Executor.run(
             missing,
             options(missing_fake)
             |> Keyword.put(:workspace_requirements, [
               Map.take(companion, ["base_commit", "name"])
             ])
           ) == {:error, {:coop_protocol_error, :session_workspace}}

    assert FakeAPI.state(missing_fake).submit_count == 0

    context_missing =
      claim_with_bound_repository_context!(
        "eval-repository-context-missing",
        "responder",
        ["blitz-rivals-scraper"]
      )

    {:ok, context_missing_fake} =
      fake_for(context_missing, [reply("Must not run without the frozen companion.")])

    assert Executor.run(context_missing, options(context_missing_fake)) ==
             {:error, {:coop_protocol_error, :repository_context}}

    assert FakeAPI.state(context_missing_fake).submit_count == 0
  end

  test "a Coop session without owner-issued repository freshness never reaches the model" do
    claim = claim_with_bound_empty_session!("legacy-workspace-freshness")
    {:ok, fake} = fake_for(claim, [reply("Must not run.")])

    FakeAPI.update(fake, fn state ->
      %{
        state
        | session:
            Map.drop(state.session, ["repository_freshness", "repository_freshness_status"])
      }
    end)

    assert Executor.run(claim, options(fake)) ==
             {:error, {:coop_protocol_error, :repository_freshness}}

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "freshness correlation is keyed and distinguishes a PR merge base from its base head" do
    claim = claim_with_bound_empty_session!("pr-workspace-freshness")
    {:ok, fake} = fake_for(claim, [reply("The repositories are pinned.")])

    merge_base = String.duplicate("1", 40)
    base_head = String.duplicate("2", 40)
    pull_head = String.duplicate("3", 40)
    alpha_head = String.duplicate("4", 40)
    zulu_head = String.duplicate("5", 40)

    companions = [
      %{"base_commit" => zulu_head, "name" => "zulu", "path" => "/coop/repositories/zulu"},
      %{"base_commit" => alpha_head, "name" => "alpha", "path" => "/coop/repositories/alpha"}
    ]

    receipt = fn name, resolved, workspace_base ->
      %{
        "fetched_at" => "2026-09-04T08:00:00Z",
        "name" => name,
        "remote_identity" => "origin",
        "requested_revision" => "refs/heads/main",
        "resolved_revision" => resolved,
        "stale_base_status" => "unknown",
        "version" => 2
      }
      |> then(fn value ->
        if workspace_base,
          do: Map.put(value, "workspace_base_revision", workspace_base),
          else: value
      end)
    end

    freshness = [
      receipt.("primary", base_head, merge_base),
      receipt.("zulu", zulu_head, nil),
      receipt.("alpha", alpha_head, nil),
      receipt.("pull_request", pull_head, nil)
    ]

    FakeAPI.update(fake, fn state ->
      session =
        state.session
        |> Map.put("base_commit", merge_base)
        |> Map.put("companions", companions)
        |> Map.put("pull_request", %{
          "head_commit" => pull_head,
          "number" => 91,
          "ref" => "refs/pull/91/head"
        })
        |> Map.put("repository_freshness", freshness)

      %{state | session: session}
    end)

    assert {:ok, %{status: :accepted, turn: accepted}} = Executor.run(claim, options(fake))
    workspace = get_in(accepted.submission, ["context", "workspace"])
    assert Enum.map(workspace["companions"], & &1["name"]) == ["alpha", "zulu"]

    assert workspace["freshness"]["repositories"] ==
             Enum.map(freshness, fn item ->
               item
               |> Map.put_new("stale_base_revision", nil)
               |> Map.put_new("workspace_base_revision", nil)
             end)
  end

  test "a submit revision conflict spends only the submit generation" do
    claim = claim_with_bound_session!("submit-conflict")
    {:ok, fake} = fake_for(claim, [reply("unused")])

    FakeAPI.seed_operation(
      fake,
      turn_key(claim),
      failed_operation("revision_conflict", "SubmitTurn")
    )

    assert {:error,
            {:work_generation_spent, :turn_submit,
             {:coop_operation_failed, "revision_conflict", _detail}}} =
             Executor.run(claim, options(fake))

    reloaded = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert reloaded.submit_generation == 2
    assert reloaded.coop_turn_id == nil
    assert reloaded.submission == claim.turn.submission
  end

  test "terminal and unknown remote turn states are never silently replayed" do
    Enum.each(~w(failed interrupted budget_exhausted cancelled), fn state ->
      work = bound_turn!("terminal-#{state}")
      {:ok, fake} = fake_for(work, [])
      FakeAPI.seed_turn(fake, work.session.coop_session_id, work.turn.coop_turn_id, state)

      assert {:error, {:work_turn_terminal, ^state, nil, nil}} =
               Executor.run(work, options(fake))

      assert FakeAPI.state(fake).submit_count == 0
    end)

    unknown = bound_turn!("unknown-state")
    {:ok, fake} = fake_for(unknown, [])
    FakeAPI.seed_turn(fake, unknown.session.coop_session_id, unknown.turn.coop_turn_id, "paused")

    assert Executor.run(unknown, options(fake)) ==
             {:error, {:coop_protocol_error, :turn_state}}
  end

  test "a queued remote turn has a bounded wait and renews a long-lived local lease" do
    work = bound_turn!("queued-timeout")
    {:ok, fake} = fake_for(work, [])
    FakeAPI.seed_turn(fake, work.session.coop_session_id, work.turn.coop_turn_id, "queued")

    counter = start_supervised!({Agent, fn -> 0 end})

    monotonic = fn -> Agent.get_and_update(counter, fn value -> {value, value + 25_000} end) end

    assert Executor.run(
             work,
             options(fake)
             |> Keyword.put(:lease_seconds, 60)
             |> Keyword.put(:max_polls, 1)
             |> Keyword.put(:monotonic_ms, monotonic)
           ) == {:error, {:work_poll_window_elapsed, :turn}}

    reloaded = Responder.Repo.get!(Responder.Work.Turn, work.turn.id)
    assert reloaded.lease_ref == work.lease_ref
    assert DateTime.compare(reloaded.lease_expires_at, work.turn.lease_expires_at) in [:gt, :eq]
  end

  test "malformed candidate and completed receipts stop at the Coop protocol boundary" do
    malformed = bound_turn!("malformed-candidate")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.update(malformed_fake, fn state ->
      turn = %{
        "candidate" => %{
          "attempt" => 1,
          "message" => reply("Wrong digest."),
          "sha256" => String.duplicate("0", 64)
        },
        "id" => malformed.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => malformed.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert Executor.run(malformed, options(malformed_fake)) ==
             {:error, {:coop_protocol_error, :candidate_digest}}

    completed = accepted_intent_turn!("missing-receipt")
    {:ok, completed_fake} = fake_for(completed, [])

    FakeAPI.update(completed_fake, fn state ->
      turn = %{
        "assistant_message" => completed.turn.candidate,
        "id" => completed.turn.coop_turn_id,
        "revision" => 2,
        "session_id" => completed.session.coop_session_id,
        "state" => "completed",
        "validation_attempt" => completed.turn.candidate_attempt,
        "validation_candidate_sha256" => completed.turn.candidate_sha256
      }

      %{state | turn: turn}
    end)

    assert Executor.run(completed, options(completed_fake)) ==
             {:error, {:coop_protocol_error, :validation_receipt}}
  end

  test "a completed receipt belongs to the exact staged candidate attempt" do
    claim = accepted_intent_turn!("stale-completed-attempt", 2)
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      completed = %{
        "assistant_message" => claim.turn.candidate,
        "id" => claim.turn.coop_turn_id,
        "session_id" => claim.session.coop_session_id,
        "state" => "completed",
        "validation_attempt" => 1,
        "validation_candidate_sha256" => claim.turn.candidate_sha256,
        "validation_receipt" => "validation:stale-attempt"
      }

      %{state | turn: completed}
    end)

    assert Executor.run(claim, options(fake)) ==
             {:error, {:coop_protocol_error, :validation_attempt}}

    persisted = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted.status == :pending
    assert persisted.result_ref == nil
  end

  test "invalid validation context fails locally before Coop is mutated" do
    Enum.each(
      [fn _claim -> :invalid end, fn _claim -> {:error, :context_unavailable} end],
      fn validation_context ->
        claim = claim_episode!("bad-context-#{System.unique_integer([:positive])}")
        {:ok, fake} = FakeAPI.start_link([reply("Must not be validated.")])

        FakeAPI.update(fake, fn state ->
          %{state | session: %{state.session | "id" => "remote:#{claim.episode.id}"}}
        end)

        expected =
          if validation_context.(claim) == :invalid,
            do: {:error, {:invalid_work_executor, :validation_context}},
            else: {:error, :context_unavailable}

        assert Executor.run(
                 claim,
                 Keyword.put(options(fake), :validation_context, validation_context)
               ) == expected

        assert FakeAPI.state(fake).validations == []
      end
    )
  end

  test "remote cancellation failure, uncertainty, and preexisting terminal state are explicit" do
    terminal = cancel_claim!("already-terminal", "completed")
    {:ok, terminal_fake} = fake_for(terminal, [])

    FakeAPI.seed_turn(
      terminal_fake,
      terminal.session.coop_session_id,
      terminal.turn.coop_turn_id,
      "completed"
    )

    assert {:ok, %{status: :cancelled}} = Executor.run(terminal, options(terminal_fake))
    assert FakeAPI.state(terminal_fake).cancel_keys == []

    failed = cancel_claim!("cancel-failed", "running")
    {:ok, failed_fake} = fake_for(failed, [])
    FakeAPI.seed_turn(failed_fake, failed.session.coop_session_id, failed.turn.coop_turn_id)

    FakeAPI.seed_operation(
      failed_fake,
      Cancellation.operation_key(failed.turn.id, 1),
      failed_operation("revision_conflict", "CancelTurn")
    )

    assert {:error,
            {:work_generation_spent, :cancellation,
             {:coop_operation_failed, "revision_conflict", _detail}}} =
             Executor.run(failed, options(failed_fake))

    unresolved = cancel_claim!("cancel-uncertain", "running")
    {:ok, unresolved_fake} = fake_for(unresolved, [])

    FakeAPI.seed_turn(
      unresolved_fake,
      unresolved.session.coop_session_id,
      unresolved.turn.coop_turn_id
    )

    FakeAPI.seed_operation(
      unresolved_fake,
      Cancellation.operation_key(unresolved.turn.id, 1),
      uncertain_operation("operation_uncertain", "CancelTurn")
    )

    assert {:error,
            {:work_cancellation_unresolved,
             {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(unresolved, options(unresolved_fake))
  end

  test "successful operation journals recover session and turn resources" do
    session_claim = claim_episode!("journal-session")
    {:ok, session_fake} = fake_for(session_claim, [reply("Recovered session operation.")])

    FakeAPI.seed_operation(
      session_fake,
      create_key(session_claim),
      succeeded_operation(
        "CreateRemoteSession",
        "session",
        "remote:#{session_claim.episode.id}"
      )
    )

    assert {:ok, %{status: :accepted}} = Executor.run(session_claim, options(session_fake))
    assert FakeAPI.state(session_fake).create_count == 0

    turn_claim = claim_with_bound_session!("journal-turn")
    {:ok, turn_fake} = fake_for(turn_claim, [reply("Recovered turn operation.")])

    strip_turn = fn fallback ->
      {:ok, %{"operation" => operation, "turn" => _turn}} = fallback.()
      {:ok, %{"operation" => operation}}
    end

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               turn_claim,
               protocol_options(turn_fake, %{submit_turn: strip_turn})
             )

    assert FakeAPI.state(turn_fake).submit_count == 1
  end

  test "a malformed successful mutation response reconciles the exact operation journal" do
    create_claim = claim_episode!("malformed-success-create")
    {:ok, create_fake} = fake_for(create_claim, [reply("Recovered malformed create response.")])

    malformed_after_commit = fn fallback ->
      _committed_response = fallback.()
      {:ok, %{"unexpected" => true}}
    end

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               create_claim,
               protocol_options(create_fake, %{create_session: malformed_after_commit})
             )

    submit_claim = claim_with_bound_session!("malformed-success-submit")
    {:ok, submit_fake} = fake_for(submit_claim, [reply("Recovered malformed submit response.")])

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               submit_claim,
               protocol_options(submit_fake, %{submit_turn: malformed_after_commit})
             )

    validation_claim = claim_episode!("malformed-success-validation")

    {:ok, validation_fake} =
      fake_for(validation_claim, [reply("Recovered malformed validation response.")])

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               validation_claim,
               protocol_options(validation_fake, %{validate_candidate: malformed_after_commit})
             )

    cancellation_claim = cancel_claim!("malformed-success-cancel", "running")
    {:ok, cancellation_fake} = fake_for(cancellation_claim, [])

    FakeAPI.seed_turn(
      cancellation_fake,
      cancellation_claim.session.coop_session_id,
      cancellation_claim.turn.coop_turn_id,
      "running"
    )

    assert {:ok, %{status: :cancelled}} =
             Executor.run(
               cancellation_claim,
               protocol_options(cancellation_fake, %{
                 cancel_turn: malformed_after_commit,
                 close_session: malformed_after_commit
               })
             )
  end

  test "malformed create, submit, and resource envelopes cannot enter durable custody" do
    create_claim = claim_episode!("bad-create-envelope")
    {:ok, create_fake} = fake_for(create_claim, [reply("unused")])

    assert Executor.run(
             create_claim,
             protocol_options(create_fake, %{create_session: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :create_session, :create_session_response}}

    revision_claim = claim_with_bound_session!("bad-session-revision")
    {:ok, revision_fake} = fake_for(revision_claim, [reply("unused")])

    assert Executor.run(
             revision_claim,
             protocol_options(revision_fake, %{
               get_session:
                 {:ok,
                  %{
                    "external_ref" => revision_claim.session.external_ref,
                    "id" => revision_claim.session.coop_session_id,
                    "policy" => revision_claim.session.policy,
                    "policy_digest" => revision_claim.session.policy_digest,
                    "state" => "open"
                  }}
             })
           ) == {:error, {:coop_protocol_error, :resource_revision}}

    submit_claim = claim_with_bound_session!("bad-submit-envelope")
    {:ok, submit_fake} = fake_for(submit_claim, [reply("unused")])

    assert Executor.run(
             submit_claim,
             protocol_options(submit_fake, %{submit_turn: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error, {:coop_mutation_response_unresolved, :submit_turn, :submit_turn_response}}

    turn_claim = claim_with_bound_session!("bad-turn-resource")
    {:ok, turn_fake} = fake_for(turn_claim, [reply("unused")])

    assert Executor.run(
             turn_claim,
             protocol_options(turn_fake, %{submit_turn: {:ok, %{"turn" => %{}}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :submit_turn,
               {:coop_protocol_error, :turn_resource}}}
  end

  test "direct validation cleanup and uncertainty reconcile the exact remote candidate" do
    cleanup_claim = claim_episode!("direct-cleanup")
    {:ok, cleanup_fake} = fake_for(cleanup_claim, [reply("Cleanup retry.")])

    cleanup_error =
      {:error, {:coop_error, 503, "session_cleanup_error", "cleanup unavailable"}}

    assert {:error,
            {:work_generation_spent, :validation,
             {:coop_error, 503, "session_cleanup_error", "cleanup unavailable"}}} =
             Executor.run(
               cleanup_claim,
               protocol_options(cleanup_fake, %{validate_candidate: cleanup_error})
             )

    uncertain_claim = claim_episode!("direct-validation-uncertain")
    {:ok, uncertain_fake} = fake_for(uncertain_claim, [reply("Uncertain validation.")])

    uncertain_error =
      {:error, {:coop_error, 409, "operation_uncertain", "outcome unknown"}}

    assert {:error,
            {:work_execution_blocked,
             {:coop_error, 409, "operation_uncertain", "outcome unknown"}}} =
             Executor.run(
               uncertain_claim,
               protocol_options(uncertain_fake, %{validate_candidate: uncertain_error})
             )

    malformed_claim = claim_episode!("bad-validation-envelope")
    {:ok, malformed_fake} = fake_for(malformed_claim, [reply("Malformed validation.")])

    assert Executor.run(
             malformed_claim,
             protocol_options(malformed_fake, %{
               validate_candidate: {:ok, %{"unexpected" => true}}
             })
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :validate_candidate, :validation_response}}
  end

  test "an uncertain reject that already resumed the turn keeps the same model turn alive" do
    claim = claim_episode!("uncertain-reject-resumed")

    {:ok, fake} =
      fake_for(claim, [
        silent("This invalid first candidate must be repaired."),
        reply("The repaired answer remains in the same logical turn.")
      ])

    uncertain_after_reject = fn fallback ->
      assert {:ok, %{"turn" => _next_candidate}} = fallback.()

      FakeAPI.update(fake, fn state ->
        %{state | turn: state.turn |> Map.put("candidate", nil) |> Map.put("state", "queued")}
      end)

      {:error, {:coop_error, 409, "operation_uncertain", "response lost after reject"}}
    end

    assert Executor.run(
             claim,
             protocol_options(fake, %{validate_candidate: uncertain_after_reject})
             |> Keyword.put(:max_polls, 1)
           ) == {:error, {:work_poll_window_elapsed, :turn}}

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject]
    assert state.turn["state"] == "queued"
  end

  test "direct cancellation conflicts and uncertain outcomes preserve remote custody" do
    conflict = cancel_claim!("direct-cancel-conflict", "running")
    {:ok, conflict_fake} = fake_for(conflict, [])
    FakeAPI.seed_turn(conflict_fake, conflict.session.coop_session_id, conflict.turn.coop_turn_id)

    conflict_error =
      {:error, {:coop_error, 409, "revision_conflict", "remote advanced"}}

    assert {:error,
            {:work_generation_spent, :cancellation,
             {:coop_error, 409, "revision_conflict", "remote advanced"}}} =
             Executor.run(
               conflict,
               protocol_options(conflict_fake, %{cancel_turn: conflict_error})
             )

    uncertain = cancel_claim!("direct-cancel-uncertain", "running")
    {:ok, uncertain_fake} = fake_for(uncertain, [])

    FakeAPI.seed_turn(
      uncertain_fake,
      uncertain.session.coop_session_id,
      uncertain.turn.coop_turn_id
    )

    uncertain_error =
      {:error, {:coop_error, 409, "operation_uncertain", "outcome unknown"}}

    assert {:error,
            {:work_cancellation_unresolved,
             {:coop_error, 409, "operation_uncertain", "outcome unknown"}}} =
             Executor.run(
               uncertain,
               protocol_options(uncertain_fake, %{cancel_turn: uncertain_error})
             )

    malformed = cancel_claim!("bad-cancel-envelope", "running")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.seed_turn(
      malformed_fake,
      malformed.session.coop_session_id,
      malformed.turn.coop_turn_id
    )

    assert Executor.run(
             malformed,
             protocol_options(malformed_fake, %{cancel_turn: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error, {:coop_mutation_response_unresolved, :cancel_turn, :cancel_turn_response}}
  end

  test "executor rejects unsafe settings and claims without touching work" do
    claim = claim_episode!("invalid-options")
    {:ok, fake} = fake_for(claim, [reply("unused")])
    valid = options(fake)

    cases = [
      {Keyword.put(valid, :api, "module"), :api},
      {Keyword.put(valid, :lease_seconds, 0), :lease_seconds},
      {Keyword.put(valid, :max_block_ms, 20_000), :max_block_ms},
      {Keyword.put(valid, :max_polls, 0), :max_polls},
      {Keyword.put(valid, :monotonic_ms, :clock), :monotonic_ms},
      {Keyword.put(valid, :now, :clock), :now},
      {Keyword.put(valid, :poll_interval_ms, 20_000), :poll_interval_ms},
      {Keyword.put(valid, :sleep, :sleep), :sleep},
      {Keyword.put(valid, :validation_context, :context), :validation_context}
    ]

    Enum.each(cases, fn {invalid, field} ->
      assert Executor.run(claim, invalid) == {:error, {:invalid_work_executor, field}}
    end)

    assert Executor.run(claim, Keyword.put(valid, :unknown, true)) ==
             {:error, {:invalid_work_executor, :options}}

    assert Executor.run(claim, :invalid) == {:error, {:invalid_work_executor, :options}}
    assert Executor.run(%{}, valid) == {:error, {:invalid_work_executor, :claim}}

    delivery = %{claim | turn: %{claim.turn | status: :delivery_pending}}
    assert Executor.run(delivery, valid) == {:error, :work_delivery_requires_gateway}

    settled = %{claim | turn: %{claim.turn | status: :settled}}
    assert Executor.run(settled, valid) == {:error, :work_turn_not_executable}

    malformed_submission = %{claim | turn: %{claim.turn | submission: "not-a-document"}}
    assert Executor.run(malformed_submission, valid) == {:error, :work_submission_missing}

    assert Executor.run(claim, api: FakeAPI) ==
             {:error, {:invalid_work_executor, :options}}
  end

  test "session creation reconciles both operation-only and lost-response outcomes" do
    Enum.each([:operation_only, :lost_response], fn mode ->
      claim = claim_episode!("create-reconcile-#{mode}")
      {:ok, fake} = fake_for(claim, [reply("Recovered create #{mode}.")])

      override = fn fallback ->
        {:ok, %{"operation" => operation, "session" => _session}} = fallback.()

        case mode do
          :operation_only -> {:ok, %{"operation" => operation}}
          :lost_response -> {:error, {:coop_transport_error, :response_lost}}
        end
      end

      assert {:ok, %{status: :accepted}} =
               Executor.run(claim, protocol_options(fake, %{create_session: override}))

      assert FakeAPI.state(fake).create_count == 1
    end)
  end

  test "session and operation protocol failures cannot bind guessed resources" do
    operation_error = claim_episode!("operation-read-error")
    {:ok, operation_fake} = fake_for(operation_error, [reply("unused")])

    assert Executor.run(
             operation_error,
             protocol_options(operation_fake, %{operation_by_key: {:error, :journal_down}})
           ) == {:error, :journal_down}

    bad_session = claim_episode!("bad-session-resource")
    {:ok, session_fake} = fake_for(bad_session, [reply("unused")])

    assert Executor.run(
             bad_session,
             protocol_options(session_fake, %{create_session: {:ok, %{"session" => %{}}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :create_session,
               {:coop_protocol_error, :session_resource}}}

    bad_operation = claim_episode!("bad-operation-state")
    {:ok, bad_operation_fake} = fake_for(bad_operation, [reply("unused")])

    FakeAPI.seed_operation(
      bad_operation_fake,
      create_key(bad_operation),
      %{"id" => "op-invalid", "state" => "mystery"}
    )

    assert Executor.run(bad_operation, options(bad_operation_fake)) ==
             {:error, {:coop_protocol_error, :operation_state}}
  end

  test "turn submission distinguishes direct conflict, uncertainty, and journal failure" do
    conflict = claim_with_bound_session!("direct-submit-conflict")
    {:ok, conflict_fake} = fake_for(conflict, [reply("unused")])
    conflict_error = {:error, {:coop_error, 409, "revision_conflict", "stale revision"}}

    assert {:error,
            {:work_generation_spent, :turn_submit,
             {:coop_error, 409, "revision_conflict", "stale revision"}}} =
             Executor.run(
               conflict,
               protocol_options(conflict_fake, %{submit_turn: conflict_error})
             )

    uncertain = claim_with_bound_session!("submit-uncertain")
    {:ok, uncertain_fake} = fake_for(uncertain, [reply("unused")])

    FakeAPI.seed_operation(
      uncertain_fake,
      turn_key(uncertain),
      uncertain_operation("operation_uncertain", "SubmitTurn")
    )

    assert {:error,
            {:work_execution_blocked, {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(uncertain, options(uncertain_fake))

    journal_error = claim_with_bound_session!("submit-journal-error")
    {:ok, journal_fake} = fake_for(journal_error, [reply("unused")])

    assert Executor.run(
             journal_error,
             protocol_options(journal_fake, %{operation_by_key: {:error, :journal_down}})
           ) == {:error, :journal_down}
  end

  test "a restarted validator reuses the exact frozen intent and candidate" do
    claim = accepted_intent_turn!("frozen-intent-resume")
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      turn = %{
        "candidate" => %{
          "attempt" => claim.turn.candidate_attempt,
          "message" => claim.turn.candidate,
          "sha256" => claim.turn.candidate_sha256
        },
        "id" => claim.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => claim.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert {:ok, %{status: :accepted}} = Executor.run(claim, options(fake))
    assert Enum.map(FakeAPI.state(fake).validations, & &1.verdict) == [:accept]

    malformed = bound_turn!("candidate-shape")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.update(malformed_fake, fn state ->
      turn = %{
        "candidate" => %{"attempt" => 1},
        "id" => malformed.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => malformed.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert Executor.run(malformed, options(malformed_fake)) ==
             {:error, {:coop_protocol_error, :candidate}}
  end

  test "a validation-context provider may return its durable snapshot explicitly" do
    claim = claim_episode!("explicit-validation-context")
    {:ok, fake} = fake_for(claim, [reply("Used the supplied host context.")])

    context = %{
      "artifact_refs" => [],
      "records" => %{},
      "visible_reply_required" => true
    }

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               claim,
               Keyword.put(options(fake), :validation_context, fn _claim -> {:ok, context} end)
             )
  end

  defp claim_episode!(suffix), do: claim_episode!(suffix, nil, :live)

  defp claim_after_human_reply! do
    first = claim_episode!("quiet-human-followup")

    {:ok, fake} =
      FakeAPI.start_link([reply("The plan is ready; I will report the apply outcome.")])

    assert {:ok, %{turn: accepted}} = Executor.run(first, options(fake))

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: "slack:app:B0BHPQTBMA7",
                 episode_id: first.episode.id,
                 episode_key: first.episode.key,
                 native_input_id: "tfc-unchanged-followup",
                 destination: %{
                   transport: first.episode.destination_transport,
                   conversation_ref: first.episode.destination_conversation_ref,
                   thread_ref: first.episode.destination_thread_ref
                 },
                 occurred_at: DateTime.add(@now, 1),
                 payload: %{"text" => "Run still pending"},
                 turn_ref: "queued:tfc-followup"
               })
             )

    assert {:ok, delivery} = Custody.claim_next("quiet-human-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.delivery_ref,
               first.episode.destination_transport,
               first.episode.destination_conversation_ref,
               first.episode.destination_thread_ref,
               "1787932807.004100"
             )

    assert {:ok, _} =
             Custody.confirm_delivery(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    assert {:ok, next} = Custody.claim_next("quiet-human-next", 60, :work)
    next
  end

  defp claim_episode!(suffix, payload), do: claim_episode!(suffix, payload, :live)

  defp claim_episode!(suffix, payload, execution_mode),
    do: claim_episode!(suffix, payload, execution_mode, nil)

  defp claim_episode!(suffix, payload, execution_mode, authority_digest) do
    claim_episode!(suffix, payload, execution_mode, authority_digest, nil, nil)
  end

  defp claim_episode!(
         suffix,
         payload,
         execution_mode,
         authority_digest,
         repository_ref,
         repository_context,
         actor_ref \\ "slack:user:U-stage3"
       ) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: actor_ref,
        episode_id: id,
        episode_key: "work-executor:#{suffix}:#{id}",
        execution_mode: execution_mode,
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        payload: payload || %{"text" => "Please handle #{suffix}."},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               id,
               "work-read-only",
               String.duplicate("a", 64),
               authority_digest,
               repository_ref,
               repository_context
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)
    claim
  end

  defp options(fake) do
    [
      api: FakeAPI,
      client: fake,
      lease_seconds: 60,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp bound_turn!(suffix) do
    claim = claim_episode!(suffix)

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               turn.submit_generation,
               "coop-turn:#{claim.episode.id}"
             )

    %{claim | session: session, turn: turn}
  end

  defp claim_with_bound_session!(suffix) do
    claim = claim_episode!(suffix)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session, turn: turn}
  end

  defp claim_with_bound_empty_session!(suffix, authority_digest \\ nil) do
    claim = claim_episode!(suffix, nil, :live, authority_digest)

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session}
  end

  defp claim_with_bound_repository_context!(suffix, repository_ref, read_only_repositories) do
    repository_context = %{
      "context_ref" => "platform",
      "parallel_goal_limit" => 2,
      "primary_repository" => repository_ref,
      "read_only_repositories" => read_only_repositories
    }

    claim =
      claim_episode!(suffix, nil, :live, nil, repository_ref, repository_context)

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session}
  end

  defp accepted_intent_turn!(suffix, attempt \\ 1) do
    claim = bound_turn!(suffix)
    candidate = reply("Validated answer.")
    sha256 = digest(candidate)

    assert {:ok, _staged_turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               attempt
             )

    assert {:ok, result} = Result.new(:reply, Jason.decode!(candidate))

    assert {:ok, turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               attempt,
               :accept,
               result
             )

    %{claim | turn: turn}
  end

  defp cancel_claim!(suffix, _remote_state) do
    work = bound_turn!(suffix)

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:#{work.turn.id}",
               "Stopped by the operator."
             )

    assert {:ok, claim} = Custody.claim_next("worker:cancel:#{suffix}", 60, :work)
    claim
  end

  defp fake_for(claim, candidates, options \\ []) do
    with {:ok, fake} <- FakeAPI.start_link(candidates, options) do
      FakeAPI.update(fake, fn state ->
        session =
          Map.merge(state.session, %{
            "external_ref" => claim.session.external_ref,
            "id" => claim.session.coop_session_id || "remote:#{claim.episode.id}",
            "policy" => claim.session.policy,
            "policy_digest" => claim.session.policy_digest,
            "authority_digest" => claim.session.authority_digest
          })

        %{state | session: session}
      end)

      {:ok, fake}
    end
  end

  defp protocol_options(fake, overrides) do
    options(%{fake: fake, overrides: overrides})
    |> Keyword.put(:api, ProtocolAPI)
  end

  defp prepare_remote_operation(claim, kind, key, revision, function) do
    Custody.with_mutation_fence(
      claim.episode.id,
      claim.turn.turn_ref,
      claim.lease_ref,
      %{
        kind: kind,
        lease_seconds: 60,
        maximum_block_ms: 1_000,
        operation_key: key,
        operation_revision: revision
      },
      function
    )
  end

  defp first_not_found_then(counter, operation) do
    fn _fallback ->
      Agent.get_and_update(counter, fn
        0 -> {:not_found, 1}
        count -> {{:ok, operation}, count + 1}
      end)
    end
  end

  defp reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp reply_with_records(message, record_refs) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => record_refs,
        "state" => "complete"
      }
    })
  end

  defp workspace_changes(overrides) do
    overrides = Map.new(overrides)

    %{
      "base_commit" => Map.get(overrides, :base_commit, "base-commit"),
      "committed" => Map.get(overrides, :committed, []),
      "conflicts" => Map.get(overrides, :conflicts, []),
      "fork_head" => Map.get(overrides, :fork_head, "base-commit"),
      "fork_tree" => Map.get(overrides, :fork_tree, "base-tree"),
      "parent_head" => "parent-head",
      "parent_divergence" => %{
        "ahead" => 0,
        "base_to_fork" => 0,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch_bytes" => 0,
      "patch_has_more" => false,
      "patch_next_offset" => 0,
      "patch_offset" => 0,
      "staged" => Map.get(overrides, :staged, []),
      "truncated" => false,
      "unstaged" => Map.get(overrides, :unstaged, []),
      "untracked" => Map.get(overrides, :untracked, [])
    }
    |> maybe_put_pull_request_tree(overrides)
  end

  defp maybe_put_pull_request_tree(changes, %{pull_request_tree: tree}),
    do: Map.put(changes, "pull_request_tree", tree)

  defp maybe_put_pull_request_tree(changes, _overrides), do: changes

  defp silent(reason) do
    Jason.encode!(%{
      "decision_reason" => reason,
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp failed_operation(code, method) do
    %{
      "error_code" => code,
      "error_detail" => "simulated #{code}",
      "id" => "op_failed_#{code}",
      "method" => method,
      "state" => "failed"
    }
  end

  defp uncertain_operation(code, method) do
    %{
      "error_code" => code,
      "error_detail" => "simulated #{code}",
      "id" => "op_uncertain_#{code}",
      "method" => method,
      "state" => "uncertain"
    }
  end

  defp running_operation(method) do
    %{"id" => "op_running", "method" => method, "state" => "running"}
  end

  defp succeeded_operation(method, type, id) do
    %{
      "id" => "op_#{type}_#{id}",
      "method" => method,
      "resource_id" => id,
      "resource_type" => type,
      "state" => "succeeded"
    }
  end

  defp create_key(claim),
    do: "responder:work:create:#{claim.session.id}:g#{claim.session.create_generation}"

  defp turn_key(claim),
    do:
      "responder:work:turn:#{claim.turn.id}:g#{claim.turn.submit_generation}:#{claim.turn.submission_fingerprint}"

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
