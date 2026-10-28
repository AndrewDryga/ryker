defmodule Ryker.Work.GuidanceRequirements do
  @moduledoc "Required outputs of the exact correction guidance a turn was briefed with."
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Work

  @doc "Current required outputs, with this turn's newest evidence-backed result, for validation."
  def context(%Work.Turn{} = turn) do
    case Repo.fetch(Episodes.Episode.Query.by_id(turn.episode_id)) do
      {:ok, %Episodes.Episode{execution_mode: :live}} -> live_context(turn)
      _shadow_or_missing -> []
    end
  end

  defp live_context(turn) do
    results =
      Records.guidance_results(turn.episode_id, turn.id)
      |> Map.new(&{&1.payload["requirement_ref"], &1})

    for requirement <- Behaviors.required_outputs(turn) do
      result = results[requirement["requirement_ref"]]

      requirement
      |> Map.put("result", if(result, do: Map.put(result.payload, "record_ref", result.ref)))
    end
  end

  @doc "A result may name only a current required output in this turn's frozen briefing."
  def authorize(%Work.Turn{} = turn, payload) do
    if Enum.any?(Behaviors.required_outputs(turn), fn requirement ->
         requirement["requirement_ref"] == payload["requirement_ref"] and
           requirement["guidance_ref"] == payload["guidance_ref"] and
           requirement["revision"] == payload["revision"]
       end), do: :ok, else: {:error, :guidance_requirement_stale}
  end

  @doc "Reject malformed host validation context rather than trusting partial result shapes."
  def valid_context?(requirements) when is_list(requirements) and length(requirements) <= 4_000 do
    Enum.all?(requirements, fn
      %{} = requirement ->
        Maps.exact_keys?(
          requirement,
          ~w(description guidance_ref requirement_ref result revision)
        ) and
          Enum.all?(~w(guidance_ref requirement_ref), &Reference.token?(requirement[&1])) and
          Reference.text?(requirement["description"], 1_000) and
          is_integer(requirement["revision"]) and requirement["revision"] > 0 and
          valid_result?(requirement["result"], requirement)

      _ ->
        false
    end)
  end

  def valid_context?(_requirements), do: false

  defp valid_result?(nil, _requirement), do: true

  defp valid_result?(%{} = result, requirement) do
    Maps.exact_keys?(
      result,
      ~w(detail evidence_refs guidance_ref record_ref requirement_ref revision status)
    ) and
      result["status"] in ~w(satisfied blocked not_applicable) and
      Reference.token?(result["record_ref"]) and
      Reference.text?(result["detail"], 2_000) and
      Map.take(result, ~w(guidance_ref requirement_ref revision)) ==
        Map.take(requirement, ~w(guidance_ref requirement_ref revision)) and
      is_list(result["evidence_refs"]) and length(result["evidence_refs"]) in 1..12 and
      Enum.all?(result["evidence_refs"], &Reference.token?/1)
  end

  defp valid_result?(_result, _requirement), do: false

  @doc "Deterministic result coverage; prose quality belongs to the recorded world evaluation."
  def violations(requirements, final) do
    output =
      if reply_required?(requirements) and final.delivery != :reply,
        do: [
          "Communicate the required correction outputs and any blocked results in the final reply."
        ],
        else: []

    output ++ Enum.flat_map(requirements, &requirement_violations(&1, final))
  end

  defp reply_required?(requirements),
    do: Enum.any?(requirements, &(get_in(&1, ["result", "status"]) != "not_applicable"))

  defp requirement_violations(
         %{"result" => %{"record_ref" => reference, "evidence_refs" => evidence}},
         final
       )
       when evidence != [] do
    if reference in final.record_refs and Enum.all?(evidence, &(&1 in final.record_refs)),
      do: [],
      else: [
        "Include the guidance result #{reference} and its supporting evidence in outcome.record_refs."
      ]
  end

  defp requirement_violations(requirement, _final) do
    [
      "Record the required correction output #{requirement["requirement_ref"]}: #{requirement["description"]}. Use record_guidance_result with supporting cite_source records, or an evidenced blocked result explaining the missing source and attempted alternatives. A completed goal does not satisfy this output."
    ]
  end
end
