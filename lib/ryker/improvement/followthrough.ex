defmodule Ryker.Improvement.Followthrough do
  @moduledoc "Observed correction use, kept distinct from a diagnosis or a saved instruction."
  alias Ryker.Behaviors
  alias Ryker.Improvement.Candidate
  alias Ryker.Records
  alias Ryker.Repo

  def correction_followthrough([]), do: %{}

  def correction_followthrough(candidates) do
    episode_ids = candidates |> Enum.map(& &1.episode_id) |> Enum.reject(&is_nil/1)

    corrections =
      episode_ids |> Behaviors.Behavior.Query.corrections_from_episodes() |> Repo.all()

    results =
      if corrections == [],
        do: [],
        else:
          corrections
          |> Enum.map(& &1.ref)
          |> Records.Record.Query.accepted_guidance_results()
          |> Repo.all()

    by_episode = Enum.group_by(corrections, & &1.payload["correction_source"]["episode_id"])

    Map.new(candidates, fn %Candidate{} = candidate ->
      {candidate.id, summarize(Map.get(by_episode, candidate.episode_id, []), results)}
    end)
  end

  defp summarize([], _results),
    do: %{
      state: :diagnosed,
      label: "Diagnosis has no verified repair recorded.",
      followed: 0,
      blocked: 0
    }

  defp summarize(corrections, results) do
    outcomes = for behavior <- corrections, outcome <- outcomes(behavior, results), do: outcome
    followed = Enum.count(outcomes, &(&1.state == :followed))
    blocked = Enum.count(outcomes, &(&1.state == :blocked))

    latest_states = Enum.map(corrections, &latest_state(&1, results))

    state = aggregate_state(latest_states)

    label =
      case state do
        :followed ->
          "Later delivered work includes evidence for every required correction output."

        :blocked ->
          "Later work recorded a blocked correction output; the requested result is still unverified."

        :accepted ->
          "Later work recorded all correction outputs; delivery is not yet verified."

        :not_applicable ->
          "Later work recorded why this correction did not apply to its task."

        :partial ->
          "Later work has not evidenced every correction output."

        :saved ->
          "Correction saved; no later delivered task has proved it yet."
      end

    %{state: state, label: label, followed: followed, blocked: blocked}
  end

  defp latest_state(behavior, results) do
    case Enum.max_by(outcomes(behavior, results), & &1.accepted_at, DateTime, fn -> nil end) do
      nil -> :saved
      outcome -> outcome.state
    end
  end

  defp aggregate_state(states) do
    cond do
      :blocked in states -> :blocked
      Enum.all?(states, &(&1 == :followed)) -> :followed
      Enum.all?(states, &(&1 == :saved)) -> :saved
      Enum.all?(states, &(&1 == :not_applicable)) -> :not_applicable
      Enum.all?(states, &(&1 in [:accepted, :followed])) -> :accepted
      true -> :partial
    end
  end

  defp outcomes(behavior, results) do
    requirements =
      Enum.map(
        behavior.payload["requirements"] || [],
        &Behaviors.required_output_ref(behavior, &1)
      )

    results
    |> Enum.filter(fn result ->
      result["payload"]["guidance_ref"] == behavior.ref and
        result["payload"]["revision"] == behavior.revision and
        result["episode_id"] != behavior.payload["correction_source"]["episode_id"]
    end)
    |> Enum.group_by(& &1["episode_id"])
    |> Enum.map(fn {_episode, observations} ->
      by_requirement =
        Enum.reduce(observations, %{}, fn result, kept ->
          Map.put_new(kept, result["payload"]["requirement_ref"], result)
        end)

      selected = Enum.map(requirements, &by_requirement[&1])

      state = observation_state(requirements, selected)

      %{state: state, accepted_at: hd(observations)["accepted_at"]}
    end)
  end

  defp observation_state(requirements, selected) do
    cond do
      Enum.any?(selected, &(&1 && &1["payload"]["status"] == "blocked")) -> :blocked
      requirements == [] or Enum.any?(selected, &is_nil/1) -> :partial
      Enum.all?(selected, &(&1["payload"]["status"] == "not_applicable")) -> :not_applicable
      Enum.any?(selected, &(&1["payload"]["status"] == "not_applicable")) -> :partial
      Enum.all?(selected, &delivered_output?/1) -> :followed
      true -> :accepted
    end
  end

  defp delivered_output?(result),
    do: result["payload"]["status"] == "satisfied" and not is_nil(result["delivered_at"])
end
