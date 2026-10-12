defmodule Ryker.Evals.WorldAdmissionCase do
  @moduledoc """
  A routing-tagged world's current admission decision, using the production
  prompt, source-specific schema and host validation. The isolated evaluation
  lane supplies the model; the case does not prescribe an expected route.
  """
  alias Ryker.Admission
  alias Ryker.Ingress

  @enforce_keys [:context, :eval_id, :prompt, :schema]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          context: Admission.Context.t(),
          eval_id: String.t(),
          prompt: String.t(),
          schema: map()
        }

  def namespace, do: "world-admission"
  def failure_reason, do: :admission_rejected

  @spec new(Admission.Context.t()) :: {:ok, t()} | {:error, term()}
  def new(%Admission.Context{} = context) do
    allowed_actions = Ingress.Input.allowed_actions(context.input)
    reaction_names = Ingress.Input.reaction_names(context.input)
    repository_bound? = is_binary(context.input_entry.repository_ref)
    repository_refs = Enum.map(context.repository_choices, & &1["ref"])
    sentiment_offered? = Admission.Context.sentiment_offered?(context)

    {:ok,
     %__MODULE__{
       context: context,
       eval_id: "world-admission:#{context.input_entry.id}",
       prompt: context |> Admission.Prompt.build() |> Admission.Prompt.render(),
       schema:
         Admission.Decision.json_schema(
           allowed_actions,
           reaction_names,
           repository_bound?,
           repository_refs,
           sentiment_offered?
         )
     }}
  end

  def new(_context), do: {:error, {:invalid_world_admission, :context}}

  @spec validate(t(), binary()) :: {:accept, map()} | {:reject, [String.t()]}
  def validate(%__MODULE__{context: context}, answer) when is_binary(answer) do
    with {:ok, %{} = document} <- Jason.decode(answer),
         {:ok, decision} <- Admission.Decision.parse(document),
         {:ok, _validated} <- Admission.validate(context, decision) do
      # Keep all decision fields and the optional sentiment, not a routing
      # replay's three-field comparison. World assertions score the outcome.
      {:accept, %{document: document, passed: true}}
    else
      {:error, reason} ->
        {:reject, ["Return an allowed admission decision: #{Admission.refusal(reason)}."]}

      _unreadable ->
        {:reject, ["Return one admission decision JSON object in the response format."]}
    end
  end

  def validate(_case, _answer),
    do: {:reject, ["Return one admission decision JSON object in the response format."]}
end
