defmodule Ryker.Work.CompletionReview.Result do
  @moduledoc "Validates retained reviewer results for historical inspection and source custody only."
  alias Ryker.{Maps, Reference}

  @decisions ~w(complete continue wait_for_event request_input)

  @doc "A well-formed judgment, or an invalid result; free-text completion never passes."
  def parse(text) when is_binary(text) and byte_size(text) <= 524_288 do
    with {:ok, %{} = result} <- Jason.decode(text),
         true <-
           Maps.exact_keys?(result, ~w(actions decision dismiss_wait_refs reason requirements)),
         true <- result["decision"] in @decisions and Reference.text?(result["reason"], 1_000),
         true <- requirements?(result["requirements"]),
         true <- actions?(result["actions"], result["decision"]),
         true <- dismissed?(result["dismiss_wait_refs"], result["decision"]),
         true <-
           result["decision"] != "complete" or
             Enum.all?(result["requirements"], &(&1["status"] == "satisfied")) do
      {:ok, result}
    else
      _invalid -> {:error, :invalid_completion_review}
    end
  end

  def parse(_text), do: {:error, :invalid_completion_review}

  defp dismissed?([], _decision), do: true

  defp dismissed?(refs, "continue") when is_list(refs) and length(refs) <= 8,
    do: length(Enum.uniq(refs)) == length(refs) and Enum.all?(refs, &Reference.valid?(&1, 256))

  defp dismissed?(_refs, _decision), do: false

  defp requirements?(requirements) when is_list(requirements) and length(requirements) in 1..12 do
    Enum.all?(requirements, fn item ->
      is_map(item) and Maps.exact_keys?(item, ~w(evidence requirement status)) and
        Reference.text?(item["requirement"], 500) and Reference.text?(item["evidence"], 1_000) and
        item["status"] in ~w(satisfied unresolved)
    end)
  end

  defp requirements?(_requirements), do: false
  defp actions?([], "complete"), do: true

  defp actions?(actions, decision)
       when is_list(actions) and length(actions) in 1..3 and decision != "complete" do
    Enum.all?(actions, fn item ->
      is_map(item) and Maps.exact_keys?(item, ~w(action basis requirement)) and
        Reference.text?(item["requirement"], 500) and Reference.text?(item["action"], 1_000) and
        Reference.text?(item["basis"], 1_000)
    end)
  end

  defp actions?(_actions, _decision), do: false
end
