defmodule Responder.Evals.AdmissionCaseTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.AdmissionCase

  @fixture_path "test/responder/admission/fixtures/resolved_card_continues_active_episode.json"

  test "every pending model judgment compiles into an executable opaque eval case" do
    assert {:ok, cases} = AdmissionCase.all()
    assert length(cases) == 14
    assert Enum.uniq_by(cases, & &1.eval_id) == cases

    assert Enum.any?(cases, &(&1.eval_id == "human_thread_reply_continues_existing_episode"))
    assert Enum.any?(cases, &(&1.eval_id == "direct_question_selects_conversational_work"))
    assert Enum.any?(cases, &(&1.eval_id == "broad_health_assessment_selects_deep_work"))

    for eval <- cases do
      document = AdmissionCase.document(eval)

      assert Map.keys(document) |> Enum.sort() ==
               ~w(accepted_alternatives eval_id expectation fixture_path prompt reason schema source)

      assert document["prompt"]["instructions"] =~ "Interpret the event itself"
      assert document["schema"]["title"] == "Responder admission decision"
      refute Jason.encode!(document["prompt"]) =~ "fixture:"
      refute Jason.encode!(document["prompt"]) =~ "01993d45-"
    end
  end

  test "assessment ignores prose while enforcing the exact lifecycle action and candidate" do
    assert {:ok, cases} = AdmissionCase.all()

    eval =
      Enum.find(cases, &(&1.eval_id == "human_thread_reply_continues_existing_episode"))

    submitted =
      Map.put(eval.expectation, "reason", "This is still the same requested thread work.")

    assert {:ok, decision} = AdmissionCase.assess(eval, submitted)
    assert decision.action == :continue_episode
    assert decision.relation == :same_work
    assert decision.work_class == :standard

    wrong = %{
      submitted
      | "action" => "start_episode",
        "episode_ref" => nil,
        "relation" => "unrelated"
    }

    assert {:error,
            {:admission_eval_mismatch, expected: expected, submitted: submitted_comparison}} =
             AdmissionCase.assess(eval, wrong)

    assert expected == eval.expectation
    assert submitted_comparison["action"] == "start_episode"
  end

  test "a harvested human-thread fixture admits only its explicit conversational same-work reply" do
    assert {:ok, cases} = AdmissionCase.all()

    eval =
      Enum.find(cases, &(&1.eval_id == "human_thread_reply_continues_existing_episode"))

    alternate = %{
      "action" => "reply",
      "episode_ref" => eval.expectation["episode_ref"],
      "reaction" => nil,
      "relation" => "same_work",
      "reason" =>
        "This is a direct follow-up to the ads.txt redirect discussion. Whether www is needed can be answered conversationally, while distinguishing general guidance from unverified domain configuration.",
      "work_class" => "conversational"
    }

    assert {:ok, %{action: :reply, relation: :same_work, work_class: :conversational}} =
             AdmissionCase.assess(eval, alternate)

    for submitted <- [
          %{alternate | "episode_ref" => "candidate:unoffered"},
          %{alternate | "relation" => "history_only"},
          %{
            "action" => "start_episode",
            "episode_ref" => eval.expectation["episode_ref"],
            "reaction" => nil,
            "relation" => "history_only",
            "reason" => "Treat the earlier episode only as background.",
            "work_class" => "standard"
          }
        ] do
      assert {:error,
              {:admission_eval_mismatch, expected: expected, submitted: submitted_comparison}} =
               AdmissionCase.assess(eval, submitted)

      assert expected == eval.expectation

      assert submitted_comparison ==
               Map.take(submitted, ~w(action episode_ref reaction relation work_class))
    end

    assert {:error, {:invalid_decision, :work_class}} =
             AdmissionCase.assess(eval, %{alternate | "work_class" => "deep"})

    non_human_eval =
      Enum.find(
        cases,
        &(&1.fixture_path ==
            "test/responder/admission/fixtures/terraform_lifecycle_continues_episode.json")
      )

    non_human_submitted = %{
      alternate
      | "episode_ref" => non_human_eval.expectation["episode_ref"],
        "reason" => "Reply directly to a lifecycle update."
    }

    assert {:error,
            {:admission_eval_mismatch,
             expected: non_human_expected, submitted: non_human_submitted_comparison}} =
             AdmissionCase.assess(non_human_eval, non_human_submitted)

    assert non_human_expected == non_human_eval.expectation

    assert non_human_submitted_comparison ==
             Map.take(non_human_submitted, ~w(action episode_ref reaction relation work_class))
  end

  test "assessment scores the abstract work class independently of lifecycle prose" do
    assert {:ok, cases} = AdmissionCase.all()

    eval =
      Enum.find(cases, &(&1.eval_id == "human_thread_reply_continues_existing_episode"))

    wrong_class =
      eval.expectation
      |> Map.put("reason", "Use an unnecessarily deep route for the same lifecycle.")
      |> Map.put("work_class", "deep")

    assert {:error, {:admission_eval_mismatch, expected: expected, submitted: submitted}} =
             AdmissionCase.assess(eval, wrong_class)

    assert expected["work_class"] == "standard"
    assert submitted["work_class"] == "deep"
  end

  test "malformed manifests and candidates fail before a model score can be reported" do
    temporary = Path.join(System.tmp_dir!(), "responder-eval-#{Ecto.UUID.generate()}.json")
    File.write!(temporary, Jason.encode!(%{"stage2_pending_model_evals" => []}))
    on_exit(fn -> File.rm(temporary) end)

    assert AdmissionCase.all(temporary) == {:ok, []}

    assert AdmissionCase.compile(%{}) ==
             {:error, {:invalid_admission_eval, :descriptor_fields}}

    assert {:ok, [eval | _]} = AdmissionCase.all()
    assert AdmissionCase.assess(eval, %{}) == {:error, {:invalid_decision, :fields}}
  end

  test "the eval compiler accepts every Slack lifecycle vocabulary at its exact boundary" do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()

    variants = [
      {"waiting_for_input", "bot", "edit", fixture["decision"]},
      {"waiting_for_event", "user", "delete", fixture["decision"]},
      {"complete", "app", "message", fixture["decision"]},
      {"cancelled", "app", "message",
       %{
         "action" => "start_episode",
         "episode_ref" => "$seed",
         "reaction" => nil,
         "relation" => "history_only",
         "reason" => "Cancelled work is history, not a resumable owner.",
         "work_class" => "standard"
       }}
    ]

    for {state, actor_kind, event_kind, decision} <- variants do
      document =
        fixture
        |> put_in(["seed", "state"], state)
        |> put_in(["input", "actor", "kind"], actor_kind)
        |> put_in(["input", "event_kind"], event_kind)
        |> Map.put("decision", decision)

      path = write_json!(document)
      assert {:ok, eval} = AdmissionCase.compile(descriptor(path, "vocabulary:#{state}"))
      assert eval.expectation["relation"] == decision["relation"]
    end
  end

  test "malformed corpus structure fails closed before it can become a model score" do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()

    invalid = [
      {put_in(fixture, ["seed"], "invalid"), {:invalid_admission_eval, :seed}},
      {put_in(fixture, ["input"], []), {:invalid_admission_eval, :input}},
      {put_in(fixture, ["decision"], []), {:invalid_admission_eval, :decision}},
      {put_in(fixture, ["continuation_window_seconds"], -1),
       {:invalid_admission_eval, :continuation_window_seconds}},
      {put_in(fixture, ["now"], 42), {:invalid_admission_eval, :now}},
      {put_in(fixture, ["seed", "state"], "invented"), {:invalid_admission_eval, :state}},
      {put_in(fixture, ["input", "actor", "kind"], "guest"),
       {:invalid_admission_eval, :actor_kind}},
      {put_in(fixture, ["input", "event_kind"], "reaction"),
       {:invalid_admission_eval, :event_kind}},
      {put_in(fixture, ["seed", "episode_id"], "not-a-uuid"),
       {:invalid_admission_eval, :episode_id}},
      {put_in(fixture, ["seed", "updated_at"], "not-a-time"),
       {:invalid_admission_eval, :updated_at}}
    ]

    for {document, reason} <- invalid do
      path = write_json!(document)
      assert AdmissionCase.compile(descriptor(path, Ecto.UUID.generate())) == {:error, reason}
    end

    assert AdmissionCase.compile(:invalid) ==
             {:error, {:invalid_admission_eval, :descriptor}}

    assert AdmissionCase.compile(descriptor(42, "invalid-path")) ==
             {:error, {:invalid_admission_eval, :path}}

    assert AdmissionCase.compile(%{
             "context_fixture" => @fixture_path,
             "eval_id" => "invalid-reason",
             "reason" => nil
           }) == {:error, {:invalid_admission_eval, :reason}}

    assert AdmissionCase.compile(%{
             "context_fixture" => @fixture_path,
             "eval_id" => <<0>>,
             "reason" => "A valid explanation."
           }) == {:error, {:invalid_admission_eval, :text}}
  end

  test "manifest decoding rejects missing, duplicate, non-object, and unreadable documents" do
    missing = write_json!(%{})

    assert AdmissionCase.all(missing) ==
             {:error, {:invalid_admission_eval_manifest, :pending_model_evals}}

    not_a_list = write_json!(%{"stage2_pending_model_evals" => %{}})

    assert AdmissionCase.all(not_a_list) ==
             {:error, {:invalid_admission_eval_manifest, :document}}

    duplicate = descriptor(@fixture_path, "duplicate")
    duplicate_manifest = write_json!(%{"stage2_pending_model_evals" => [duplicate, duplicate]})

    assert AdmissionCase.all(duplicate_manifest) ==
             {:error, {:invalid_admission_eval_manifest, :duplicate_eval_id}}

    json_array = temporary_path()
    File.write!(json_array, "[]")

    assert AdmissionCase.all(json_array) ==
             {:error, {:invalid_admission_eval, :json_document}}

    missing_path = temporary_path()

    assert {:error, {:invalid_admission_eval_file, ^missing_path, :enoent}} =
             AdmissionCase.all(missing_path)

    invalid_descriptor = descriptor(missing_path, "missing-fixture")
    invalid_manifest = write_json!(%{"stage2_pending_model_evals" => [invalid_descriptor]})

    assert AdmissionCase.all(invalid_manifest) ==
             {:error, {missing_path, {:invalid_admission_eval_file, missing_path, :enoent}}}
  end

  defp descriptor(path, eval_id) do
    %{
      "context_fixture" => path,
      "eval_id" => eval_id,
      "reason" => "This exact lifecycle vocabulary must remain executable."
    }
  end

  defp write_json!(document) do
    path = temporary_path()
    File.write!(path, Jason.encode!(document))
    path
  end

  defp temporary_path do
    path = Path.join(System.tmp_dir!(), "responder-admission-eval-#{Ecto.UUID.generate()}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
