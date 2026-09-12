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

  alias Responder.Delivery.PlatformAction
  alias Responder.Repo
  alias Responder.Slack.{IncidentRoom, Permalink, SavedEntity}
  alias Responder.State.{Behavior, EventWaitTiming, MemoryEntry, Schedule, SlackPostOffers}
  alias Responder.Work.{ActivityEvent, ActivityRetention}

  @saved_offer_kinds ~w(guidance_offer memory_offer preference_offer schedule_offer standing_assignment_offer)

  @spec documents(String.t(), String.t(), [map()]) :: [map()]
  def documents(transport, episode_id, records) do
    documents = Enum.map(records, &document/1)

    if transport == "slack" and records != [] do
      times = Map.new(records, &{&1.ref, &1.inserted_at})

      sources =
        for %{kind: "evidence", payload: %{"source_id" => id}} <- records,
            is_binary(id),
            do: id

      documents
      |> enrich(receipts(episode_id, Enum.uniq(sources)), times)
      |> Enum.zip_with(records, &present_saved_entity/2)
      |> Enum.zip_with(records, &present_sent_post/2)
    else
      documents
    end
  end

  # A confirmed post said the delivery worker was "sending or reconciling" it
  # forever, because the card was built from the offer and the offer cannot know
  # where the message went. The host does: the action this record produced keeps
  # the receipt. Without a workspace origin there is no link, and the card says
  # what it always said.
  defp present_sent_post(document, %{status: :confirmed, kind: "slack_post_offer"} = record) do
    with %PlatformAction{status: :delivered, conversation_ref: conversation} = action <-
           sent_action(record),
         %{"message_ref" => message} <- action.external_receipt,
         url when is_binary(url) <- Permalink.message_url(workspace_url(), conversation, message) do
      Map.put(document, "message_url", url)
    else
      _unsent -> document
    end
  end

  defp present_sent_post(document, _record), do: document

  defp sent_action(record) do
    Repo.get_by(PlatformAction,
      turn_id: record.turn_id,
      host_slot: SlackPostOffers.host_slot(record)
    )
  end

  defp workspace_url do
    case Responder.Settings.fetch() do
      {:ok, %{slack: %{workspace_url: url}}} -> url
      _unavailable -> nil
    end
  rescue
    _error -> nil
  end

  # A confirmed offer is shown as the entity it saved, with the entity's current
  # status: the offer payload alone cannot say whether the schedule still runs.
  defp present_saved_entity(document, %{status: :confirmed, kind: kind} = record)
       when kind in @saved_offer_kinds do
    case saved_entity(kind, record) do
      nil ->
        document

      entity ->
        Map.put(document, "presentation", %{"entity" => SavedEntity.document(entity, :saved)})
    end
  end

  defp present_saved_entity(
         document,
         %{status: :confirmed, kind: "automation_change_offer", payload: payload}
       ) do
    case updated_automation(payload["automation_id"]) do
      nil ->
        document

      entity ->
        Map.put(document, "presentation", %{"entity" => SavedEntity.document(entity, :updated)})
    end
  end

  # A confirmed incident offer says which path it took; the room link appears
  # only once the room's channel exists.
  defp present_saved_entity(
         document,
         %{status: :confirmed, kind: "task_offer", payload: %{"kind" => "incident"}} = record
       ) do
    case Repo.get_by(IncidentRoom, record_id: record.id) do
      nil -> document
      room -> Map.put(document, "presentation", %{"incident_room" => %{"url" => room_url(room)}})
    end
  end

  defp present_saved_entity(document, _record), do: document

  defp room_url(%IncidentRoom{channel_ref: channel_ref, workspace_ref: workspace_ref})
       when is_binary(channel_ref) and is_binary(workspace_ref) do
    if Regex.match?(~r/\A[A-Z0-9]+\z/, channel_ref) and
         Regex.match?(~r/\A[A-Z0-9]+\z/, workspace_ref),
       do:
         "https://slack.com/app_redirect?" <>
           URI.encode_query(team: workspace_ref, channel: channel_ref),
       else: nil
  end

  defp room_url(_room), do: nil

  defp saved_entity("schedule_offer", record),
    do: Repo.get_by(Schedule, offer_record_id: record.id)

  defp saved_entity("memory_offer", record),
    do: Repo.get_by(MemoryEntry, offer_record_id: record.id)

  defp saved_entity(_behavior_offer, record),
    do: Repo.get_by(Behavior, offer_record_id: record.id)

  defp updated_automation("schedule:" <> _rest = ref), do: Repo.get_by(Schedule, ref: ref)
  defp updated_automation("behavior:" <> _rest = ref), do: Repo.get_by(Behavior, ref: ref)
  defp updated_automation(_ref), do: nil

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
