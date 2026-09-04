defmodule Responder.Work.Activity do
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
  alias Responder.Work.{ActivityEvent, Session}

  @activity_kinds ~w(
    tool.started
    tool.completed
    model.plan
    model.thought
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

  @spec sync(Session.t(), module(), term()) ::
          {:ok, %{cursor: non_neg_integer(), inserted: non_neg_integer()}} | {:error, term()}
  def sync(%Session{coop_session_id: remote_id} = session, api, client)
      when is_binary(remote_id) and is_atom(api) do
    if function_exported?(api, :list_events, 4) do
      result = sync_pages(session.id, remote_id, session.activity_cursor, api, client, 0)
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
    totals =
      Repo.one!(
        from(event in ActivityEvent,
          where: event.episode_id == ^episode_id,
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
        from(event in ActivityEvent,
          where: event.episode_id == ^episode_id,
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

  defp sync_pages(session_id, remote_id, cursor, api, client, inserted) do
    with {:ok, events} <- api.list_events(client, remote_id, cursor, @sync_page_size),
         true <- is_list(events) and length(events) <= @sync_page_size,
         {:ok, page} <- ingest(session_id, events) do
      case {length(events), page.cursor > cursor} do
        {@sync_page_size, true} ->
          sync_pages(
            session_id,
            remote_id,
            page.cursor,
            api,
            client,
            inserted + page.inserted
          )

        {@sync_page_size, false} ->
          {:error, {:invalid_coop_activity, :stalled_cursor}}

        {_short_page, _progress} ->
          {:ok, %{cursor: page.cursor, inserted: inserted + page.inserted}}
      end
    else
      false -> {:error, {:invalid_coop_activity, :page}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_page(events, session) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, prepared} ->
      case prepare_event(event, session) do
        {:ok, value} -> {:cont, {:ok, [value | prepared]}}
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
        replay_verdict(replayed_activity?(activity, event), event.sequence)

      _missing_or_changed ->
        {:halt, {:error, {:coop_activity_replay_conflict, event.sequence}}}
    end
  end

  defp replayed_activity?(activity, event) do
    fields = [
      :remote_event_id,
      :coop_turn_id,
      :kind,
      :version,
      :payload_fingerprint
    ]

    Map.take(activity, fields) == Map.take(event, fields) and
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
        |> Map.put(:episode_id, session.episode_id)
        |> Map.put(:session_id, session.id)

      case %ActivityEvent{}
           |> Changeset.cast(attributes, [
             :coop_turn_id,
             :episode_id,
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
           |> Changeset.validate_required([
             :episode_id,
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

      {:ok, compact_map(%{"tool_call_id" => tool_call_id, "input" => visible})}
    end
  end

  defp public_payload("tool.completed", payload) do
    with {:ok, tool_call_id} <- public_text(payload["tool_call_id"], 1_024, :tool_call_id),
         {:ok, status} <- public_enum(payload["status"], ~w(completed failed cancelled), :status) do
      {:ok, %{"tool_call_id" => tool_call_id, "status" => status}}
    end
  end

  defp public_payload("model.plan", payload) do
    count =
      cond do
        is_integer(payload["step_count"]) -> payload["step_count"]
        is_list(payload["entries"]) -> length(payload["entries"])
        true -> 0
      end

    if count >= 0 and count <= 32,
      do: {:ok, %{"step_count" => count}},
      else: {:error, {:invalid_coop_activity, :step_count}}
  end

  defp public_payload("model.thought", _payload), do: {:ok, %{}}

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
