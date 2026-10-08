defmodule Ryker.LocalRouting.Verdict do
  @moduledoc """
  What the local routing model's answer amounts to beside the decision the
  provider made and Ryker kept.

  The answer goes through exactly the checks routing puts a provider's answer
  through (`Ryker.Admission.Executor`): one JSON object, a well-formed
  decision (`Ryker.Admission.Decision.parse/1`), and a decision the frozen
  context allows (`Ryker.Admission.validate/2`). One that fails is invalid,
  and why is kept as a short code:

    * `empty` - no answer text
    * `cut_off` - the text stopped at the local server's token limit
    * `not_json` - the text is not one JSON object
    * `decision:<field>` - that field breaks the decision contract, such as
      `decision:fields` for a missing or unknown field
    * `rejected:<reason>` - routing's checks refuse the decision here, such
      as `rejected:unknown_candidate` for earlier work that was not offered

  A valid answer agrees when it would make Ryker do the same next: the same
  `action`, the same earlier work (`episode_ref`) in the same `relation`, the
  same `work_class`, the same `repository` and `repository_source` for new
  work, and the same emoji (`reactions`, in any order). The words of a quick
  reply (`messages`) and the `reason` are prose and are not compared: two
  greetings in other words are the same decision.
  """
  alias Ryker.Admission

  @compared ~w(action episode_ref relation work_class repository repository_source reactions)

  @type t :: %{
          valid: boolean(),
          agrees: boolean() | nil,
          differing_fields: [String.t()],
          invalid_reason: String.t() | nil
        }

  @spec judge(String.t() | nil, String.t() | nil, Admission.Context.t(), map()) :: t()
  def judge(content, finish_reason, %Admission.Context{} = context, provider)
      when is_map(provider) do
    with {:ok, document} <- decode(content, finish_reason),
         {:ok, decision} <- Admission.Decision.parse(document),
         {:ok, %{decision: decision}} <- Admission.validate(context, decision) do
      differing = differing(provider, Admission.Decision.document(decision))

      %{
        valid: true,
        agrees: differing == [],
        differing_fields: differing,
        invalid_reason: nil
      }
    else
      {:error, reason} ->
        %{valid: false, agrees: nil, differing_fields: [], invalid_reason: reason(reason)}
    end
  end

  @doc "The compared fields in which two decision documents differ."
  @spec differing(map(), map()) :: [String.t()]
  def differing(provider, local) do
    Enum.reject(@compared, &(same(&1, provider[&1]) == same(&1, local[&1])))
  end

  defp same("reactions", reactions) when is_list(reactions), do: Enum.sort(reactions)
  defp same(_field, value), do: value

  defp decode(content, _finish_reason) when content in [nil, ""], do: {:error, :empty}

  defp decode(content, finish_reason) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = document} -> {:ok, document}
      _other when finish_reason == "length" -> {:error, :cut_off}
      _other -> {:error, :not_json}
    end
  end

  defp decode(_content, _finish_reason), do: {:error, :not_json}

  defp reason(reason) when reason in [:empty, :cut_off, :not_json], do: Atom.to_string(reason)
  defp reason(reason), do: Admission.refusal(reason)
end
