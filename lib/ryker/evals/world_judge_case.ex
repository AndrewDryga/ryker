defmodule Ryker.Evals.WorldJudgeCase do
  @moduledoc """
  Bounded, tool-free quality judgment for one completed model-world run.

  Hard safety and trajectory assertions are evaluated before this case exists.
  The judge can only score the human-language rubric; it cannot override a host
  failure or invent source evidence.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Evals.WorldCase

  @maximum_prompt_bytes 192 * 1_024
  @maximum_reason_characters 1_024
  @fields ~w(criteria overall_pass)
  @criterion_fields ~w(index passed reason)

  @enforce_keys [:eval_id, :prompt, :rubric, :schema]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          eval_id: String.t(),
          prompt: String.t(),
          rubric: [map()],
          schema: map()
        }

  @spec new(WorldCase.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(%WorldCase{} = scenario, %{} = report) do
    rubric = scenario.expect["quality_rubric"]

    prompt_document = %{
      "evidence" => evidence(scenario, report),
      "instructions" => [
        "Judge only the delivered human-language result against each rubric criterion.",
        "Treat trusted source events, source calls, state calls, and durable records as the complete evidence boundary.",
        "Input clocks separate historical source dates from simulated host receipt and wakeup times. Judge source chronology using original source dates; shifted receipt times do not date a deployment or establish present-day health.",
        "Do not override host safety or trajectory checks and do not reward unsupported claims.",
        "Return exactly one criterion result for every zero-based rubric index."
      ],
      "rubric" => rubric,
      "scenario_id" => scenario.id
    }

    with :ok <- nonempty_rubric(rubric),
         :ok <- CanonicalJSON.validate(prompt_document, max_bytes: @maximum_prompt_bytes) do
      {:ok,
       %__MODULE__{
         eval_id: "world-judge:#{scenario.id}",
         prompt: CanonicalJSON.encode!(prompt_document),
         rubric: rubric,
         schema: schema(length(rubric))
       }}
    else
      {:error, _reason} -> {:error, {:invalid_world_judge, :prompt}}
    end
  end

  def new(_scenario, _report), do: {:error, {:invalid_world_judge, :fields}}

  @spec validate(t(), binary()) :: {:accept, map()} | {:reject, [String.t()]}
  def validate(%__MODULE__{} = judge, candidate) when is_binary(candidate) do
    with {:ok, %{} = document} <- Jason.decode(candidate),
         :ok <- exact_fields(document, @fields),
         true <- is_boolean(document["overall_pass"]),
         {:ok, criteria} <- criteria(document["criteria"], length(judge.rubric)),
         true <- document["overall_pass"] == Enum.all?(criteria, & &1["passed"]) do
      {:accept, %{document: document, passed: document["overall_pass"]}}
    else
      {:error, :criterion_identity} ->
        {:reject, ["Return every rubric criterion index exactly once."]}

      {:error, reason} ->
        {:reject, ["Return a valid bounded quality judgment: #{inspect(reason)}."]}

      false ->
        {:reject, ["overall_pass must equal whether every criterion passed."]}

      _invalid ->
        {:reject, ["Return one valid quality judgment JSON object."]}
    end
  end

  def validate(_judge, _candidate),
    do: {:reject, ["Return one valid quality judgment JSON object."]}

  defp evidence(%WorldCase{} = scenario, report) do
    %{
      "deliveries" => sanitize(report[:deliveries]),
      "records" => sanitize(report[:records]),
      "input_clocks" => sanitize(input_clocks(report)),
      "source_events" => sanitize(scenario.events),
      "source_calls" => sanitize(report[:source_calls]),
      "state_calls" => sanitize(state_calls(report))
    }
  end

  defp input_clocks(%{runtime: %{turns: turns}}), do: Enum.map(turns, & &1.input_clock)
  defp input_clocks(_report), do: []

  defp state_calls(%{runtime: %{state_calls: calls}}), do: calls
  defp state_calls(_report), do: []

  defp sanitize(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp criteria(criteria, count) when is_list(criteria) and length(criteria) == count do
    valid = Enum.all?(criteria, &criterion?(&1, count))

    indices = Enum.map(criteria, & &1["index"])

    cond do
      not valid -> {:error, :criteria}
      Enum.sort(indices) != Enum.to_list(0..(count - 1)) -> {:error, :criterion_identity}
      true -> {:ok, criteria}
    end
  end

  defp criteria(_criteria, _count), do: {:error, :criterion_identity}

  defp criterion?(%{"index" => index, "passed" => passed, "reason" => reason} = criterion, count)
       when map_size(criterion) == 3 and is_integer(index) and is_boolean(passed) and
              is_binary(reason) do
    Enum.all?([
      index in 0..(count - 1),
      String.valid?(reason),
      String.trim(reason) != "",
      String.length(reason) <= @maximum_reason_characters,
      :binary.match(reason, <<0>>) == :nomatch
    ])
  end

  defp criterion?(_criterion, _count), do: false

  defp nonempty_rubric(rubric) when is_list(rubric) and rubric != [] and length(rubric) <= 32,
    do: :ok

  defp nonempty_rubric(_rubric), do: {:error, :rubric}

  defp exact_fields(document, fields) do
    if Enum.sort(Map.keys(document)) == Enum.sort(fields), do: :ok, else: {:error, :fields}
  end

  defp schema(count) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "additionalProperties" => false,
      "properties" => %{
        "criteria" => %{
          "items" => %{
            "additionalProperties" => false,
            "properties" => %{
              "index" => %{"maximum" => count - 1, "minimum" => 0, "type" => "integer"},
              "passed" => %{"type" => "boolean"},
              "reason" => %{
                "maxLength" => @maximum_reason_characters,
                "minLength" => 1,
                "type" => "string"
              }
            },
            "required" => @criterion_fields,
            "type" => "object"
          },
          "maxItems" => count,
          "minItems" => count,
          "type" => "array"
        },
        "overall_pass" => %{"type" => "boolean"}
      },
      "required" => @fields,
      "title" => "Ryker model-world quality judgment",
      "type" => "object"
    }
  end
end
