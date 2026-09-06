defmodule Responder.Work.Activity do
  alias Responder.Admission.FleetSession
  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.Work.ActivityRetention

  @moduledoc """
  Durable, replay-safe custody for Coop's bounded turn narration.

  Coop owns the event sequence. Responder advances one cursor per bound session
  and stores only operator-useful activity events; lifecycle events still move
  the cursor so they cannot be fetched forever. Recording is independent from
  turn settlement, allowing the executor to treat narration as best effort.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Responder.CanonicalJSON
  alias Responder.Repo
  alias Responder.Work.{ActivityEvent, ActivityPaths, Session}

  @activity_kinds ~w(
    tool.started
    tool.completed
    model.plan
    model.thought
    model.progress
    permission.decided
    activity.elided
    provider.backoff
    provider.alive
  )
  @event_fields ~w(id session_id sequence turn_id type version occurred_at payload)
  @required_event_fields ~w(id session_id sequence type version occurred_at)
  @maximum_payload_bytes 256 * 1_024
  @maximum_page 1_000
  @sync_page_size 1_000
  @projection_limit 1_000

  @doc "Capture routing activity without requiring or inventing a kernel episode."
  def sync_admission(entry, remote_id, settings) do
    if function_exported?(settings.api, :list_events, 4) do
      with {:ok, _} <-
             FleetSession.ensure(entry, %{
               name: settings.policy,
               digest: settings.policy_digest
             }),
           {:ok, session} <- FleetSession.bind(entry, remote_id) do
        sync(session, settings.api, settings.client)
      end
    else
      {:ok, %{cursor: 0, inserted: 0}}
    end
  end

  @doc false
  def close_admission(entry, remote_id) do
    if Repo.exists?(
         from(s in Session,
           where:
             s.execution_kind == :admission and s.admission_input_id == ^entry.id and
               s.generation == ^entry.execution_generation
         )
       ), do: FleetSession.settle(entry, remote_id), else: :ok
  end

  @spec sync(Session.t(), module(), term()) ::
          {:ok, %{cursor: non_neg_integer(), inserted: non_neg_integer()}} | {:error, term()}
  def sync(%Session{coop_session_id: remote_id} = session, api, client)
      when is_binary(remote_id) and is_atom(api) do
    if function_exported?(api, :list_events, 4) do
      result = sync_pages(session.id, remote_id, session.activity_cursor, api, client, 0, 32)
      persist_sync_obligation(session.id, result)
      result
    else
      {:ok, %{cursor: session.activity_cursor, inserted: 0}}
    end
  end

  def sync(%Session{} = session, _api, _client),
    do: {:ok, %{cursor: session.activity_cursor, inserted: 0}}

  @spec ingest(Ecto.UUID.t(), [map()]) ::
          {:ok, %{cursor: non_neg_integer(), inserted: non_neg_integer()}} | {:error, term()}
  def ingest(session_id, events)
      when is_binary(session_id) and is_list(events) and length(events) <= @maximum_page do
    Repo.transaction(fn ->
      session =
        Repo.one(from(session in Session, where: session.id == ^session_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:work_session_not_found)

      with {:ok, prepared} <- prepare_page(events, session),
           {:ok, result} <- apply_page(session, prepared) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def ingest(_session_id, _events), do: {:error, {:invalid_coop_activity, :page}}

  @doc false
  @spec ingest_fleet(Ecto.UUID.t(), String.t(), non_neg_integer(), [map()]) ::
          {:ok, %{cursor: non_neg_integer(), inserted: non_neg_integer()}} | {:error, term()}
  def ingest_fleet(session_id, remote_id, cursor, events)
      when is_binary(session_id) and is_binary(remote_id) and is_integer(cursor) and cursor >= 0 and
             is_list(events) and length(events) <= @maximum_page do
    Repo.transaction(fn ->
      session = Repo.get(Session, session_id) || Repo.rollback(:work_session_not_found)

      if session.coop_session_id != remote_id,
        do: Repo.rollback({:coop_activity_session_conflict, remote_id})

      with {:ok, prepared} <- prepare_page(events, session),
           {:ok, result} <- apply_page(session, prepared, cursor, false) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def ingest_fleet(_session_id, _remote_id, _cursor, _events),
    do: {:error, {:invalid_coop_activity, :page}}

  @doc false
  @spec retry_once(module(), term()) :: {:ok, :idle | {:synced, Ecto.UUID.t()}} | {:error, term()}
  def retry_once(api, client) when is_atom(api) do
    if function_exported?(api, :list_events, 4) do
      case Repo.one(
             from(session in Session,
               where:
                 session.activity_sync_pending == true and not is_nil(session.coop_session_id),
               order_by: [asc: session.updated_at, asc: session.id],
               limit: 1
             )
           ) do
        nil -> {:ok, :idle}
        session -> retry_sync(session, api, client)
      end
    else
      {:ok, :idle}
    end
  end

  def retry_once(_api, _client), do: {:error, {:invalid_coop_activity, :api}}

  @spec list_for_episode(Ecto.UUID.t()) :: [ActivityEvent.t()]
  def list_for_episode(episode_id) when is_binary(episode_id) do
    episode_id |> page_for_episode() |> Map.fetch!(:events)
  end

  def list_for_episode(_episode_id), do: []

  @spec page_for_episode(Ecto.UUID.t()) :: %{
          events: [ActivityEvent.t()],
          shown: non_neg_integer(),
          tool_calls: non_neg_integer(),
          total: non_neg_integer(),
          truncated: boolean()
        }
  def page_for_episode(episode_id) when is_binary(episode_id) do
    inputs =
      from(i in Responder.Ingress.Inbox.Entry, where: i.episode_id == ^episode_id, select: i.id)

    query =
      from(event in ActivityEvent,
        where: event.episode_id == ^episode_id or event.admission_input_id in subquery(inputs)
      )
      |> ActivityRetention.visible()

    totals =
      Repo.one!(
        from(event in query,
          select: %{
            tool_calls:
              type(
                fragment("COUNT(*) FILTER (WHERE ? = 'tool.started')::bigint", event.kind),
                :integer
              ),
            total: count(event.id)
          }
        )
      )

    events =
      Repo.all(
        from(event in query,
          order_by: [desc: event.occurred_at, desc: event.session_id, desc: event.sequence],
          limit: @projection_limit
        )
      )
      |> Enum.reverse()

    Map.merge(totals, %{
      events: events,
      shown: length(events),
      truncated: totals.total > length(events)
    })
  end

  def page_for_episode(_episode_id),
    do: %{events: [], shown: 0, tool_calls: 0, total: 0, truncated: false}

  defp sync_pages(_session_id, _remote_id, _cursor, _api, _client, _inserted, 0),
    do: {:error, :coop_activity_more_pages}

  defp sync_pages(session_id, remote_id, cursor, api, client, inserted, pages_left) do
    with {:ok, events} <- fetch_events(api, client, remote_id, cursor),
         true <- is_list(events) and length(events) <= @sync_page_size,
         {:ok, page} <- ingest(session_id, events) do
      case {length(events), page.cursor > cursor} do
        {0, _} ->
          {:ok, %{cursor: page.cursor, inserted: inserted + page.inserted}}

        {_nonempty_page, true} ->
          sync_pages(
            session_id,
            remote_id,
            page.cursor,
            api,
            client,
            inserted + page.inserted,
            pages_left - 1
          )

        {_nonempty_page, false} ->
          {:error, {:invalid_coop_activity, :stalled_cursor}}
      end
    else
      false -> {:error, {:invalid_coop_activity, :page}}
      {:error, _reason} = error -> error
    end
  end

  # Recording failure leaves retry custody; it must not turn an otherwise valid
  # admission or work result into an execution failure.
  defp fetch_events(api, client, remote_id, cursor) do
    api.list_events(client, remote_id, cursor, @sync_page_size)
  rescue
    _ -> {:error, :coop_activity_unavailable}
  catch
    :exit, _ -> {:error, :coop_activity_unavailable}
  end

  defp prepare_page(events, session) do
    retention = ActivityRetention.context(session)

    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, prepared} ->
      case prepare_event(event, session) do
        {:ok, value} -> {:cont, {:ok, [ActivityRetention.mark(value, retention) | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> ordered_page(Enum.reverse(prepared))
      {:error, _reason} = error -> error
    end
  end

  defp prepare_event(%{} = event, session) do
    payload = Map.get(event, "payload") || %{}

    with true <- Map.keys(event) -- @event_fields == [],
         true <- Enum.all?(@required_event_fields, &Map.has_key?(event, &1)),
         :ok <- reference(event["id"], 512, :event_id),
         true <- event["session_id"] == session.coop_session_id,
         :ok <- positive(event["sequence"], :sequence),
         :ok <- optional_reference(event["turn_id"], 512, :turn_id),
         :ok <- reference(event["type"], 128, :type),
         :ok <- positive(event["version"], :version),
         true <- event["version"] <= 65_535,
         {:ok, occurred_at} <- timestamp(event["occurred_at"]),
         true <- is_map(payload),
         {:ok, payload} <- public_payload(event["type"], payload),
         :ok <- CanonicalJSON.validate(payload, max_bytes: @maximum_payload_bytes) do
      {:ok,
       %{
         coop_turn_id: event["turn_id"],
         kind: event["type"],
         occurred_at: occurred_at,
         payload: payload,
         payload_fingerprint: CanonicalJSON.digest(payload),
         remote_payload_fingerprint: CanonicalJSON.digest(event["payload"] || %{}),
         remote_event_id: event["id"],
         remote_session_id: event["session_id"],
         sequence: event["sequence"],
         version: event["version"]
       }}
    else
      false -> {:error, {:invalid_coop_activity, :event}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_event(_event, _session), do: {:error, {:invalid_coop_activity, :event}}

  defp ordered_page([]), do: {:ok, []}

  defp ordered_page(events) do
    sequences = Enum.map(events, & &1.sequence)

    if sequences == Enum.sort(Enum.uniq(sequences)) do
      {:ok, events}
    else
      {:error, {:invalid_coop_activity, :sequence}}
    end
  end

  defp apply_page(session, events) do
    apply_page(session, events, session.activity_cursor, true)
  end

  defp apply_page(session, events, cursor, advance_direct?) do
    fresh = Enum.drop_while(events, &(&1.sequence <= cursor))

    with :ok <- verify_replay(session, events -- fresh),
         :ok <- exact_next(cursor, fresh),
         {:ok, inserted} <- insert_fresh(session, fresh),
         {:ok, next_cursor} <- advance_cursor(session, fresh, cursor, advance_direct?) do
      {:ok, %{cursor: next_cursor, inserted: inserted}}
    end
  end

  defp verify_replay(session, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      if event.kind in @activity_kinds do
        verify_replayed_activity(session.id, event)
      else
        {:cont, :ok}
      end
    end)
  end

  defp verify_replayed_activity(session_id, event) do
    stored =
      Repo.one(
        from(stored in ActivityEvent,
          where:
            stored.session_id == ^session_id and
              stored.remote_session_id == ^event.remote_session_id and
              stored.sequence == ^event.sequence
        )
      )

    case stored do
      %ActivityEvent{} = activity ->
        matches = replayed_activity?(activity, event)
        if matches, do: enrich_legacy(activity, event)
        replay_verdict(matches, event.sequence)

      _missing_or_changed ->
        {:halt, {:error, {:coop_activity_replay_conflict, event.sequence}}}
    end
  end

  defp enrich_legacy(activity, event) do
    if is_nil(activity.operational_pruned_at) &&
         is_nil(event.operational_pruned_at) &&
         not Map.has_key?(activity.payload, "evidence_version") &&
         Map.has_key?(event.payload, "evidence_version") do
      # Re-reading real retained Coop events can enrich a legacy projection;
      # it cannot manufacture an output the provider never saved.
      # Retention can expire the row after this read. The update predicate
      # must be rechecked under its row lock, never overwrite a tombstone.
      ActivityRetention.enrich(activity.id,
        payload: event.payload,
        payload_fingerprint: event.payload_fingerprint,
        remote_payload_fingerprint: event.remote_payload_fingerprint
      )
    end
  end

  defp replayed_activity?(activity, event) do
    fields = [
      :remote_event_id,
      :coop_turn_id,
      :kind,
      :version
    ]

    same_payload =
      if activity.remote_payload_fingerprint do
        activity.remote_payload_fingerprint == event.remote_payload_fingerprint
      else
        activity.payload_fingerprint == event.payload_fingerprint ||
          (not Map.has_key?(activity.payload, "evidence_version") &&
             activity.payload_fingerprint ==
               CanonicalJSON.digest(legacy_payload(event.kind, event.payload)))
      end

    Map.take(activity, fields) == Map.take(event, fields) and same_payload and
      DateTime.compare(activity.occurred_at, event.occurred_at) == :eq
  end

  defp replay_verdict(true, _sequence), do: {:cont, :ok}

  defp replay_verdict(false, sequence),
    do: {:halt, {:error, {:coop_activity_replay_conflict, sequence}}}

  defp exact_next(_cursor, []), do: :ok

  defp exact_next(cursor, [first | rest]) do
    expected = Enum.to_list((cursor + 1)..(cursor + length(rest) + 1))
    received = Enum.map([first | rest], & &1.sequence)

    if received == expected,
      do: :ok,
      else: {:error, {:coop_activity_cursor_gap, cursor + 1, first.sequence}}
  end

  defp insert_fresh(session, events) do
    events
    |> Enum.filter(&(&1.kind in @activity_kinds))
    |> Enum.reduce_while({:ok, 0}, fn event, {:ok, count} ->
      attributes =
        event
        |> ActivityRetention.expire()
        |> Map.put(:episode_id, session.episode_id)
        |> Map.put(:admission_input_id, session.admission_input_id)
        |> Map.put(:session_id, session.id)

      case %ActivityEvent{}
           |> Changeset.cast(attributes, [
             :coop_turn_id,
             :episode_id,
             :admission_input_id,
             :kind,
             :occurred_at,
             :payload,
             :payload_fingerprint,
             :remote_payload_fingerprint,
             :operational_pruned_at,
             :remote_event_id,
             :remote_session_id,
             :sequence,
             :session_id,
             :version
           ])
           |> Changeset.validate_required([
             :kind,
             :occurred_at,
             :payload,
             :payload_fingerprint,
             :remote_event_id,
             :remote_session_id,
             :sequence,
             :session_id,
             :version
           ])
           |> Repo.insert() do
        {:ok, _stored} -> {:cont, {:ok, count + 1}}
        {:error, changeset} -> {:halt, {:error, {:coop_activity_store, changeset.errors}}}
      end
    end)
  end

  defp advance_cursor(_session, [], cursor, _advance_direct?), do: {:ok, cursor}

  defp advance_cursor(_session, events, _cursor, false), do: {:ok, List.last(events).sequence}

  defp advance_cursor(session, events, _cursor, true) do
    cursor = List.last(events).sequence

    case session |> Changeset.change(activity_cursor: cursor) |> Repo.update() do
      {:ok, _session} -> {:ok, cursor}
      {:error, changeset} -> {:error, {:coop_activity_cursor, changeset.errors}}
    end
  end

  defp reference(value, maximum, _field)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, {:invalid_coop_activity, :text}}
  end

  defp reference(_value, _maximum, field), do: {:error, {:invalid_coop_activity, field}}

  defp optional_reference(nil, _maximum, _field), do: :ok
  defp optional_reference(value, maximum, field), do: reference(value, maximum, field)

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_coop_activity, field}}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_coop_activity, :occurred_at}}
    end
  end

  defp timestamp(_value), do: {:error, {:invalid_coop_activity, :occurred_at}}

  defp persist_sync_obligation(session_id, {:ok, _receipt}) do
    _ =
      Repo.update_all(
        from(session in Session, where: session.id == ^session_id),
        set: [activity_sync_pending: false]
      )

    :ok
  end

  defp persist_sync_obligation(session_id, {:error, _reason}) do
    _ =
      Repo.update_all(
        from(session in Session, where: session.id == ^session_id),
        set: [activity_sync_pending: true]
      )

    :ok
  end

  defp retry_sync(session, api, client) do
    case sync(session, api, client) do
      {:ok, _receipt} -> {:ok, {:synced, session.id}}
      {:error, _reason} = error -> error
    end
  end

  defp public_payload(kind, _payload) when kind not in @activity_kinds, do: {:ok, %{}}

  defp public_payload("tool.started", payload) do
    with {:ok, tool_call_id} <- public_text(payload["tool_call_id"], 1_024, :tool_call_id) do
      visible = public_tool_input(payload["input"])

      {:ok,
       enrich_tool(compact_map(%{"tool_call_id" => tool_call_id, "input" => visible}), payload)}
    end
  end

  defp public_payload("tool.completed", payload) do
    with {:ok, tool_call_id} <- public_text(payload["tool_call_id"], 1_024, :tool_call_id),
         {:ok, status} <- public_enum(payload["status"], ~w(completed failed cancelled), :status) do
      {:ok, enrich_tool(%{"tool_call_id" => tool_call_id, "status" => status}, payload)}
    end
  end

  defp public_payload("model.plan", payload) do
    count =
      cond do
        is_integer(payload["step_count"]) -> payload["step_count"]
        is_list(payload["entries"]) -> length(payload["entries"])
        true -> 0
      end

    if count >= 0 and count <= 32 do
      entries =
        case payload["entries"] do
          entries when is_list(entries) ->
            Enum.filter(entries, &is_map/1)
            |> Enum.map(&Map.take(&1, ~w(content text status priority)))

          _ ->
            []
        end

      {:ok,
       %{"step_count" => count, "entries" => sanitize_evidence(entries), "evidence_version" => 1}}
    else
      {:error, {:invalid_coop_activity, :step_count}}
    end
  end

  defp public_payload("model.thought", _payload), do: {:ok, %{}}

  defp public_payload("model.progress", payload) do
    with {:ok, text} <- public_text(payload["text"], 65_536, :text) do
      artifact = InspectionRedactor.artifact(text, max_bytes: 16_384)

      {:ok,
       %{"text" => artifact.text, "truncated" => artifact.truncated, "evidence_version" => 1}}
    end
  end

  defp public_payload("permission.decided", payload) do
    with {:ok, outcome} <-
           public_enum(payload["outcome"], ~w(selected allowed denied cancelled), :outcome) do
      result =
        %{"outcome" => outcome}
        |> optional_public_text("tool_call_id", payload["tool_call_id"], 1_024)
        |> optional_public_text("option_kind", payload["option_kind"], 32)

      {:ok, result}
    end
  end

  defp public_payload("activity.elided", payload) do
    case payload["dropped"] do
      dropped when is_integer(dropped) and dropped >= 0 -> {:ok, %{"dropped" => dropped}}
      _invalid -> {:error, {:invalid_coop_activity, :dropped}}
    end
  end

  defp public_payload("provider.backoff", payload) do
    result =
      %{}
      |> optional_public_integer("attempt", payload["attempt"])
      |> optional_public_integer("retry_after_seconds", payload["retry_after_seconds"])
      |> optional_public_text("target", payload["target"], 256)
      |> optional_public_text("next_target", payload["next_target"], 256)
      |> optional_public_timestamp("reset_at", payload["reset_at"])
      |> optional_public_timestamp("all_limited_until", payload["all_limited_until"])

    {:ok, result}
  end

  defp public_payload("provider.alive", payload) do
    {:ok,
     %{}
     |> optional_public_integer("frames", payload["frames"])
     |> optional_public_integer("bytes", payload["bytes"])}
  end

  defp enrich_tool(base, payload) do
    evidence =
      payload
      |> Map.put("path_context", ActivityPaths.sanitize(payload["path_context"]))
      |> Map.take(~w(title kind input output content locations error path_context))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {key, sanitize_evidence(value)} end)

    Map.merge(base, evidence) |> Map.put("evidence_version", 1)
  end

  defp sanitize_evidence(value) do
    artifact = InspectionRedactor.artifact(value, max_bytes: 16_384)

    if artifact.truncated do
      %{"preview" => artifact.text, "truncated" => true}
    else
      case Jason.decode(artifact.text) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
        _ -> artifact.text
      end
    end
  end

  defp legacy_payload("tool.started", payload),
    do:
      compact_map(%{
        "tool_call_id" => payload["tool_call_id"],
        "input" => public_tool_input(payload["input"])
      })

  defp legacy_payload("tool.completed", payload), do: Map.take(payload, ~w(tool_call_id status))
  defp legacy_payload("model.plan", payload), do: Map.take(payload, ~w(step_count))
  defp legacy_payload(_kind, payload), do: Map.delete(payload, "evidence_version")

  defp public_tool_input(%{} = input) do
    arguments = public_tool_arguments(input["arguments"])

    %{}
    |> optional_public_text("server", input["server"], 128)
    |> optional_public_text("tool", input["tool"], 128)
    |> optional_public_text(
      "operation",
      arguments["action_id"] || input["action_id"] || input["operation"],
      128
    )
  end

  defp public_tool_input(_missing), do: %{}
  defp public_tool_arguments(%{} = arguments), do: arguments
  defp public_tool_arguments(_arguments), do: %{}

  defp public_text(value, maximum, _field)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, {:invalid_coop_activity, :text}}
  end

  defp public_text(_value, _maximum, field), do: {:error, {:invalid_coop_activity, field}}

  defp public_enum(value, allowed, field) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_coop_activity, field}}
  end

  defp optional_public_text(result, _key, nil, _maximum), do: result

  defp optional_public_text(result, key, value, maximum) do
    case public_text(value, maximum, key) do
      {:ok, visible} -> Map.put(result, key, visible)
      {:error, _reason} -> result
    end
  end

  defp optional_public_integer(result, key, value)
       when is_integer(value) and value >= 0,
       do: Map.put(result, key, value)

  defp optional_public_integer(result, _key, _value), do: result

  defp optional_public_timestamp(result, key, value) when is_binary(value) do
    case timestamp(value) do
      {:ok, datetime} -> Map.put(result, key, DateTime.to_iso8601(datetime))
      {:error, _reason} -> result
    end
  end

  defp optional_public_timestamp(result, _key, _value), do: result

  defp compact_map(value), do: Map.reject(value, fn {_key, nested} -> nested in [nil, %{}] end)
end
