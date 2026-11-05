defmodule Ryker.Evals.ReactionConversation do
  @moduledoc """
  Replays the screenshot's exchange through today's admission model, then
  judges its conversational choices. Earlier accepted choices become an inert
  simulated transcript for the next input. No Slack publisher, Work run or
  real reaction is involved; this qualifies model choices, not delivery.
  """
  alias Ryker.Admission
  alias Ryker.CanonicalJSON
  alias Ryker.Evals.{CoopRunner, WorldAdmissionCase, WorldJudgeCase}
  alias Ryker.Ingress
  alias Ryker.Slack

  @fixture "testdata/admission/reactions/screenshot-exchange.json"

  @doc "Runs the recorded exchange and its judge on the source-free evaluation worker."
  @spec run(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(subject_options, judge_options) do
    with {:ok, bytes} <- File.read(@fixture),
         {:ok, corpus} <- Jason.decode(bytes),
         {:ok, start, 0} <- DateTime.from_iso8601(corpus["start"]),
         {:ok, choices} <- choose(corpus, start, subject_options),
         {:ok, report} <- assess(corpus, choices, judge_options) do
      {:ok,
       Map.merge(report, %{
         generated_at: DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
         requested_targets: %{routing: target(subject_options), judge: target(judge_options)}
       })}
    end
  end

  defp target(options) do
    case Keyword.get(options, :job) do
      %{document: %{"targets" => [target]}} -> target
      _unconfigured -> nil
    end
  end

  defp assess(corpus, choices, judge_options) do
    failures = hard_failures(choices)
    report = %{provenance: corpus["provenance"], choices: choices, hard_failures: failures}

    if failures == [] do
      with {:ok, judge} <- WorldJudgeCase.conversation(corpus, choices) do
        quality = CoopRunner.run_case(judge, judge_options)
        {:ok, Map.merge(report, %{quality: quality, passed: passed?(quality)})}
      end
    else
      {:ok, Map.merge(report, %{quality: %{status: :unrun}, passed: false})}
    end
  end

  defp choose(corpus, start, options) do
    corpus["messages"]
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], []}, &choose_next(&1, &2, corpus, start, options))
    |> case do
      {:ok, _history, choices} -> {:ok, choices}
      result -> result
    end
  end

  defp choose_next({message, index}, {:ok, history, choices}, corpus, start, options) do
    at = DateTime.add(start, message["offset_seconds"], :second)

    with {:ok, context} <- context(message, index, at, history, corpus),
         {:ok, eval} <- WorldAdmissionCase.new(context) do
      result = CoopRunner.run_case(eval, options)
      choice = %{input: message, result: result}

      if passed?(result) do
        history = simulate(history, context.input, result.decision, at)
        {:cont, {:ok, history, choices ++ [choice]}}
      else
        {:halt, {:ok, choices ++ [choice]}}
      end
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp context(message, index, at, history, corpus) do
    message_ref = "#{DateTime.to_unix(at)}.000100"

    with {:ok, input} <-
           Slack.Input.new(%{
             actor: %{kind: :user, ref: message["actor"]},
             channel_ref: "CEVAL",
             content: %{"text" => message["text"]},
             event_kind: :message,
             event_ref: "Ev-reaction-conversation-#{index}",
             message_ref: message_ref,
             occurred_at: at,
             revision: 1,
             thread_ref: "1793822400.000100",
             workspace_ref: "TEVAL"
           }) do
      {:ok,
       %Admission.Context{
         active_episode_fingerprint: CanonicalJSON.digest([]),
         built_at: at,
         candidates: [],
         conversation_episode_count: 0,
         input: input,
         input_entry: %Ingress.Inbox.Entry{
           id: Ecto.UUID.generate(),
           execution_mode: :live,
           slack_audience: :ambient,
           slack_bot_user_ref: corpus["slack_addressing"]["ryker_user_ref"]
         },
         slack_addressing: corpus["slack_addressing"],
         conversation_context: %{"messages" => history, "custom_emoji" => corpus["custom_emoji"]},
         context_manifest: %{"included" => length(history), "requested" => 20}
       }}
    end
  end

  defp simulate(history, input, decision, at) do
    delivered_at = at |> DateTime.add(1, :microsecond) |> DateTime.to_iso8601()

    reactions =
      Enum.map(decision["reactions"] || [], fn emoji ->
        %{"action" => "add", "emoji" => emoji, "at" => delivered_at}
      end)

    message = %{
      "actor_ref" => Ingress.Input.actor_ref(input),
      "occurred_at" => DateTime.to_iso8601(at),
      "content" => input.content,
      "ryker_reactions" => reactions
    }

    replies =
      Enum.map(decision["messages"] || [], fn text ->
        %{"actor_ref" => "ryker", "occurred_at" => delivered_at, "content" => %{"text" => text}}
      end)

    history ++ [message] ++ replies
  end

  defp hard_failures(choices) do
    Enum.flat_map(choices, fn choice ->
      cond do
        not passed?(choice.result) ->
          ["An admission turn failed or did not clean up."]

        choice.result.decision["action"] not in ~w(react ignore quick_reply) ->
          ["An exchange between people started tool-backed work."]

        true ->
          []
      end
    end)
  end

  defp passed?(%{status: :passed, cleanup_error: nil}), do: true
  defp passed?(_result), do: false
end
