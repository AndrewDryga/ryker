defmodule Ryker.Evals.WeeklyReviewCase do
  @moduledoc "One frozen weekly evidence manifest, checked against the exact production contract without repair calls."
  alias Ryker.WeeklyReport.ReviewPrompt

  @enforce_keys [:eval_id, :manifest, :prompt, :schema]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def namespace, do: "weekly-review"
  def failure_reason, do: :invalid_weekly_recommendations

  def new(%{"evidence" => evidence} = manifest)
      when is_list(evidence) and length(evidence) <= 80 do
    {:ok,
     %__MODULE__{
       eval_id: "weekly-review-contract",
       manifest: manifest,
       prompt: ReviewPrompt.render(manifest),
       schema: ReviewPrompt.output_schema()
     }}
  end

  def new(_manifest), do: {:error, :invalid_weekly_review_manifest}

  def validate(eval, answer) do
    case ReviewPrompt.parse(answer, eval.manifest) do
      {:ok, recommendations} ->
        {:accept, %{passed: true, document: %{"recommendations" => recommendations}}}

      {:error, reason} ->
        # The production lane never repairs an invalid answer. Qualification
        # must not hide its first failure by buying another model call either.
        {:accept, %{passed: false, document: %{"error" => Atom.to_string(reason)}}}
    end
  end
end
