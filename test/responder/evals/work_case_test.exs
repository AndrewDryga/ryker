defmodule Responder.Evals.WorkCaseTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.WorkCase

  test "the recorded Work corpus compiles into the production prompt and final contract" do
    assert {:ok, cases} = WorkCase.all()
    assert length(cases) == 3
    assert Enum.uniq_by(cases, & &1.eval_id) == cases

    assert Enum.any?(cases, &(&1.eval_id == "github_and_slack_remain_platform_adapters"))

    for eval <- cases do
      document = WorkCase.document(eval)

      assert Map.keys(document) |> Enum.sort() ==
               ~w(eval_id expectation prompt reason schema source validation_context)

      assert document["prompt"]["instructions"] =~ "host-bound communication platform"
      assert document["schema"]["title"] == "Responder episode result"

      expected_tools =
        if document["prompt"]["work"]["offer_confirmation_supported"] do
          ~w(get_work_state cite_source request_input wait_for list_automations get_automation propose_automation request_task search_memory propose_memory update_conversation_summary record_feedback validate_final)
        else
          ~w(get_work_state cite_source request_input wait_for list_automations get_automation search_memory record_feedback validate_final)
        end

      assert document["prompt"]["work"]["responder_state_tools"] == expected_tools

      refute Map.has_key?(document["prompt"]["work"], "state_tools")
      refute Jason.encode!(document) =~ "SLACK_BOT_TOKEN"
      refute Jason.encode!(document) =~ "github_pat_"
    end
  end

  test "host-invalid output is repairable while a valid but wrong answer is scored" do
    eval = case_by_id!("direct_question_gets_a_visible_answer")

    silent = %{
      "decision_reason" => "No response is needed.",
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    assert {:reject, [violation]} = WorkCase.validate(eval, Jason.encode!(silent))
    assert violation =~ "explicit human request"

    wrong = complete_reply("The deploy needs one more check.")

    assert {:accept, accepted} = WorkCase.validate(eval, Jason.encode!(wrong))

    assert {:error,
            {:work_eval_mismatch, %{missing_message_terms: ["transaction"], submitted: submitted}}} =
             WorkCase.assess(eval, accepted)

    assert submitted["delivery"] == "reply"
    assert submitted["outcome"]["state"] == "complete"

    correct = complete_reply("Verify a representative transaction before calling it healthy.")
    assert {:accept, accepted} = WorkCase.validate(eval, Jason.encode!(correct))
    assert {:ok, final} = WorkCase.assess(eval, accepted)
    assert final.message =~ "transaction"
  end

  test "shadow evaluation uses the same host validator as production" do
    eval = case_by_id!("shadow_assessment_never_delivers")

    assert {:reject, [violation]} =
             WorkCase.validate(eval, Jason.encode!(complete_reply("Everything is healthy.")))

    assert violation =~ "observe-only shadow"

    silent = %{
      "decision_reason" => "Would verify the recorded operational evidence before reporting.",
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    assert {:accept, accepted} = WorkCase.validate(eval, Jason.encode!(silent))
    assert {:ok, final} = WorkCase.assess(eval, accepted)
    assert final.delivery == :none
  end

  test "malformed corpus documents fail before a model score can be reported" do
    assert WorkCase.compile(%{}) == {:error, {:invalid_work_eval, :fields}}
    assert WorkCase.compile(:invalid) == {:error, {:invalid_work_eval, :fields}}
    assert WorkCase.assess(:invalid, :invalid) == {:error, {:invalid_work_eval, :accepted}}

    invalid = valid_document() |> put_in(["expectation", "delivery"], "later")
    assert WorkCase.compile(invalid) == {:error, {:invalid_work_eval, :expectation}}

    invalid_documents = [
      put_in(valid_document(), ["eval_id"], "not a reference"),
      put_in(valid_document(), ["reason"], ""),
      put_in(valid_document(), ["source"], []),
      put_in(valid_document(), ["now"], "not-a-time"),
      put_in(valid_document(), ["now"], nil),
      put_in(valid_document(), ["context"], []),
      put_in(valid_document(), ["expectation"], []),
      put_in(valid_document(), ["expectation", "message_contains"], "transaction"),
      put_in(valid_document(), ["validation_context"], []),
      put_in(valid_document(), ["validation_context", "visible_reply_required"], "yes")
    ]

    assert Enum.all?(invalid_documents, &match?({:error, _reason}, WorkCase.compile(&1)))

    assert {:ok, _eval} =
             valid_document()
             |> put_in(["validation_context", "execution_mode"], "shadow")
             |> WorkCase.compile()

    duplicate = valid_document()
    path = write_jsonl!([duplicate, duplicate])

    assert WorkCase.all(path) ==
             {:error, {:invalid_work_eval_corpus, :duplicate_eval_id}}

    malformed = temporary_path()
    File.write!(malformed, "not-json\n")

    assert {:error, {:invalid_work_eval_file, ^malformed, 1, _reason}} = WorkCase.all(malformed)

    non_object = temporary_path()
    File.write!(non_object, "# sanitized fixture\n[]\n")

    assert WorkCase.all(non_object) ==
             {:error, {:invalid_work_eval_file, non_object, 2, :json_object_required}}

    invalid_case = temporary_path()
    File.write!(invalid_case, Jason.encode!(put_in(valid_document(), ["reason"], "")) <> "\n")

    assert {:error, {:invalid_work_eval_file, ^invalid_case, 1, _reason}} =
             WorkCase.all(invalid_case)

    missing = temporary_path()
    assert {:error, {:invalid_work_eval_file, ^missing, :enoent}} = WorkCase.all(missing)
  end

  test "forbidden behavioral terms fail after host-valid acceptance" do
    document =
      valid_document()
      |> put_in(["expectation", "message_excludes"], ["unverified"])

    assert {:ok, eval} = WorkCase.compile(document)
    answer = complete_reply("The transaction remains unverified.")
    assert {:accept, accepted} = WorkCase.validate(eval, Jason.encode!(answer))

    assert {:error, {:work_eval_mismatch, %{forbidden_message_terms: ["unverified"]}}} =
             WorkCase.assess(eval, accepted)
  end

  defp case_by_id!(id) do
    {:ok, cases} = WorkCase.all()
    Enum.find(cases, &(&1.eval_id == id)) || flunk("missing Work eval #{id}")
  end

  defp complete_reply(message) do
    %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    }
  end

  defp valid_document do
    WorkCase.all()
    |> elem(1)
    |> hd()
    |> WorkCase.source_document()
  end

  defp write_jsonl!(documents) do
    path = temporary_path()
    File.write!(path, Enum.map_join(documents, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp temporary_path do
    path = Path.join(System.tmp_dir!(), "responder-work-eval-#{Ecto.UUID.generate()}.jsonl")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
