defmodule Ryker.Work.ExecutionTarget do
  @moduledoc """
  One presentation of a retained co:op execution target.

  The canonical value remains available for copying and configuration while
  operator surfaces receive labelled model, effort, provider and account parts.
  Unknown shapes stay literal instead of being guessed into those roles.

  A kind of work saves a list of targets, its model and then the fallbacks
  Coop moves to in order; a list reads as its first target, then each fallback.
  """

  @spec present(String.t() | [String.t()] | nil) :: map()
  def present(nil), do: unrecorded("Model not recorded", nil)
  def present([]), do: present(nil)
  def present([target]), do: present(target)

  # A list is kept as Coop writes a ladder back: its targets joined by spaces.
  def present([_first | _fallbacks] = targets) do
    [first | _rest] = presentations = Enum.map(targets, &present/1)

    %{
      first
      | canonical: Enum.join(targets, " "),
        compact: Enum.map_join(presentations, ", then ", & &1.compact)
    }
  end

  def present(target) when is_binary(target) do
    case parts(target) do
      %{provider: provider, model: model} = parts ->
        meta =
          [effort(parts.effort), provider_name(provider), account(parts.account)]
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
    with [head | account] <- String.split(target, "@", parts: 2),
         true <- valid_account?(account),
         [provider, model] when provider != "" and model != "" <-
           String.split(head, ":", parts: 2),
         [model | effort] <- String.split(model, "/", parts: 2),
         false <- model == "" do
      %{
        provider: provider,
        model: model,
        effort: List.first(effort),
        account: List.first(account)
      }
    else
      _ -> nil
    end
  end

  def parts(_target), do: nil

  defp valid_account?([]), do: true

  defp valid_account?([value]),
    do: value != "" and not String.contains?(value, "@")

  defp unrecorded(label, canonical) do
    %{canonical: canonical, model: label, meta: nil, compact: label, parts: nil}
  end

  defp effort(nil), do: nil
  defp effort("none"), do: "No reasoning"
  defp effort(value), do: effort_name(value) <> " reasoning"

  @doc """
  A reasoning effort in the words Settings and every filter use: "Extra
  high", never the configuration's "xhigh".
  """
  @spec effort_name(String.t()) :: String.t()
  def effort_name("none"), do: "No reasoning"
  def effort_name("xhigh"), do: "Extra high"
  def effort_name(value), do: human(value)

  @doc "A provider in the words every page uses: Codex, Claude."
  @spec provider_name(String.t()) :: String.t()
  def provider_name("codex"), do: "Codex"
  def provider_name("openai"), do: "OpenAI"
  def provider_name("anthropic"), do: "Anthropic"
  def provider_name(value), do: human(value)

  defp account(nil), do: nil
  defp account(value), do: human(value) <> " account"

  defp human(value) do
    value
    |> String.replace(~r/[_-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
