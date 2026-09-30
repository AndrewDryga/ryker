defmodule Ryker.Ingress.RecallText do
  @moduledoc """
  Meaningful, bounded search text; the submitted source document remains unchanged.

  A message is searched by its own text (`Ryker.Ingress.MessageText`), so a
  Slack message counts its words once, as the timeline shows it. Any other
  payload is searched by its titles, bodies and descriptions.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.MessageText

  # A voice message's transcript is what it said; one Ryker could not
  # transcribe says so.
  @fields ~w(title text transcript transcript_unavailable body description summary fallback)
  @part_characters 512

  def from(content) do
    case MessageText.parts(content) do
      nil -> fields(content)
      parts -> bounded(parts)
    end
  end

  @doc """
  One input as a model reads it among others: a message's whole text, for the
  reader to shorten where it says so, and any other payload as its search text.
  """
  @spec prose(term()) :: String.t()
  def prose(content) do
    case MessageText.parts(content) do
      nil -> fields(content)
      parts -> Enum.join(parts, "\n")
    end
  end

  # Where a link names what a message is about: an alert's rule or incident page on its title, a
  # button or rich text. Icons, images and files name nothing.
  @link_keys ~w(title_link url)
  @maximum_references 32

  @doc """
  What a message or alert names outside its words, for finding the work it belongs to: the links
  a Slack message carries on attachment titles, buttons and rich text, and the rule, host, both
  together and fingerprint an Alertmanager alert is known by, with its graph link. 706 of 1,034
  alerts in the Tenant history carried their link only there, and none of it was searched (ID7,
  2026-09-30); the same rule on the same host is the same incident, the host alone only related
  (ID9).
  """
  @spec references(term()) :: %{links: [String.t()], labels: [String.t()]}
  def references(%{"alerts" => alerts} = payload) when is_list(alerts) do
    alerts = Enum.filter(alerts, &is_map/1)

    %{
      links: alerts |> Enum.map(& &1["generatorURL"]) |> Enum.filter(&link?/1) |> bounded_list(),
      labels:
        [payload["commonLabels"] | Enum.map(alerts, & &1["labels"])]
        |> Enum.flat_map(&alert_labels/1)
        |> Kernel.++(alerts |> Enum.map(& &1["fingerprint"]) |> Enum.filter(&label?/1))
        |> Enum.map(&String.downcase/1)
        |> bounded_list()
    }
  end

  # A webhook's body is its payload (`Ryker.Webhooks.Input`).
  def references(%{"event_type" => _type, "payload" => %{} = payload}), do: references(payload)

  def references(content) do
    if MessageText.parts(content),
      do: %{links: content |> links(0) |> bounded_list(), labels: []},
      else: %{links: [], labels: []}
  end

  defp alert_labels(%{} = labels) do
    rule = labels["alertname"]
    host = labels["instance"]
    both = if label?(rule) and label?(host), do: ["#{rule}@#{host}"], else: []
    Enum.filter([rule, host], &label?/1) ++ both
  end

  defp alert_labels(_labels), do: []

  defp links(%{} = value, depth) when depth < 12 do
    Enum.flat_map(value, fn
      {key, link} when key in @link_keys -> if link?(link), do: [link], else: []
      {_key, nested} -> links(nested, depth + 1)
    end)
  end

  defp links(value, depth) when is_list(value) and depth < 12,
    do: Enum.flat_map(value, &links(&1, depth + 1))

  defp links(_value, _depth), do: []

  defp link?(value),
    do: is_binary(value) and byte_size(value) <= 2_048 and value =~ ~r{\Ahttps?://\S+\z}

  defp label?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 256

  defp bounded_list(values), do: values |> Enum.uniq() |> Enum.take(@maximum_references)

  defp fields(content) do
    case content |> fragments(0) |> Enum.reject(&(String.trim(&1) == "")) |> Enum.uniq() do
      [] -> String.slice(CanonicalJSON.encode!(content), 0, 4000)
      texts -> bounded(texts)
    end
  end

  defp bounded(texts),
    do: texts |> Enum.take(16) |> Enum.map_join("\n", &cut/1)

  # A part ends at its last whole word before the limit. Cut inside a link, the rest of it was
  # an identifier unrelated alerts shared (".../alerting/sil" in 14 Tenant alerts, ID4,
  # 2026-09-30). Text with nowhere to cut, one long token or a script written without spaces,
  # is cut where the limit falls.
  defp cut(text) do
    head = String.slice(text, 0, @part_characters)

    cond do
      String.length(text) <= @part_characters -> text
      String.match?(String.at(text, @part_characters), ~r/\s/u) -> head
      true -> head |> String.replace(~r/\s+\S*\z/u, "") |> non_empty(head)
    end
  end

  defp non_empty("", head), do: head
  defp non_empty(kept, _head), do: kept

  defp fragments(value, depth) when is_map(value) and depth < 16 do
    value
    |> Enum.sort_by(fn {key, _} -> {Enum.find_index(@fields, &(&1 == key)) || 99, key} end)
    |> Enum.flat_map(fn
      {key, text} when key in @fields and is_binary(text) -> [text]
      {_key, nested} -> fragments(nested, depth + 1)
    end)
  end

  defp fragments(value, depth) when is_list(value) and depth < 16,
    do: Enum.flat_map(value, &fragments(&1, depth + 1))

  defp fragments(_, _), do: []
end
