defmodule Ryker.Evals.RoutingReplayCase do
  @moduledoc """
  One recorded routing decision asked again under today's prompt and contract.

  Routing had no model eval: the world eval routes with a deterministic stand-in,
  so a change to routing's instructions or contract (the addressing wording, a
  sender's sentiment) could only be tried on live traffic. The routing
  examples Ryker keeps for training hold the exact request each decision was
  made on and what it decided (`Ryker.RoutingExamples.Export`). A replay case
  is one of them: the same context with the instructions today's routing gives
  it (`Ryker.Admission.Prompt.replay/1`), under the contract its source was
  offered, rebuilt with today's shapes (`Ryker.Admission.Decision.replay_schema/1`).

  An answer routing could not act on goes back for repair, as routing's own
  does. One it can act on passes when it makes Ryker do the same next as the
  recorded answer did: the same action, the same earlier work and the same
  relation to it. The words of a quick reply and the reason are not compared.
  """

  alias Ryker.Admission.{Decision, Prompt}

  @compared ~w(action episode_ref relation)

  @enforce_keys [:eval_id, :prompt, :schema, :recorded, :candidates, :labels]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          eval_id: String.t(),
          prompt: String.t(),
          schema: map(),
          recorded: map(),
          candidates: %{String.t() => [String.t()]},
          labels: map()
        }

  @doc "The name its sessions and operations carry (`Ryker.Evals.CoopRunner`)."
  def namespace, do: "routing-replay"

  @doc "Why a case that ran fails: the replayed decision differs from the recorded one."
  def failure_reason, do: :routing_changed

  @doc "A case from one line of the routing examples export, decoded."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{
        "messages" => [
          %{"role" => "user", "content" => prompt},
          %{"role" => "assistant", "content" => answer}
        ],
        "output_schema" => schema,
        "labels" => %{"example_id" => id} = labels
      })
      when is_binary(prompt) and is_binary(answer) and is_binary(id) do
    with {:ok, %{"context" => context} = request} when is_map(context) <- Jason.decode(prompt),
         {:ok, schema} <- Decision.replay_schema(schema),
         {:ok, %{} = decision} <- Jason.decode(answer),
         {:ok, recorded} <- compared(decision) do
      {:ok,
       %__MODULE__{
         eval_id: "routing-replay:#{id}",
         prompt: request |> Prompt.replay() |> Prompt.render(),
         schema: schema,
         recorded: recorded,
         candidates: candidates(context),
         labels: Map.take(labels, ~w(example_id request_ref decided_at model))
       }}
    else
      _invalid -> {:error, {:invalid_routing_example, id}}
    end
  end

  def new(_line), do: {:error, {:invalid_routing_example, nil}}

  @doc """
  The host's reading of one answer: accepted and scored when routing could act
  on it, or sent back with what to fix.
  """
  @spec validate(t(), binary()) :: {:accept, map()} | {:reject, [String.t()]}
  def validate(%__MODULE__{} = replay, answer) when is_binary(answer) do
    with {:ok, %{} = document} <- Jason.decode(answer),
         {:ok, decision} <- Decision.parse(document),
         {:ok, replayed} <- compared(Decision.document(decision)),
         :ok <- offered(replayed, replay.candidates) do
      {:accept, %{document: replayed, passed: replayed == replay.recorded}}
    else
      {:error, {:invalid_decision, field}} ->
        {:reject, ["Return a decision the response format allows; #{field} is not valid."]}

      {:error, :unknown_episode} ->
        {:reject, ["episode_ref must be the episode_ref of one of the candidates, or null."]}

      {:error, :relation_not_allowed} ->
        {:reject, ["relation must be one of the chosen candidate's allowed_relations."]}

      _unreadable ->
        {:reject, ["Return one decision JSON object in the response format."]}
    end
  end

  def validate(_replay, _answer),
    do: {:reject, ["Return one decision JSON object in the response format."]}

  # What an answer named, in the prompt's own candidate refs, which a replayed
  # answer names too: the export's decision label names the request it joined
  # instead. An answer leaves out an episode_ref it did not name.
  defp compared(%{"action" => action, "relation" => relation} = decision)
       when is_binary(action) and is_binary(relation),
       do: {:ok, Map.new(@compared, &{&1, Map.get(decision, &1)})}

  defp compared(_decision), do: {:error, :decision}

  # Each earlier work offered, with the relations routing may give it.
  defp candidates(context) do
    context
    |> Map.get("candidates", [])
    |> Map.new(&{&1["episode_ref"], &1["allowed_relations"] || []})
  end

  defp offered(%{"episode_ref" => nil}, _candidates), do: :ok

  defp offered(%{"episode_ref" => ref, "relation" => relation}, candidates) do
    case Map.fetch(candidates, ref) do
      {:ok, relations} ->
        if relation in relations, do: :ok, else: {:error, :relation_not_allowed}

      :error ->
        {:error, :unknown_episode}
    end
  end
end
