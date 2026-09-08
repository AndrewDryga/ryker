defmodule Responder.State.KnowledgeAnchors do
  @moduledoc "Source-backed identity clues, never authority or a uniqueness guarantee."
  alias Responder.CanonicalJSON

  @urls ~r{https?://[^\s<>|"`]+}u
  @uuids ~r/\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b/u

  @doc "Read the original submitted values, not the lossy search excerpt."
  def source_texts(entries), do: Enum.map(entries, &(&1.content |> strings() |> Enum.join("\n")))

  defp strings(value) when is_binary(value), do: [value]

  defp strings(value) when is_map(value),
    do:
      value |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(fn {_key, value} -> strings(value) end)

  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(_), do: []

  def normalize(value) do
    uri = URI.parse(value)

    cond do
      github_subject?(uri) ->
        "https://github.com" <> (uri.path |> String.trim_trailing("/") |> String.downcase())

      slack_message?(uri) ->
        "https://" <> uri.host <> uri.path

      true ->
        value
    end
  end

  defp github_subject?(%URI{scheme: "https", host: "github.com", userinfo: nil, port: 443} = uri),
    do: Regex.match?(~r{\A/[^/]+/[^/]+/(?:pull|issues)/[0-9]+/?\z}, uri.path || "")

  defp github_subject?(_), do: false

  defp slack_message?(%URI{scheme: "https", host: host, userinfo: nil, port: 443} = uri)
       when is_binary(host),
       do:
         Regex.match?(~r/\A[a-z0-9-]+\.slack\.com\z/, host) and
           Regex.match?(~r{\A/archives/[A-Z0-9]+/p[0-9]+\z}, uri.path || "")

  defp slack_message?(_), do: false

  def discover(texts) do
    texts
    |> Enum.filter(&is_binary/1)
    |> Enum.take(16)
    |> Enum.flat_map(fn text ->
      text = String.slice(text, 0, 65_536)
      matches(@urls, text) ++ matches(@uuids, text)
    end)
    |> Enum.map(&normalize/1)
    |> Enum.filter(&(byte_size(&1) <= 512))
    |> Enum.uniq()
    |> Enum.take(64)
  end

  def validate(anchors, texts, inherited) do
    known =
      texts
      |> Enum.flat_map(&matches(@urls, &1))
      |> Enum.concat(inherited)
      |> Enum.map(&normalize/1)
      |> MapSet.new()

    if Enum.all?(anchors, fn anchor ->
         MapSet.member?(known, normalize(anchor)) or
           Enum.any?(texts, &contains_identity?(&1, anchor))
       end), do: :ok, else: {:error, :knowledge_anchor_not_sourced}
  end

  def keys(scope_key, anchors) do
    anchors
    |> Enum.map(&CanonicalJSON.digest(%{"scope" => scope_key, "anchor" => normalize(&1)}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp contains_identity?(text, anchor) when is_binary(text) do
    Regex.match?(
      Regex.compile!(
        "(?<![\\p{L}\\p{N}_:/-])" <>
          Regex.escape(anchor) <>
          "(?![\\p{L}\\p{N}_:/-])",
        "u"
      ),
      text
    )
  end

  defp contains_identity?(_, _), do: false

  defp matches(regex, text), do: regex |> Regex.scan(text) |> List.flatten()
end
