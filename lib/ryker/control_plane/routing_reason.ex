defmodule Ryker.ControlPlane.RoutingReason do
  @moduledoc """
  A routing decision's reason in the words a person reads.

  Routing used to explain itself in its own terms: "no candidate episode is
  available", "the message owned by the candidate". The prompt now asks for
  plain words, but stored reasons keep the old ones, so they are said plainly
  where they are shown, and a sentence that only says no earlier request was
  offered is left out. The stored decision itself never changes.
  """

  @nothing_offered "no (?:candidate|prior|existing) episodes? (?:is|are|was|were) (?:available|offered|provided|supplied)"

  # A clause ("…; no candidate episode is available.") or a whole sentence
  # ("No prior episode is offered.") that only says nothing earlier fit.
  @clause Regex.compile!("\\s*[;,]\\s*(?:and\\s+)?#{@nothing_offered}(?=[.!?]|$)", "iu")
  @sentence Regex.compile!("(?:^|(?<=[.!?]))\\s*#{@nothing_offered}[.!?]?", "iu")

  @words [
    {~r/\bowned by the candidate\b/iu, "that belongs to the earlier request"},
    {~r/\bowned by this episode\b/iu, "that belongs to this request"},
    {~r/\b(?:candidate|prior|existing|offered) episodes\b/iu, "earlier requests"},
    {~r/\b(?:candidate|prior|existing|offered) episode\b/iu, "earlier request"},
    {~r/\bcompleted episodes\b/iu, "finished requests"},
    {~r/\bcompleted episode\b/iu, "finished request"},
    {~r/\bepisodes\b/iu, "requests"},
    {~r/\bepisode\b/iu, "request"}
  ]

  @doc "The reason as a person reads it, or nil when nothing is left to say."
  @spec plain(String.t()) :: String.t() | nil
  def plain(reason) when is_binary(reason) do
    text =
      Enum.reduce(
        @words,
        reason |> String.replace(@clause, "") |> String.replace(@sentence, ""),
        fn {pattern, words}, text -> String.replace(text, pattern, words) end
      )
      |> String.trim()

    if text == "", do: nil, else: text
  end
end
