defmodule Ryker.Evals.LearningQuality do
  @moduledoc "Held-out memory questions, exact-value checks and source-grounded answer qualification."
  alias Ryker.Evals.{CoopRunner, WorldJudgeCase}

  @doc "An authored question and rubric; neither is sent to the learner."
  def probe("relative-dates") do
    %{
      question:
        "What exact UTC date and time did the recorded portal deployment reply promise as its monitoring deadline? Distinguish the deadline from the earlier fallback check and say whether the reply proves monitoring completed. Use history only.",
      checks: [
        {"deadline date is 10 September 2026",
         ~r/\b(?:2026-09-10|10(?:th)? September 2026|September 10(?:th)?,? 2026)(?!\d)/i},
        {"deadline time is 10:30 UTC",
         ~r/(?<![\d:])10:30(?::00(?:\.0+)?)?\s*(?:a\.?m\.?\s*)?(?:UTC\b|Z\b|\+00:00\b)/i}
      ],
      rubric:
        rubric([
          "Resolves tomorrow at 10:30 UTC in the source reply accepted on 2026-09-09 to 2026-09-10 at 10:30 UTC. The 10:45 UTC fallback check is a separate time, not the deadline.",
          "Attributes the deadline to the recorded promise. Does not claim the monitoring, apply or recovery actually completed; the source reply does not establish those outcomes."
        ])
    }
  end

  def probe("exact-values") do
    %{
      question:
        "What exact threshold and memory accounting did the auth/auth alert use? Give the UTC start and resolution times of the first occurrence, the start of the later occurrence, and what is still unverified. Use only the recorded conversation.",
      checks: [
        {"threshold is 95 percent", ~r/(?<![\d.])95(?:\.0+)?\s*(?:%|percent\b)/i},
        {"first occurrence started at 06:54:40", ~r/(?<![\d:])0?6:54:40\b/},
        {"first occurrence resolved at 07:13:40", ~r/(?<![\d:])0?7:13:40\b/},
        {"later occurrence started at 07:52:40", ~r/(?<![\d:])0?7:52:40\b/}
      ],
      rubric:
        rubric([
          "Preserves the threshold: resident memory plus swap exceed 95% of the limit, excluding reclaimable file cache. Does not substitute total memory, 95% usage observed, or a changed threshold.",
          "Keeps the 2026-09-02 occurrences separate: first started 06:54:40 UTC and resolved 07:13:40 UTC; later started 07:52:40 UTC. Message receipt times are not the event times.",
          "The later occurrence has no resolution in the supplied sources. The first resolved alert is not proof of later recovery, current health, a fixed leak or a raised limit."
        ])
    }
  end

  def probe("haproxy") do
    semantic(
      "What do we know about the website HAProxy OOM on nomad-hst01, and what does the later resolved alert establish or leave unverified? Answer from history; do not run infrastructure checks.",
      "Accurately describes the firing and resolved HAProxy alert from the original inputs, preserves their chronology, and does not treat resolution as proof of application recovery or a fixed root cause."
    )
  end

  def probe("auth-memory-recurrence") do
    semantic(
      "What is the latest recorded state of auth/auth resident-memory pressure on nomad-hst02, and how does it relate to the earlier firing and resolved alerts? Use history only and distinguish occurrences.",
      "The latest supplied alert is a later firing. The earlier firing and resolution are a separate occurrence; no supplied resolution establishes recovery of the later occurrence."
    )
  end

  def probe("draft-keep") do
    semantic(
      "What did the team decide about keeping draft-ai-suggestions, and why? Use the conversation history; do not change code or inspect live systems.",
      "Accurately states the decision to keep draft-ai-suggestions and the source-supported reason, respecting the difference between the initial question, explanation and final decision."
    )
  end

  def probe("starfall-correction") do
    semantic(
      "Was the Starfall release stuck, and what did the team clarify about how updates happen? Use history only and distinguish the initial concern from the later clarification.",
      "Preserves the initial concern and subsequent correction that updates happen manually. Does not assert the release was later deployed, tested or recovered without supporting sources."
    )
  end

  defp semantic(question, criterion),
    do: %{question: question, checks: [], rubric: rubric([criterion])}

  defp rubric(criteria), do: Enum.map(criteria, &%{"criterion" => &1, "weight" => 1})

  @doc "Whether the probe is bounded; a question alone intentionally remains unassessed."
  def valid?(%{question: question} = probe) when is_binary(question) do
    byte_size(question) in 1..4000 and
      Enum.all?(Map.get(probe, :checks, []), &match?({label, %Regex{}} when is_binary(label), &1)) and
      is_list(Map.get(probe, :rubric, []))
  end

  def valid?(_probe), do: false

  @doc "Checks exact values first; semantic correctness needs a completed, cleaned-up judge."
  def assess(probe, sources, answer, judge_options) when is_binary(answer) do
    checks =
      Enum.map(Map.get(probe, :checks, []), fn {label, pattern} ->
        %{criterion: label, passed: Regex.match?(pattern, answer)}
      end)

    cond do
      Enum.any?(checks, &(not &1.passed)) ->
        %{status: :failed, checks: checks, reason: :required_fact_missing, judgment: nil}

      is_nil(judge_options) or Map.get(probe, :rubric, []) == [] ->
        %{status: :unassessed, checks: checks, reason: :semantic_review_required, judgment: nil}

      true ->
        judge(probe, sources, answer, checks, judge_options)
    end
  end

  def assess(_probe, _sources, _answer, _judge_options),
    do: %{status: :unassessed, checks: [], reason: :answer_unavailable, judgment: nil}

  defp judge(probe, sources, answer, checks, options) do
    case WorldJudgeCase.learning(probe.question, sources, answer, probe.rubric) do
      {:ok, eval} ->
        judgment = CoopRunner.run_case(eval, options)

        request = %{
          prompt: eval.prompt,
          output_schema: eval.schema,
          job: Map.new(options)[:job]
        }

        status =
          if judgment.decision && is_nil(judgment.cleanup_error),
            do: judgment.status,
            else: :unassessed

        %{
          status: status,
          checks: checks,
          reason: judgment.reason,
          judgment: judgment,
          request: request
        }

      {:error, reason} ->
        %{status: :unassessed, checks: checks, reason: reason, judgment: nil}
    end
  end
end
