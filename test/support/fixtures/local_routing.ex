defmodule Ryker.Fixtures.LocalRouting do
  @moduledoc """
  Real routing answers for the local routing model's shadow comparisons.

  Harvested read-only on 2026-09-27 from the live install's
  `admission_attempts.response` and `execution_usage`: exactly what
  gpt-5.6-sol answered to three Chat messages, and what that call measured;
  and on 2026-09-30 from `local_routing_comparisons.local_answer`, what the
  first local model answered. None of them is invented; each test that needs a local model's answer uses
  one a model really gave.
  """

  @doc """
  The message the provider answered with `hi_quick_reply/0`, from Chat on
  2026-09-27 14:53 UTC (attempt 42a03ce8).
  """
  def hi_text, do: "hi, reply with one word please"

  @doc "gpt-5.6-sol's answer to `hi_text/0`: a quick reply, in the current contract."
  def hi_quick_reply,
    do:
      ~s({"action":"quick_reply","episode_ref":null,"messages":["Hi!"],"reactions":null,"relation":"unrelated","reason":"The person greeted Ryker and requested a one-word reply.","repository":null,"repository_source":null,"work_class":null})

  @doc """
  The answer to "hi again" (attempt 3a6ad168, 2026-09-26 18:01 UTC) as the
  host accepted it: the same kind of decision as `hi_quick_reply/0` in other
  words and with another reason.
  """
  def hi_again_quick_reply,
    do:
      ~s({"action":"quick_reply","episode_ref":null,"messages":["Hi again! What can I help with?"],"reactions":null,"reason":"A greeting directed at Ryker needs only a brief reply.","relation":"unrelated","repository":null,"repository_source":null,"work_class":null})

  @doc """
  The same "hi again" answer exactly as the model wrote it, in the contract of
  the day, with `message` and `reaction`: today's routing checks refuse it,
  as they would a local model that ignored the schema.
  """
  def hi_again_old_contract,
    do:
      ~s({"action":"quick_reply","episode_ref":null,"message":"Hi again! What can I help with?","reaction":null,"relation":"unrelated","reason":"A greeting directed at Ryker needs only a brief reply.","repository":null,"repository_source":null,"work_class":null})

  @doc """
  gpt-5.6-luna's answer to "Look at scripts/deploy.sh in the ryker repository
  and tell me in two sentences what it does before it replaces the
  container." (attempt b733602e, 2026-09-27 14:54 UTC): a reply, as
  conversation work.
  """
  def deploy_script_reply,
    do:
      ~s({"action":"reply","episode_ref":null,"messages":null,"reactions":null,"relation":"unrelated","reason":"This is a small, focused lookup: read scripts/deploy.sh and summarize what it does before replacing the container in two sentences.","repository":null,"repository_source":null,"work_class":"conversational"})

  @doc """
  qwen2.5:3b's answer to "Which repositories can you read in this
  environment?" in the first comparison on the live install (2026-09-30,
  served by scripts/routing-model-service.sh; the provider chose a quick
  reply). It starts work on earlier work named `same_work`, which routing
  never offered, so routing's checks refuse it (`rejected:unknown_candidate`).
  """
  def made_up_earlier_work,
    do:
      ~s({"action":"start_episode","episode_ref":"same_work","messages":null,"reactions":null,"reason":"The input asks for a list of repositories that can be read in the environment. This is a request for information and does not require any investigation or action. The current conversation does not contain any prior work or requests that would need to be handled. Therefore, the appropriate action is to provide the requested information without starting any new work. The environment's repositories can be read from the provided repository_choices list.","relation":"history_only","repository":"andrewdryga-ryker","repository_source":{"kind":"default"},"work_class":"standard"})

  @doc "The model that gave `hi_again_quick_reply/0`, as its session reported it."
  def provider_target, do: "codex:gpt-5.6-sol/medium@default"

  @doc """
  What that routing call reported: 5,543 fresh and 12,160 cached input
  tokens, 64 output tokens, and 16.77 s in the model. Codex reports no cost,
  so the saved gpt-5.6-sol price estimates it: $0.028316.
  """
  def provider_report do
    %{
      "usage" => %{
        "input_tokens" => 5_543,
        "cached_input_tokens" => 12_160,
        "output_tokens" => 64,
        "reasoning_tokens" => 0
      },
      "queued_at" => "2026-09-26T18:01:09.625381Z",
      "started_at" => "2026-09-26T18:01:09.628776Z",
      "finished_at" => "2026-09-26T18:01:26.399360Z"
    }
  end

  def provider_ms, do: 16_770
  def provider_cost_usd, do: Decimal.new("0.028316")
end
