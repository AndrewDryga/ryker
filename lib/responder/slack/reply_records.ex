defmodule Responder.Slack.ReplyRecords do
  @moduledoc """
  Host-owned reply metadata; the original records remain unchanged.

  An evidence source becomes a link only when a completed tool call in the same
  episode still proves the destination: Emisar names the run it started, and
  every other server must have returned that exact URL in the retained output of
  its own `tool.completed` receipt. A URL the model merely wrote — into
  `source_id`, into its own tool arguments, into a call that failed, or into a
  record our state server then read back — is not a receipt, and its source is
  omitted rather than linked.
  """

  import Ecto.Query

  alias Responder.Repo
  alias Responder.State.EventWaitTiming
  alias Responder.Work.{ActivityEvent, ActivityRetention}

  @spec documents(String.t(), String.t(), [map()]) :: [map()]
  def documents(transport, episode_id, records) do
    documents = Enum.map(records, &document/1)

    if transport == "slack" and records != [] do
      times = Map.new(records, &{&1.ref, &1.inserted_at})

      sources =
        for %{kind: "evidence", payload: %{"source_id" => id}} <- records,
            is_binary(id),
            do: id

      enrich(documents, receipts(episode_id, Enum.uniq(sources)), times)
    else
      documents
    end
  end

  @doc false
  def enrich(documents, receipts, times \\ %{}) do
    urls =
      receipts
      |> Enum.flat_map(&receipt/1)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {source, urls} ->
        case Enum.uniq(urls) do
          [url] -> [{source, url}]
          _ambiguous -> []
        end
      end)
      |> Map.new()

    Enum.map(documents, &enrich_record(&1, urls, times))
  end

  @doc false
  def safe_url?(value) when is_binary(value) and byte_size(value) in 1..2_000 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        # These links are source receipts, never signed downloads or Slack control syntax.
        decoded = URI.decode(value)
        String.valid?(decoded) and not Regex.match?(~r/[\s\x00-\x1f\x7f<>|\\]/, decoded)

      _invalid ->
        false
    end
  end

  def safe_url?(_value), do: false

  defp document(record) do
    %{
      "kind" => record.kind,
      "payload" => record.payload,
      "ref" => record.ref,
      "status" => Atom.to_string(record.status)
    }
  end

  defp enrich_record(%{"kind" => "evidence", "payload" => payload} = record, urls, _times) do
    case urls[payload["source_id"]] do
      nil -> record
      url -> Map.put(record, "presentation", %{"source_url" => url})
    end
  end

  defp enrich_record(%{"kind" => "event_wait", "payload" => payload} = record, _urls, times) do
    trigger = payload["event_matcher"]

    case EventWaitTiming.due_at(trigger, times[record["ref"]]) do
      {:ok, at} ->
        Map.put(record, "presentation", %{"next_check_at" => DateTime.to_iso8601(at)})

      _not_a_timer ->
        record
    end
  end

  defp enrich_record(record, _urls, _times), do: record

  defp receipt(%{"run_id" => id, "run_url" => url}) when is_binary(id) do
    if safe_url?(url) and String.ends_with?(URI.parse(url).path || "", "/runs/" <> id),
      do: [{id, url}],
      else: []
  end

  defp receipt(%{"url" => url}) do
    if safe_url?(url), do: [{url, url}], else: []
  end

  defp receipt(_receipt), do: []

  defp receipts(_episode_id, []), do: []

  defp receipts(episode_id, sources) do
    {urls, references} = Enum.split_with(sources, &safe_url?/1)
    run_receipts(episode_id, references) ++ url_receipts(episode_id, urls)
  end

  defp run_receipts(_episode_id, []), do: []

  defp run_receipts(episode_id, references) do
    # Select only receipt identities, not stdout. Retired or foreign-episode evidence cannot
    # reappear as a clickable source during delivery or an interaction repaint.
    from(a in ActivityEvent,
      where: a.episode_id == ^episode_id and a.kind == "tool.completed",
      where: fragment("?::jsonb #>> '{input,server}' = 'emisar'", a.payload),
      where: fragment("?::jsonb #>> '{input,tool}' = 'run_action'", a.payload),
      where: fragment("?::jsonb #>> '{status}' = 'completed'", a.payload),
      select:
        fragment(
          "(SELECT coalesce(jsonb_agg(jsonb_build_object('run_id', r->>'run_id', 'run_url', r->>'run_url')), '[]'::jsonb) FROM jsonb_path_query(?::jsonb, '$.output.result.structuredContent.runs[*]') AS r WHERE r->>'run_id' = ANY(?))",
          a.payload,
          type(^references, {:array, :string})
        )
    )
    |> ActivityRetention.visible()
    |> Repo.all()
    |> Enum.flat_map(fn runs -> if is_list(runs), do: runs, else: [] end)
  end

  defp url_receipts(_episode_id, []), do: []

  defp url_receipts(episode_id, urls) do
    # Match the whole retained output value, never a substring, and never the
    # model's own arguments or titles sitting in the same row: a URL is provenance
    # only when the call returned it. Our own state server is excluded because it
    # hands back the saved records themselves, so reading them would certify every
    # source_id the model had just written.
    from(a in ActivityEvent,
      where: a.episode_id == ^episode_id and a.kind == "tool.completed",
      where: fragment("?::jsonb #>> '{status}' = 'completed'", a.payload),
      where:
        fragment("?::jsonb #>> '{input,server}' IS DISTINCT FROM 'responder-state'", a.payload),
      select:
        fragment(
          "(SELECT coalesce(jsonb_agg(DISTINCT returned), '[]'::jsonb) FROM jsonb_path_query(?::jsonb #> '{output}', '$.**') AS returned WHERE jsonb_typeof(returned) = 'string' AND (returned #>> '{}') = ANY(?))",
          a.payload,
          type(^urls, {:array, :string})
        )
    )
    |> ActivityRetention.visible()
    |> Repo.all()
    |> Enum.flat_map(fn returned ->
      if is_list(returned), do: Enum.map(returned, &%{"url" => &1}), else: []
    end)
  end
end
