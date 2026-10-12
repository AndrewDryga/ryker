defmodule Ryker.Evals.WorldAdmissionCaseTest do
  use ExUnit.Case, async: true
  alias Ryker.Admission
  alias Ryker.CanonicalJSON
  alias Ryker.Evals.{CoopRunner, Job, WorldAdmissionCase}
  alias Ryker.Ingress
  alias Ryker.Slack
  alias Ryker.TestSupport.FakeCoopAPI

  setup do
    {:ok, input} =
      Slack.Input.new(%{
        actor: %{kind: :app, ref: "AEVAL"},
        channel_ref: "CEVAL",
        content: %{"text" => "An unavailable file with no operational event."},
        event_kind: :message,
        event_ref: "EvEVAL",
        message_ref: "1787832000.000100",
        occurred_at: ~U[2026-08-27 12:00:00.000000Z],
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TEVAL"
      })

    context = %Admission.Context{
      active_episode_fingerprint: CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Ingress.Inbox.Entry{id: Ecto.UUID.generate(), execution_mode: :live}
    }

    captured =
      "testdata/admission/sentiment/file-after-quick-answer.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("recorded_result")

    %{context: context, captured: captured}
  end

  test "uses today's complete admission prompt and source-specific contract", %{context: context} do
    assert {:ok, eval} = WorldAdmissionCase.new(context)
    assert eval.prompt == context |> Admission.Prompt.build() |> Admission.Prompt.render()
    allowed_actions = Ingress.Input.allowed_actions(context.input)
    reaction_names = Ingress.Input.reaction_names(context.input)

    assert eval.schema ==
             Admission.Decision.json_schema(
               allowed_actions,
               reaction_names,
               false,
               [],
               false
             )

    assert WorldAdmissionCase.new(%{}) == {:error, {:invalid_world_admission, :context}}
  end

  test "a recorded valid decision keeps all fields, not a replay comparison", %{
    context: context,
    captured: captured
  } do
    {:ok, eval} = WorldAdmissionCase.new(context)

    assert {:accept, %{document: document, passed: true}} =
             WorldAdmissionCase.validate(eval, captured)

    assert document == Jason.decode!(captured)
    assert Map.has_key?(document, "work_class")
    assert Map.has_key?(document, "repository_source")

    sentiment = %{"feeling" => "neutral", "reason" => "No response was requested."}
    answer = document |> Map.put("sentiment", sentiment) |> Jason.encode!()

    assert {:accept, %{document: %{"sentiment" => ^sentiment}}} =
             WorldAdmissionCase.validate(eval, answer)
  end

  test "unoffered candidates and malformed decisions require repair", %{
    context: context,
    captured: captured
  } do
    {:ok, eval} = WorldAdmissionCase.new(context)
    document = Jason.decode!(captured)

    unoffered =
      Map.merge(document, %{
        "action" => "start_episode",
        "episode_ref" => "candidate:unoffered",
        "relation" => "history_only",
        "work_class" => "standard"
      })

    unoffered_answer = Jason.encode!(unoffered)
    incomplete_answer = document |> Map.delete("repository") |> Jason.encode!()

    assert {:reject, [_reason]} = WorldAdmissionCase.validate(eval, unoffered_answer)
    assert {:reject, [_reason]} = WorldAdmissionCase.validate(eval, incomplete_answer)

    assert {:reject, [_reason]} = WorldAdmissionCase.validate(eval, "[]")
    assert {:reject, [_reason]} = WorldAdmissionCase.validate(eval, nil)
  end

  test "a real Coop-shaped admission turn repairs and cleans up without prescribing a route", %{
    context: context,
    captured: captured
  } do
    {:ok, eval} = WorldAdmissionCase.new(context)
    {:ok, fake} = FakeCoopAPI.start_link(["not-json", captured])
    {:ok, job} = Job.new(:world, "codex:fixture/low@eval")

    result =
      CoopRunner.run_case(eval,
        api: FakeCoopAPI,
        client: fake,
        job: job,
        id_generator: fn -> "world-admission-test" end,
        max_polls: 10,
        poll_interval_ms: 0,
        sleep: fn 0 -> :ok end
      )

    assert result.status == :passed
    assert result.decision == Jason.decode!(captured)
    assert result.cleanup_error == nil
    state = FakeCoopAPI.state(fake)
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
    assert state.submit_count == 1
    assert state.schema == eval.schema
    assert state.submitted_prompt == eval.prompt
    assert state.closed
    assert state.discarded
  end
end
