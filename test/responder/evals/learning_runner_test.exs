defmodule Responder.Evals.LearningRunnerTest do
  use Responder.DataCase, async: false
  alias Mix.Tasks.Responder.LearningEval
  alias Responder.Evals.LearningRunner
  alias Responder.TestSupport.FakeCoopAPI, as: Fake

  defmodule HostAPI do
    @moduledoc "Offline dispatcher plumbing: constructed contract output, never a recorded model answer."
    def capabilities(_client), do: {:ok, %{"repository_freshness_receipt_versions" => [2]}}
    defdelegate operation_by_key(client, key), to: Fake
    defdelegate fence_create_session(client, key, policy, ref), to: Fake
    defdelegate cancel_turn(client, sid, tid, key, revision), to: Fake

    def get_session(client, sid),
      do: in_session(client, sid, fn -> Fake.get_session(client, sid) end)

    def get_turn(client, sid, tid),
      do: in_session(client, sid, fn -> Fake.get_turn(client, sid, tid) end)

    def plan_discard(client, sid, key, revision, dirty, unmerged),
      do:
        in_session(client, sid, fn ->
          Fake.plan_discard(client, sid, key, revision, dirty, unmerged)
        end)

    def discard_session(client, sid, key, plan),
      do: in_session(client, sid, fn -> Fake.discard_session(client, sid, key, plan) end)

    def create_session(client, key, policy, ref) do
      Agent.update(client, fn state ->
        sessions =
          Map.put(
            Map.get(state, :eval_sessions, %{}),
            state.session["id"],
            Map.delete(state, :eval_sessions)
          )

        state
        |> Map.put(:eval_sessions, sessions)
        |> Map.put(:turn, nil)
        |> Map.put(:closed, false)
        |> Map.put(:discarded, false)
        |> Map.update!(
          :session,
          &Map.merge(&1, %{"id" => "remote_#{ref}", "revision" => 1, "state" => "open"})
        )
      end)

      Fake.create_session(client, key, policy, ref)
    end

    def submit_frozen_turn(
          client,
          sid,
          key,
          revision,
          %{"contract_version" => "work-final-v1"} = submission,
          nil,
          []
        ) do
      # Existing explicitly synthetic host-contract fixture; this tests custody
      # and recall exposure, not whether its unrelated answer is factually good.
      fixture =
        File.read!(
          "testdata/scenarios/ordinary-thread-question-gets-natural-answer/scenario.json"
        )
        |> Jason.decode!()

      body =
        get_in(fixture, [
          "host_replay",
          "model_events",
          Access.at(0),
          "candidates",
          Access.at(0),
          "document"
        ])

      Agent.update(client, &%{&1 | candidates: [Jason.encode!(body)], turn: nil})

      Fake.submit_turn(
        client,
        sid,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def submit_frozen_turn(client, sid, key, revision, submission, nil, []) do
      prompt = Jason.decode!(submission["prompt"])
      [input] = prompt["inputs"]
      state = Fake.state(client)

      old =
        if input["source_input_id"] not in Map.get(state, :eval_distinct_input_ids, []),
          do: List.first(prompt["knowledge"])

      body = constructed_body(input, old, prompt["knowledge"])

      body =
        if input["source_input_id"] in Map.get(state, :eval_no_change_input_ids, []) or
             (state[:eval_no_change_when_offered] && old != nil),
           do:
             Jason.encode!(%{"updates" => [], "reason" => "Constructed host no-change output."}),
           else: state[:eval_body] || body

      Agent.update(client, &%{&1 | candidates: [body], turn: nil})

      Fake.submit_turn(
        client,
        sid,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    defp constructed_body(input, old, knowledge) do
      summary =
        case input["content"]["text"] do
          text when is_binary(text) and text != "" -> text
          _ -> input["content"]["attachments"] |> hd() |> Map.fetch!("fallback")
        end

      Jason.encode!(%{
        "reason" => "Constructed host contract output.",
        "updates" => [
          %{
            "action" => if(old, do: "update", else: "create"),
            "topic_key" => constructed_topic_key(input, old, knowledge),
            "title" => "Structural topic fixture",
            "summary" => summary,
            "topics" => [],
            "anchors" => [],
            "target_ref" => old && old["source_ref"],
            "expected_version" => if(old, do: old["version"], else: 0),
            "source_input_ids" => [input["source_input_id"]]
          }
        ]
      })
    end

    defp constructed_topic_key(input, old, knowledge) do
      cond do
        old -> old["topic_key"]
        knowledge == [] -> "host-plumbing-topic"
        true -> "host-plumbing-occurrence-#{input["source_input_id"]}"
      end
    end

    def fence_frozen_turn(client, sid, key, revision, submission, nil, []),
      do:
        Fake.fence_submit_turn(
          client,
          sid,
          key,
          revision,
          submission["prompt"],
          submission["output_schema"]
        )

    def validate_frozen_candidate(client, sid, tid, key, _attempt, sha, :accept),
      do: Fake.validate_candidate(client, sid, tid, key, sha, :accept)

    def close_session(client, sid, key, revision) do
      {:ok, response} =
        in_session(client, sid, fn -> Fake.close_session(client, sid, key, revision) end)

      {:ok,
       Map.put(response, "operation", %{
         "id" => "close:#{key}",
         "method" => "CloseSession",
         "resource_id" => sid,
         "resource_type" => "session",
         "state" => "succeeded"
       })}
    end

    # The shared fake models one session. Preserve isolated historical snapshots
    # here so a rejected generation is cleaned using its own identity and proof.
    defp in_session(client, sid, call) do
      current = Fake.state(client)

      if current.session["id"] == sid do
        call.()
      else
        historical = Map.fetch!(current.eval_sessions, sid)
        Agent.update(client, fn _ -> historical end)

        try do
          call.()
        after
          changed = Fake.state(client)
          Agent.update(client, fn _ -> put_in(current.eval_sessions[sid], changed) end)
        end
      end
    end
  end

  @tag isolation: "REPEATABLE READ"
  test "held-out Work receives learned topics through the ordinary briefing, never as training",
       %{options: options} do
    options = Map.put(options, :probe_question, "What happened to the Host OOM kills alert?")
    assert {:ok, report} = LearningRunner.run(LearningRunner.recorded_sequence(), options)
    probe = report.work_probe
    assert report.passed, inspect(probe, pretty: true)
    assert probe.provenance =~ "authored"
    assert probe.proof =~ "automatic recall"
    assert "explicit search_memory invocation" in probe.not_qualified
    assert length(report.runs) == 2
    assert probe.turn["state_tools_endpoint"] == nil
    assert probe.turn["validation_receipt"] != nil
    assert probe.turn["external_receipt"]["transport"] == "slack"
    assert probe.session["cleanup_status"] == "discarded"

    assert [%{"knowledge_id" => id, "version" => 2}] =
             Enum.map(probe.knowledge_exposures, &Map.take(&1, ~w(knowledge_id version)))

    assert [%{"id" => ^id}] = Enum.map(report.topics, &Map.take(&1, ["id"]))

    assert [%{"source_ref" => "knowledge:" <> ^id}] =
             get_in(probe.turn, [
               "submission",
               "context",
               "operator_context",
               "continuity",
               "knowledge"
             ])

    assert Jason.encode!(probe) =~ "required; inspect the answer"
  end

  setup do
    {root, 0} = System.cmd("mktemp", ["-d", "-t", "responder-learning-eval.XXXXXX"])
    root = String.trim(root)
    {_, 0} = System.cmd("git", ["init", "--quiet", root])
    {canonical, 0} = System.cmd("git", ["-C", root, "rev-parse", "--show-toplevel"])
    root = String.trim(canonical)

    {_, 0} =
      System.cmd("git", [
        "-C",
        root,
        "-c",
        "user.name=Host Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "Disposable empty evaluation repository"
      ])

    # Only this newly created, exact disposable directory is removed.
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, fake} = Fake.start_link([])
    {head, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
    head = String.trim(head)

    Agent.update(fake, fn state ->
      put_in(
        state.session,
        Map.merge(state.session, %{
          "base_commit" => head,
          "companions" => [],
          "repository_freshness_status" => "recorded",
          "repository_freshness" => [
            %{
              "fetched_at" => "2026-09-08T08:00:00Z",
              "name" => "primary",
              "remote_identity" => "local",
              "requested_revision" => "HEAD",
              "resolved_revision" => head,
              "workspace_base_revision" => head,
              "stale_base_status" => "not_applicable",
              "version" => 2
            }
          ]
        })
      )
    end)

    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    %{rows: [[database]]} = Repo.query!("SELECT current_database()")

    %{
      options: %{
        database: database,
        scratch_repository: root,
        api: HostAPI,
        client: fake,
        policy: "learning-evaluation-only",
        policy_digest: String.duplicate("a", 64),
        max_polls: 20
      }
    }
  end

  test "separate source batches reuse the first applied topic without seeing the future", %{
    options: options
  } do
    assert {:ok, report} = LearningRunner.run(LearningRunner.recorded_sequence(), options)

    assert report.passed,
           inspect(
             %{
               steps: report.steps,
               sessions: report.sessions,
               runs:
                 Enum.map(
                   report.runs,
                   &Map.take(&1, ~w(status error_code result))
                 )
             },
             pretty: true
           )

    assert report.execution == "host_plumbing"
    assert Jason.decode!(Jason.encode!(report))["semantic_review"] =~ "required"
    assert [first, second] = report.steps
    assert [%{id: id, version: 1}] = first.after
    assert [%{id: ^id, version: 2}] = second.after
    assert first.cleanup == :discarded and second.cleanup == :discarded
    assert [first_run, second_run] = report.runs
    assert Jason.decode!(first_run["prompt"])["knowledge"] == []

    assert [%{"source_ref" => "knowledge:" <> ^id}] =
             Jason.decode!(second_run["prompt"])["knowledge"]

    assert Enum.all?(
             report.runs,
             &(&1["remote_stopped_at"] && &1["validation_receipt"] && &1["producer"])
           )

    assert Enum.all?(
             report.sessions,
             &(&1["cleanup_status"] == "discarded" && &1["cleanup_receipt"])
           )

    assert Enum.map(report.steps, & &1.occurred_at) == [
             "2026-09-05T17:19:24.248029Z",
             "2026-09-05T17:29:24.235999Z"
           ]

    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
  end

  test "a harvested acknowledgement can settle without creating a topic", %{options: options} do
    # Constructed empty-update contract output tests only host application; the
    # live lane must independently demonstrate that the model chooses no change.
    Agent.update(
      options.client,
      &Map.put(
        &1,
        :eval_body,
        Jason.encode!(%{"updates" => [], "reason" => "No durable change."})
      )
    )

    assert {:ok, report} =
             LearningRunner.run(LearningRunner.recorded_sequence("chatter"), options)

    assert report.passed
    assert report.topics == [] and report.revisions == []

    assert [%{expectation: :no_change, check: true, cleanup: :discarded}] =
             Enum.map(report.steps, &Map.take(&1, [:expectation, :check, :cleanup]))

    assert [run] = report.runs
    assert Jason.decode!(run["result"])["updates"] == []
  end

  test "an explicit database mismatch prevents any imported source or remote call", %{
    options: options
  } do
    assert {:error, :learning_eval_database_mismatch} =
             LearningRunner.run(LearningRunner.recorded_sequence(), %{
               options
               | database: "responder"
             })

    assert Fake.state(options.client).create_keys == []
  end

  test "the later keep decision enters only its own batch and advances the same topic", %{
    options: options
  } do
    assert {:ok, report} =
             LearningRunner.run(LearningRunner.recorded_sequence("draft-keep"), options)

    assert report.passed, inspect(report.steps)
    assert [first, second, third] = report.steps
    assert [%{id: id, version: 1}] = first.after
    assert [%{id: ^id, version: 2}] = second.after
    assert [%{id: ^id, version: 3}] = third.after

    assert [first_run, second_run, third_run] =
             Enum.filter(report.runs, &(&1["status"] == "applied"))

    refute first_run["prompt"] =~ "let’s keep it"
    refute second_run["prompt"] =~ "let’s keep it"
    assert third_run["prompt"] =~ "let’s keep it"
    assert third.original_execution_mode == "live"
    assert third.replay_execution_mode == "shadow"
    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
  end

  test "unfinished work keeps custody and stops before exposing the next input", %{
    options: options
  } do
    Agent.update(options.client, &%{&1 | turn_wait_polls: 100})

    assert {:ok, report} =
             LearningRunner.run(LearningRunner.recorded_sequence(), %{options | max_polls: 1})

    refute report.passed
    assert [step] = report.steps
    assert step.batch["error_code"] == "evaluation_poll_budget_exhausted"
    assert step.cleanup == :unfinished
    assert [%{"remote_stopped_at" => nil, "prompt" => prompt}] = report.runs
    assert is_binary(prompt)
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 1
    assert Fake.state(options.client).discard_keys == []
    assert {:error, :learning_eval_database_not_empty} = LearningRunner.preflight(options)
  end

  for release <- [:new_topic, :no_change] do
    @tag :correction
    test "human correction preserves history after the release chose #{release}",
         %{
           options: options
         } do
      # The source messages are harvested. HostAPI deliberately copies source
      # text as a constructed contract output; only a separate live run can
      # establish whether a real model interprets the correction correctly.
      sequence = LearningRunner.recorded_sequence("fortnite-correction")

      if unquote(release) == :no_change,
        do:
          Agent.update(
            options.client,
            &Map.put(&1, :eval_no_change_input_ids, [hd(sequence).input["id"]])
          )

      assert {:ok, report} = LearningRunner.run(sequence, options)

      assert report.passed,
             inspect(%{
               steps: report.steps,
               runs: Enum.map(report.runs, &Map.take(&1, ~w(error_code result knowledge)))
             })

      assert [first, second, third] = report.steps
      version = if unquote(release) == :new_topic, do: 2, else: 1
      assert [%{id: id, version: ^version}] = second.after
      assert third.after == [%{id: id, version: version + 1}]

      assert first.after ==
               if(unquote(release) == :new_topic, do: [%{id: id, version: 1}], else: [])

      assert [first_run, second_run, third_run] = report.runs
      refute first_run["prompt"] =~ "Nothing is stuck, this is done manually"
      refute second_run["prompt"] =~ "Nothing is stuck, this is done manually"
      assert third_run["prompt"] =~ "Nothing is stuck, this is done manually"
      assert length(report.revisions) == version + 1

      inputs = Enum.flat_map(report.runs, &Jason.decode!(&1["prompt"])["inputs"])
      assert Enum.map(inputs, & &1["source_input_id"]) == Enum.map(sequence, & &1.input["id"])
      assert Enum.map(inputs, & &1["content"]) == Enum.map(sequence, & &1.input["content"])

      assert Enum.map(inputs, & &1["actor"]) == [
               %{"kind" => "app", "ref" => "A04FC43DC3F"},
               %{"kind" => "user", "ref" => "U0B1ZF12S49"},
               %{"kind" => "user", "ref" => "U034C9C4LLB"}
             ]

      refute Jason.encode!(report.runs) =~ "Updated assets, had to update the asset scraper"
      assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
    end
  end

  @tag :correction
  test "optional release learning does not waive the later human concern", %{options: options} do
    sequence = LearningRunner.recorded_sequence("fortnite-correction")
    ignored = sequence |> Enum.take(2) |> Enum.map(& &1.input["id"])
    Agent.update(options.client, &Map.put(&1, :eval_no_change_input_ids, ignored))
    assert {:ok, report} = LearningRunner.run(sequence, options)
    refute report.passed
    assert [release, concern] = report.steps
    assert release.passed and release.check
    refute concern.check
    assert concern.expectation == :topic_progress
    assert concern.cleanup == :discarded
    assert report.topics == []
    assert report.unrun_inputs == [List.last(sequence).input["id"]]
  end

  for memory_shape <- [:service_topic, :occurrence_topic] do
    @tag :recurrence
    test "a later recorded occurrence can use a #{memory_shape} without future resolution input",
         %{options: options} do
      # Exact recorded input chronology; both output shapes are constructed host
      # contracts, not evidence that a real model distinguished the occurrences.
      sequence = LearningRunner.recorded_sequence("auth-memory-recurrence")
      [firing, resolved, recurrence] = sequence

      if unquote(memory_shape) == :occurrence_topic,
        do:
          Agent.update(
            options.client,
            &Map.put(&1, :eval_distinct_input_ids, [recurrence.input["id"]])
          )

      assert {:ok, report} = LearningRunner.run(sequence, options)
      assert report.passed, inspect(report.steps)
      assert [first, second, third] = report.steps
      assert [%{id: id, version: 1}] = first.after
      assert [%{id: ^id, version: 2}] = second.after
      assert third.expectation == :later_occurrence
      assert third.semantic_review =~ "earlier resolution"

      if unquote(memory_shape) == :service_topic do
        assert third.after == [%{id: id, version: 3}]
      else
        assert length(third.after) == 2
        assert %{id: id, version: 2} in third.after
        assert Enum.any?(third.after, &(&1.id != id and &1.version == 1))
      end

      assert [first_run, second_run, third_run] = report.runs
      refute first_run["prompt"] =~ "07:13:40 UTC"
      refute second_run["prompt"] =~ "07:52:40 UTC"
      assert third_run["prompt"] =~ "07:52:40 UTC"
      refute third_run["prompt"] =~ "4fb4ec47-c3bd-4528-b3d5-3f809b8d80f9"

      inputs = Enum.flat_map(report.runs, &Jason.decode!(&1["prompt"])["inputs"])

      assert Enum.map(inputs, & &1["content"]) ==
               Enum.map([firing, resolved, recurrence], & &1.input["content"])

      assert Enum.all?(report.steps, &(&1.cleanup == :discarded))
      assert Enum.map(report.steps, & &1.batch["start_count"]) == [1, 1, 1]
    end
  end

  @tag :recurrence
  test "later occurrence learning cannot silently retain the earlier resolved topic unchanged", %{
    options: options
  } do
    sequence = LearningRunner.recorded_sequence("auth-memory-recurrence")
    recurrence = List.last(sequence).input["id"]
    Agent.update(options.client, &Map.put(&1, :eval_no_change_input_ids, [recurrence]))
    assert {:ok, report} = LearningRunner.run(sequence, options)
    refute report.passed
    assert [_, _, third] = report.steps
    refute third.check
    assert third.cleanup == :discarded
  end

  test "a crossed repository refuses source submission and leaves receipts intact", %{
    options: options
  } do
    Agent.update(
      options.client,
      &put_in(&1, [:session, "base_commit"], String.duplicate("b", 40))
    )

    assert {:ok, report} =
             LearningRunner.run(LearningRunner.recorded_sequence(), %{options | max_polls: 1})

    refute report.passed
    assert Fake.state(options.client).submit_count == 0
    assert [%{"prompt" => prompt}] = report.runs
    assert is_binary(prompt)
  end

  for response <- [:update, :no_change] do
    @tag :match_race
    test "an unoffered concurrent topic gets a fresh real-contract #{response} attempt", %{
      options: options
    } do
      # Controlled concurrency over exact retained input and captured creation.
      # HostAPI outputs are structural contracts; the live lane uses real model
      # results for both the rejected first attempt and the replacement judgment.
      if unquote(response) == :no_change,
        do: Agent.update(options.client, &Map.put(&1, :eval_no_change_when_offered, true))

      sequence = LearningRunner.recorded_sequence("unoffered-draft-match")
      assert {:ok, report} = LearningRunner.run(sequence, options)
      assert report.passed, inspect(report.steps)
      assert [step] = report.steps
      assert step.matching_check
      assert step.controlled_race.provenance =~ "structural concurrent writer"

      assert step.controlled_race.fixture ==
               "testdata/learning/recorded-draft-retention-create.json"

      assert [first, second] = report.runs
      assert first["knowledge"] == []
      assert first["error_code"] == "learning_match_required"
      assert first["match_refs"] == [step.controlled_race.source_ref]
      assert first["result"] != nil
      assert [offered] = second["knowledge"]
      assert offered["source_ref"] == step.controlled_race.source_ref
      assert offered["version"] == 1
      assert second["generation"] == 2
      assert second["result"] != nil
      assert step.batch["start_count"] == 2
      assert step.batch["start_limit"] == 3
      assert step.cleanup == :discarded
      assert Enum.all?(report.sessions, &(&1["cleanup_status"] == "discarded"))
      assert [topic] = report.topics
      assert topic["version"] == if(unquote(response) == :update, do: 2, else: 1)
    end
  end

  test "changing a harvested source invalidates provenance before import", %{options: options} do
    [first | rest] = LearningRunner.recorded_sequence()
    first = put_in(first.input["content"]["text"], "invented later decision")
    assert {:error, :learning_eval_invalid_sequence} = LearningRunner.run([first | rest], options)
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 0
  end

  test "failed public candidates and producer identity survive evaluation failure", %{
    options: options
  } do
    body = "{\"updates\": ["
    Agent.update(options.client, &Map.put(&1, :eval_body, body))

    assert {:ok, report} =
             LearningRunner.run(LearningRunner.recorded_sequence(), %{options | max_polls: 6})

    refute report.passed

    assert [
             %{
               "result" => ^body,
               "error_code" => "invalid_learning_result",
               "producer" => producer
             }
             | _
           ] = report.runs

    assert producer["session_id"] != nil
    assert length(report.unrun_inputs) == 1
    assert report.topics == []
  end

  test "an untracked file makes the scratch checkout ineligible", %{options: options} do
    File.write!(Path.join(options.scratch_repository, ".env"), "HOST_FIXTURE_ONLY=not_a_secret")

    assert {:error, :learning_eval_requires_empty_scratch_repository} =
             LearningRunner.preflight(options)

    assert Fake.state(options.client).create_keys == []
  end

  test "a configured background runtime is refused before imports", %{options: options} do
    previous = Application.get_env(:responder, :delivery)
    Application.put_env(:responder, :delivery, %{worker_ref: "must-not-start"})

    try do
      assert {:error, :learning_eval_background_runtime_configured} =
               LearningRunner.preflight(options)

      assert Fake.state(options.client).create_keys == []
    after
      if previous,
        do: Application.put_env(:responder, :delivery, previous),
        else: Application.delete_env(:responder, :delivery)
    end
  end

  test "the command rejects repeated authority flags and unknown scenarios before any start" do
    flags = [
      "--database",
      "responder_learning_eval_command",
      "--socket",
      "/fixture/coop.sock",
      "--scratch",
      "/fixture/scratch",
      "--policy",
      "eval",
      "--policy-digest",
      String.duplicate("a", 64),
      "--results",
      "/fixture/result.json"
    ]

    assert_raise Mix.Error, ~r/each required flag once/, fn ->
      LearningEval.run(flags ++ ["--policy", "another"])
    end

    assert_raise Mix.Error, "unknown learning scenario", fn ->
      LearningEval.run(flags ++ ["--scenario", "invented"])
    end
  end

  test "the command refuses a meaningless chatter recall probe before any start" do
    assert_raise Mix.Error, ~r/chatter has no learned topic/, fn ->
      LearningEval.run([
        "--database",
        "responder_learning_eval_chatter",
        "--socket",
        "/not-opened.sock",
        "--scratch",
        "/not-opened",
        "--policy",
        "not-used",
        "--policy-digest",
        String.duplicate("a", 64),
        "--results",
        "/not-created.json",
        "--scenario",
        "chatter",
        "--probe"
      ])
    end
  end

  test "one-off request qualification catches the captured unnecessary topic", %{options: options} do
    # The first recovered live batch stored a routine acceptance check as an
    # unresolved topic. Repeating that for ordinary requests recreates a memory
    # per message. This tests the evaluator; only a fresh model run can prove
    # that improved learning instructions avoid the captured behavior.
    [step] = LearningRunner.recorded_sequence("one-off-request")
    fixture = step.fixture |> File.read!() |> Jason.decode!()
    failure = fixture["recorded_failure"]
    assert Responder.CanonicalJSON.digest(failure["prompt"]) == failure["prompt_sha256"]
    assert Responder.CanonicalJSON.digest(failure["result"]) == failure["result_sha256"]
    assert step.expectation == :no_change
    assert [submitted] = Jason.decode!(failure["prompt"])["inputs"]
    assert submitted["content"] == step.input["content"]
    assert submitted["source_input_id"] == step.input["id"]

    Agent.update(options.client, &Map.put(&1, :eval_body, failure["result"]))
    assert {:ok, report} = LearningRunner.run([step], options)
    refute report.passed
    assert [observed] = report.steps
    refute observed.check
    refute observed.passed
    assert observed.batch["status"] == "applied"
    assert length(report.topics) == 1
    assert hd(report.runs)["result"] == failure["result"]
  end

  test "the command rejects a one-off request recall probe before any start" do
    assert_raise Mix.Error, ~r/one-off-request has no learned topic/, fn ->
      LearningEval.run([
        "--database",
        "responder_learning_eval_one_off",
        "--socket",
        "/not-opened.sock",
        "--scratch",
        "/not-opened",
        "--policy",
        "not-used",
        "--policy-digest",
        String.duplicate("a", 64),
        "--results",
        "/not-created.json",
        "--scenario",
        "one-off-request",
        "--probe"
      ])
    end
  end

  test "a runner exception produces a public failure report instead of an empty file" do
    {:ok, io} = StringIO.open("")

    assert {:error, %{kind: "runner_exception", detail: "host fixture crash"}} =
             LearningEval.write_result(io, "haproxy", fn ->
               raise "host fixture crash"
             end)

    {_input, bytes} = StringIO.contents(io)
    report = Jason.decode!(bytes)
    assert report["result"]["passed"] == false
    assert report["result"]["error"]["detail"] == "host fixture crash"
    assert report["result"]["runs"] == []
    assert report["result"]["notice"] =~ "reconciled"
    StringIO.close(io)
  end

  test "asynchronous create and submit receipts resume the same budgeted run", %{options: options} do
    Agent.update(
      options.client,
      &%{&1 | async_create: true, async_submit: true, async_operations_running: true}
    )

    assert {:ok, report} = LearningRunner.run(LearningRunner.recorded_sequence(), options)
    assert report.passed, inspect(report.steps)
    assert length(report.runs) == 2
    assert Fake.state(options.client).submit_count == 2
    assert Enum.all?(report.steps, &(&1.batch["start_count"] == 1))
  end
end
