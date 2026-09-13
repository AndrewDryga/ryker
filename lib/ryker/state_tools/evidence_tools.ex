defmodule Ryker.StateTools.EvidenceTools do
  @moduledoc false

  alias Ryker.StateTools.RecordWriter

  @spec cite_source(map(), map()) :: {:ok, map()} | {:error, term()}
  def cite_source(arguments, binding) do
    relation = if arguments["relation"] == "context", do: nil, else: arguments["relation"]

    payload = %{
      "claim" => arguments["subject"],
      "claim_id" => RecordWriter.subject_ref("citation", arguments),
      "confidence" => nil,
      "dimensions" => %{},
      "freshness" => nil,
      "health_effect" => nil,
      "observation" => arguments["observation"],
      "observed_at" => nil,
      "relation" => relation,
      "scope_note" => nil,
      "source_id" => arguments["source_ref"],
      "source_name" => arguments["source_ref"],
      "source_type" => "other",
      "supersedes" => arguments["supersedes"],
      "target" => arguments["subject"]
    }

    RecordWriter.create_public_record(
      binding,
      "cite_source",
      arguments,
      "evidence",
      payload,
      "citation"
    )
  end

  @spec request_input(map(), map()) :: {:ok, map()} | {:error, term()}
  def request_input(arguments, binding) do
    questions = arguments["questions"]

    if arguments["remember"] && length(questions) != 1 do
      {:error, :invalid_arguments}
    else
      payload = %{
        "choices" => if(length(questions) == 1, do: hd(questions)["choices"], else: []),
        "question" => question_text(questions, arguments["context"])
      }

      payload =
        if arguments["remember"],
          do: Map.put(payload, "remember", arguments["remember"]),
          else: payload

      RecordWriter.create_record(binding, "request_input", arguments, "input_request", payload)
    end
  end

  @spec record_finding(map(), map()) :: {:ok, map()} | {:error, term()}
  def record_finding(arguments, binding),
    do: RecordWriter.create_record(binding, "record_finding", arguments, "finding", arguments)

  @spec wait_for(map(), map()) :: {:ok, map()} | {:error, term()}
  def wait_for(arguments, binding) do
    trigger = Map.put(arguments["trigger"], "on_timeout", arguments["on_timeout"])

    payload = %{
      "deadline_at" => arguments["deadline"],
      "event_matcher" => trigger,
      "kind" => arguments["trigger"]["type"],
      "verification" => arguments["verification"]
    }

    RecordWriter.create_record(binding, "wait_for", arguments, "event_wait", payload)
  end

  @spec record_feedback(map(), map()) :: {:ok, map()} | {:error, term()}
  def record_feedback(arguments, binding) do
    payload = %{
      "next_due_at" => nil,
      "phase" => "feedback:#{arguments["category"]}:#{arguments["sentiment"]}",
      "summary" => feedback_summary(arguments)
    }

    RecordWriter.create_public_record(
      binding,
      "record_feedback",
      arguments,
      "progress",
      payload,
      "feedback"
    )
  end

  defp question_text(questions, context) do
    body =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, index} -> "#{index}. #{question["text"]}" end)

    if is_binary(context), do: context <> "\n\n" <> body, else: body
  end

  defp feedback_summary(arguments) do
    [arguments["summary"], arguments["details"], arguments["response_question"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
