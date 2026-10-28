defmodule Ryker.Continuity.Relevance do
  @moduledoc """
  How much a remembered text shares with the request it may be shown beside: the identifiers
  both name, read as routing reads them (`Ryker.Episodes.RoutingDigests`), which count most,
  then the words both use.

  A briefing chose its conversation notes and related summaries by how recent they were, so a
  note about the host a person asked after lost its place to lunch plans written later (the
  token-cost plan, 2026-09-30: "irrelevant recent chatter loses to applicable older
  knowledge"). Automatic recall requires an exact identifier or multiple meaningful shared words. A
  shared broad name alone is not enough. Empty requests recall no unrelated history; current
  thread continuity and explicit memory search have their own paths.
  """
  alias Ryker.Episodes

  @identifier_weight 3

  @type request :: %{identifiers: MapSet.t(String.t()), words: MapSet.t(String.t())}

  @spec request([String.t()]) :: request()
  def request(texts) do
    texts = Enum.filter(texts, &is_binary/1)

    %{
      identifiers: texts |> Episodes.RoutingDigests.identifiers() |> MapSet.new(),
      words: texts |> Enum.map(&words/1) |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    }
  end

  # Words that say nothing about a subject on their own.
  @filler ~w(the and for with this that from was were are is has have had not but you your our
    can will would could should been being into onto about again still now just also any all
    some what when where which who why how there here they them their its it's i'm we're
    please thanks thank hey hello okay yes see look looking keep need needs want wants help
    check checking get got getting make made say said tell told know think like use using used
    something anything everything thing things quick quickly explain question answer
    status update updated success successful succeeded failed failure healthy health production
    staging environment workspace repository notification utc today yesterday)

  # Split at every mark, so website/haproxy-edge shares haproxy with a question about
  # "haproxy-edge", and OOM-killed shares oom with "OOM".
  defp words(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(text |> String.slice(0, 8_192) |> String.replace(~r{https?://\S+}u, " "))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @filler or Regex.match?(~r/^\d+$/, &1)))
    |> MapSet.new()
  end

  @spec score(String.t(), request()) :: non_neg_integer()
  def score(text, %{identifiers: identifiers, words: words}) when is_binary(text) do
    shared_identifiers =
      [text]
      |> Episodes.RoutingDigests.identifiers()
      |> MapSet.new()
      |> MapSet.intersection(identifiers)

    shared_words = text |> words() |> MapSet.intersection(words)

    @identifier_weight * MapSet.size(shared_identifiers) + MapSet.size(shared_words)
  end

  def score(_text, _request), do: 0

  @doc "Whether a candidate has enough subject overlap to enter automatic recall."
  @spec related?(String.t(), request()) :: boolean()
  def related?(text, %{identifiers: identifiers, words: words}) when is_binary(text) do
    candidate = request([text])
    shared = MapSet.intersection(candidate.words, words)

    not MapSet.disjoint?(candidate.identifiers, identifiers) or
      MapSet.size(shared) >= 2
  end

  def related?(_text, _request), do: false

  @doc "Relevant items first by shared subject, preserving input order for equal scores."
  @spec rank([term()], request(), (term() -> String.t())) :: [term()]
  def rank(items, request, text) do
    items
    |> Enum.filter(&related?(text.(&1), request))
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {-score(text.(item), request), index} end)
    |> Enum.map(&elem(&1, 0))
  end
end
