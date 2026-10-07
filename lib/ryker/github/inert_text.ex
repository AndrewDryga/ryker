defmodule Ryker.GitHub.InertText do
  @moduledoc """
  A model's text made inert before it reaches GitHub. An `@login` there
  notifies that person; `#12`, `owner/repo#12` and `GH-12` link an issue or
  pull request and add a backlink to its timeline, and "Fixes #12" in a pull
  request closes issue 12 when it merges. A zero-width space after `@` and
  `#`, and inside `GH-`, keeps the words readable and stops all of them.

  Until 2026-10-07 replies and pull requests stopped only `@`, each with a
  copy of their own, and a review the model submitted stopped nothing
  (2026-10-04 review).
  """

  @doc "`text` with no mention or issue reference GitHub would act on."
  @spec inert(String.t()) :: String.t()
  def inert(text) when is_binary(text) do
    text
    |> String.replace("@", "@\u200B")
    |> String.replace(~r/#(?=\d)/u, "#\u200B")
    |> then(&Regex.replace(~r/\b(gh)-(?=\d)/iu, &1, "\\1\u200B-"))
  end
end
