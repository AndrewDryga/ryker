defmodule Ryker.ControlPlane.ExecutionTarget do
  @moduledoc """
  One presentation of a retained co:op execution target.

  The canonical value remains available for copying and configuration while
  operator surfaces receive labelled model, effort, provider and profile parts.
  Unknown shapes stay literal instead of being guessed into those roles.
  """

  @spec present(String.t() | nil) :: map()
  def present(nil), do: unrecorded("Model not recorded", nil)

  def present(target) when is_binary(target) do
    case parts(target) do
      %{provider: provider, model: model} = parts ->
        meta =
          [effort(parts.effort), provider(provider), profile(parts.profile)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        %{
          canonical: target,
          model: model,
          meta: empty_to_nil(meta),
          compact: Enum.join([model | if(meta == "", do: [], else: [meta])], " · "),
          parts: parts
        }

      nil ->
        unrecorded(target, target)
    end
  end

  @spec parts(String.t() | nil) :: map() | nil
  def parts(target) when is_binary(target) do
    with [head | profile] <- String.split(target, "@", parts: 2),
         true <- valid_profile?(profile),
         [provider, model] when provider != "" and model != "" <-
           String.split(head, ":", parts: 2),
         [model | effort] <- String.split(model, "/", parts: 2),
         false <- model == "" do
      %{
        provider: provider,
        model: model,
        effort: List.first(effort),
        profile: List.first(profile)
      }
    else
      _ -> nil
    end
  end

  def parts(_target), do: nil

  defp valid_profile?([]), do: true

  defp valid_profile?([value]),
    do: value != "" and not String.contains?(value, "@")

  defp unrecorded(label, canonical) do
    %{canonical: canonical, model: label, meta: nil, compact: label, parts: nil}
  end

  defp effort(nil), do: nil
  defp effort("none"), do: "No reasoning"
  defp effort(value), do: human(value) <> " reasoning"

  defp provider("codex"), do: "Codex"
  defp provider("openai"), do: "OpenAI"
  defp provider("anthropic"), do: "Anthropic"
  defp provider(value), do: human(value)

  defp profile(nil), do: nil
  defp profile(value), do: human(value) <> " profile"

  defp human(value) do
    value
    |> String.replace(~r/[_-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
