defmodule Responder.Slack.ReplyRecords do
  @moduledoc "Host-owned reply metadata; the original records remain unchanged."

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
            not safe_url?(id),
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
      |> Enum.filter(&receipt?/1)
      |> Enum.group_by(& &1["run_id"], & &1["run_url"])
      |> Enum.flat_map(fn {id, urls} ->
        case Enum.uniq(urls) do
          [url] -> [{id, url}]
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
    source = payload["source_id"]
    url = urls[source] || if(safe_url?(source), do: source)
    if url, do: Map.put(record, "presentation", %{"source_url" => url}), else: record
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

  defp receipt?(%{"run_id" => id, "run_url" => url}) when is_binary(id) do
    safe_url?(url) and String.ends_with?(URI.parse(url).path || "", "/runs/" <> id)
  end

  defp receipt?(_receipt), do: false

  defp receipts(_episode_id, []), do: []

  defp receipts(episode_id, source_ids) do
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
          type(^source_ids, {:array, :string})
        )
    )
    |> ActivityRetention.visible()
    |> Repo.all()
    |> Enum.flat_map(fn runs -> if is_list(runs), do: runs, else: [] end)
  end
end
