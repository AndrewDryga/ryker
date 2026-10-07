defmodule Ryker.Evals.ImprovementReplayCase do
  @moduledoc """
  One recorded self-analysis asked again under today's instructions and contract.

  Ryker analyzes a request a person was unhappy with (`Ryker.Improvement`), and each analysis run
  keeps the exact prompt it sent and the answer it accepted. A replay case is one of them: the
  same evidence under the instructions today's analysis gives (`Ryker.Improvement.Prompt`), and
  today's output contract. The self-analysis prompt had no model eval: its first run on live was
  on 2026-09-30, once a task's rating could be analyzed at all.

  An answer the host could not keep goes back for repair, as the analysis's own does. One it can
  keep passes when it puts the fault in the same place as the recorded answer: the same category
  and the same step. The words and the confidence are reported, not compared.
  """
  alias Ryker.Improvement.Prompt

  @compared [:category, :step]

  @enforce_keys [:eval_id, :prompt, :schema, :recorded]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          eval_id: String.t(),
          prompt: String.t(),
          schema: map(),
          recorded: map()
        }

  @doc "The name its sessions and operations carry (`Ryker.Evals.CoopRunner`)."
  def namespace, do: "improvement-replay"

  @doc "Why a case that ran fails: the replayed diagnosis differs from the recorded one."
  def failure_reason, do: :diagnosis_changed

  @doc "A case from one recorded analysis run: its id, the prompt it sent and its result."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{"run_id" => id, "prompt" => prompt, "result" => result})
      when is_binary(id) and is_binary(prompt) and is_binary(result) do
    with {:ok, %{"context" => context}} when is_map(context) <- Jason.decode(prompt),
         {:ok, diagnosis} <- Prompt.parse(result) do
      {:ok,
       %__MODULE__{
         eval_id: "improvement-replay:#{id}",
         prompt: Prompt.render(%{"instructions" => Prompt.instructions(), "context" => context}),
         schema: Prompt.output_schema(),
         recorded: compared(diagnosis)
       }}
    else
      _invalid -> {:error, {:invalid_improvement_run, id}}
    end
  end

  def new(_run), do: {:error, {:invalid_improvement_run, nil}}

  @doc """
  The host's reading of one answer: accepted and scored when it could be kept, or sent back.
  """
  @spec validate(t(), binary()) :: {:accept, map()} | {:reject, [String.t()]}
  def validate(%__MODULE__{} = replay, answer) when is_binary(answer) do
    case Prompt.parse(answer) do
      {:ok, diagnosis} ->
        replayed = compared(diagnosis)

        {:accept,
         %{
           document: Map.put(replayed, "confidence", Atom.to_string(diagnosis.confidence)),
           passed: replayed == replay.recorded
         }}

      {:error, _invalid} ->
        {:reject, [Prompt.correction()]}
    end
  end

  def validate(_replay, _answer),
    do: {:reject, ["Return one analysis JSON object in the response format."]}

  defp compared(diagnosis),
    do: Map.new(@compared, &{Atom.to_string(&1), Atom.to_string(Map.fetch!(diagnosis, &1))})
end
