defmodule Responder.Cutover.LegacySnapshot do
  @moduledoc """
  Builds a sealed, read-only inventory from one frozen legacy SQLite snapshot.

  This module is deliberately not a runtime compatibility reader. The operator
  stops legacy admission, creates a standalone SQLite backup with no WAL
  sidecars, inventories it once, reviews unfinished work, and later applies the
  sealed manifest through the PostgreSQL cutover ledger.
  """

  alias Responder.CanonicalJSON
  alias Responder.Cutover.LegacySchema

  @maximum_rows %{
    "episode_wakeups" => 1_000,
    "memory_entries" => 1_000,
    "scheduled_tasks" => 500,
    "standing_rules" => 500,
    "work_episodes" => 500
  }
  @maximum_item_bytes 256 * 1_024
  @maximum_manifest_bytes 16 * 1_024 * 1_024
  @terminal_episode_states ~w(completed failed refused cancelled superseded)
  @options [:cutover_at, :runner, :sqlite3, :workspace_ref]

  @queries %{
    "episode_wakeups" => """
    SELECT id, episode_id, kind, event_matcher_json, due_at, poll_after, deadline,
           state, created_at, updated_at, verification
    FROM episode_wakeups
    ORDER BY id
    LIMIT 1001
    """,
    "memory_entries" => """
    SELECT id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
           source_ref, source_revision, actor_id, visibility_kind, visibility_id,
           expires_at, created_at, updated_at, last_recalled_at, recall_count,
           last_reviewed_at
    FROM memory_entries
    ORDER BY id
    LIMIT 1001
    """,
    "scheduled_tasks" => """
    SELECT id, team_id, channel_id, thread_ts, repository, title, prompt, recurrence,
           start_at, interval_seconds, weekdays_json, day_of_month, local_time,
           timezone, catch_up, enabled, actor_id, source_ref, next_run_at, last_run_at,
           last_outcome, expires_at, created_at, updated_at, delivery_channel_id
    FROM scheduled_tasks
    ORDER BY id
    LIMIT 501
    """,
    "schema_version" => "SELECT version FROM schema_version LIMIT 1",
    "schema_objects" => """
    SELECT type, name, tbl_name, sql
    FROM sqlite_schema
    WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
    ORDER BY tbl_name, type DESC, name
    """,
    "standing_rules" => """
    SELECT id, channel_id, repository, trigger_name, action_name, source_kind,
           enabled, source_ref, actor_id, trigger_count, last_triggered_at,
           expires_at, created_at, updated_at, acted_count, quiet_count,
           workflow_name, workflow_json
    FROM standing_rules
    ORDER BY id
    LIMIT 501
    """,
    "work_episodes" => """
    SELECT e.id, e.agent_run_id, e.effort, e.authority, e.objective,
           e.required_coverage_json, e.completion_criteria_json, e.phase, e.status,
           e.next_action, e.created_at, e.updated_at, e.lifecycle_state, e.workspace_id,
           e.parent_episode_id, e.mode, e.platform, e.channel_id, e.thread_ts,
           e.anchor_ts, e.visibility, e.destination_channel_id,
           e.destination_thread_ts, e.latest_attempt_id, e.authority_snapshot_ref,
           r.state AS run_state, r.source_kind, r.source_id, r.repository,
           r.session_id, r.coop_turn_id
    FROM work_episodes AS e
    JOIN agent_runs AS r ON r.id = e.agent_run_id
    WHERE e.lifecycle_state IS NULL OR e.lifecycle_state NOT IN (
      'completed', 'failed', 'refused', 'cancelled', 'superseded'
    )
    ORDER BY e.id
    LIMIT 501
    """
  }

  @spec inventory(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inventory(path, options \\ []) do
    with {:ok, settings} <- settings(path, options),
         :ok <- frozen_snapshot(settings.path),
         {:ok, source_sha256} <- file_sha256(settings.path),
         :ok <- quick_check(settings),
         {:ok, rows} <- read_rows(settings),
         {:ok, items} <- items(rows, settings.cutover_at),
         {:ok, final_sha256} <- file_sha256(settings.path),
         :ok <- unchanged(source_sha256, final_sha256),
         {:ok, schema} <- schema_identity(rows),
         manifest <- manifest(settings, source_sha256, schema, items),
         :ok <- CanonicalJSON.validate(manifest, max_bytes: @maximum_manifest_bytes) do
      {:ok, %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp settings(path, options) do
    with :ok <- options(options),
         :ok <- path(path),
         {:ok, cutover_at} <- cutover_at(Keyword.get(options, :cutover_at)),
         {:ok, workspace_ref} <- workspace_ref(Keyword.get(options, :workspace_ref)),
         {:ok, runner} <- runner(Keyword.get(options, :runner, &system_command/2)),
         {:ok, sqlite3} <-
           sqlite3(Keyword.get(options, :sqlite3, System.find_executable("sqlite3"))) do
      {:ok,
       %{
         cutover_at: cutover_at,
         path: path,
         runner: runner,
         sqlite3: sqlite3,
         workspace_ref: workspace_ref
       }}
    end
  end

  defp options(options) do
    valid =
      Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
        Keyword.keys(options) -- @options == []

    if valid, do: :ok, else: {:error, {:invalid_legacy_snapshot, :options}}
  end

  defp path(value) when is_binary(value) do
    case File.lstat(value) do
      {:ok, %File.Stat{type: :regular}} ->
        if Path.type(value) == :absolute,
          do: :ok,
          else: {:error, {:invalid_legacy_snapshot, :path}}

      _missing_or_unsafe ->
        {:error, {:invalid_legacy_snapshot, :path}}
    end
  end

  defp path(_value), do: {:error, {:invalid_legacy_snapshot, :path}}

  defp cutover_at(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: {:ok, normalize(value)},
      else: {:error, {:invalid_legacy_snapshot, :cutover_at}}
  end

  defp cutover_at(_value), do: {:error, {:invalid_legacy_snapshot, :cutover_at}}

  defp workspace_ref(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      ["slack", workspace]
      when byte_size(workspace) in 1..256 ->
        if valid_text?(workspace),
          do: {:ok, value},
          else: {:error, {:invalid_legacy_snapshot, :workspace_ref}}

      _invalid ->
        {:error, {:invalid_legacy_snapshot, :workspace_ref}}
    end
  end

  defp workspace_ref(_value), do: {:error, {:invalid_legacy_snapshot, :workspace_ref}}

  defp runner(value) when is_function(value, 2), do: {:ok, value}
  defp runner(_value), do: {:error, {:invalid_legacy_snapshot, :runner}}

  defp sqlite3(value) when is_binary(value) do
    if Path.type(value) == :absolute and File.regular?(value),
      do: {:ok, value},
      else: {:error, {:invalid_legacy_snapshot, :sqlite3}}
  end

  defp sqlite3(_value), do: {:error, {:invalid_legacy_snapshot, :sqlite3}}

  defp frozen_snapshot(path) do
    cond do
      File.exists?(path <> "-wal") -> {:error, {:legacy_snapshot_not_frozen, :wal}}
      File.exists?(path <> "-shm") -> {:error, {:legacy_snapshot_not_frozen, :shm}}
      true -> :ok
    end
  end

  defp quick_check(settings) do
    arguments = ["-batch", "-readonly", "-noheader", settings.path, "PRAGMA quick_check;"]

    case command(settings, arguments) do
      {:ok, output} ->
        if String.trim(output) == "ok",
          do: :ok,
          else: {:error, :legacy_snapshot_integrity_failed}

      {:error, _reason} ->
        {:error, :legacy_snapshot_integrity_failed}
    end
  end

  defp read_rows(settings) do
    [
      "schema_version",
      "schema_objects",
      "memory_entries",
      "scheduled_tasks",
      "standing_rules",
      "work_episodes",
      "episode_wakeups"
    ]
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, rows} ->
      case query(settings, name, Map.fetch!(@queries, name)) do
        {:ok, values} -> {:cont, {:ok, Map.put(rows, name, values)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp query(settings, name, sql) do
    arguments = ["-batch", "-readonly", "-json", settings.path, sql]

    with {:ok, output} <- command(settings, arguments),
         {:ok, rows} <- decode_rows(output),
         true <- is_list(rows),
         true <- Enum.all?(rows, &is_map/1),
         :ok <- row_limit(name, rows) do
      {:ok, rows}
    else
      {:error, %Jason.DecodeError{}} -> {:error, {:legacy_snapshot_invalid_json, name}}
      {:error, _reason} = error -> error
      false -> {:error, {:legacy_snapshot_invalid_rows, name}}
    end
  end

  # sqlite3's JSON output mode emits no bytes, rather than `[]`, when a SELECT
  # returns no rows. A successful blank result is therefore one empty table;
  # nonblank malformed output remains an integrity failure.
  defp decode_rows(output) when is_binary(output) do
    if String.trim(output) == "", do: {:ok, []}, else: Jason.decode(output)
  end

  defp row_limit("schema_version", [_row]), do: :ok
  defp row_limit("schema_objects", rows) when length(rows) <= 300, do: :ok

  defp row_limit(name, rows) do
    case Map.fetch(@maximum_rows, name) do
      {:ok, maximum} when length(rows) <= maximum -> :ok
      {:ok, _maximum} -> {:error, {:legacy_snapshot_too_many_rows, name}}
      :error -> {:error, {:legacy_snapshot_invalid_rows, name}}
    end
  end

  defp command(settings, arguments) do
    case settings.runner.(settings.sqlite3, arguments) do
      {output, 0} when is_binary(output) -> {:ok, output}
      {_output, status} when is_integer(status) -> {:error, :legacy_snapshot_query_failed}
      _invalid -> {:error, :legacy_snapshot_runner_invalid}
    end
  rescue
    _error -> {:error, :legacy_snapshot_query_failed}
  end

  defp items(rows, cutover_at) do
    with {:ok, memories} <- memory_items(rows["memory_entries"], cutover_at),
         {:ok, schedules} <- schedule_items(rows["scheduled_tasks"], cutover_at),
         {:ok, behaviors} <- behavior_items(rows["standing_rules"], cutover_at),
         {:ok, episodes} <- episode_items(rows["work_episodes"]),
         {:ok, waits} <- wait_items(rows["episode_wakeups"], episodes) do
      items = Enum.sort_by(memories ++ schedules ++ behaviors ++ episodes ++ waits, & &1["id"])

      case Enum.find(items, &(CanonicalJSON.validate(&1, max_bytes: @maximum_item_bytes) != :ok)) do
        nil -> {:ok, items}
        item -> {:error, {:legacy_snapshot_item_too_large, item["id"]}}
      end
    end
  end

  defp memory_items(rows, cutover_at) do
    rows
    |> filter_unexpired(cutover_at)
    |> normalize_rows("memory_entries", %{"value_json" => :any})
    |> map_items(fn row ->
      kind = if row["predicate"] == "guidance", do: "behavior", else: "memory"
      item(kind, row, "memory_entries", "import")
    end)
  end

  defp schedule_items(rows, cutover_at) do
    rows
    |> filter_unexpired(cutover_at)
    |> Enum.filter(&(is_binary(&1["next_run_at"]) and &1["enabled"] in [0, 1]))
    |> normalize_rows("scheduled_tasks", %{"weekdays_json" => :optional_list})
    |> map_items(&item("schedule", &1, "scheduled_tasks", "import"))
  end

  defp behavior_items(rows, cutover_at) do
    rows
    |> filter_unexpired(cutover_at)
    |> Enum.filter(&(&1["enabled"] in [0, 1]))
    |> normalize_rows("standing_rules", %{"workflow_json" => :optional_map})
    |> map_items(&item("behavior", &1, "standing_rules", "import"))
  end

  defp episode_items(rows) do
    rows
    |> Enum.reject(&(&1["lifecycle_state"] in @terminal_episode_states))
    |> normalize_rows("work_episodes", %{
      "completion_criteria_json" => :list,
      "required_coverage_json" => :list
    })
    |> map_items(&item("episode", &1, "work_episodes", "review"))
  end

  defp wait_items(rows, episodes) do
    episode_refs = MapSet.new(episodes, & &1["source"]["ref"])

    rows
    |> Enum.filter(fn row ->
      row["state"] in ["pending", "leased"] and
        MapSet.member?(episode_refs, row["episode_id"])
    end)
    |> normalize_rows("episode_wakeups", %{"event_matcher_json" => :map})
    |> map_items(&item("wait", &1, "episode_wakeups", "review"))
  end

  defp normalize_rows(rows, table, fields) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, normalized} ->
      case normalize_row(row, table, fields) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_row(row, table, fields) do
    Enum.reduce_while(fields, {:ok, row}, fn {field, type}, {:ok, normalized} ->
      case decode_json(Map.get(normalized, field), type) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(normalized, field, decoded)}}
        :error -> {:halt, {:error, {:legacy_snapshot_invalid_field, table, field}}}
      end
    end)
  end

  defp decode_json(value, type) when is_binary(value) do
    case {type, String.trim(value)} do
      {:optional_map, ""} -> {:ok, %{}}
      {:optional_list, ""} -> {:ok, []}
      _other -> decode_json_value(value, type)
    end
  end

  defp decode_json(_value, _type), do: :error

  defp decode_json_value(value, :any) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  defp decode_json_value(value, type) when type in [:list, :optional_list] do
    case Jason.decode(value) do
      {:ok, nil} when type == :optional_list -> {:ok, []}
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp decode_json_value(value, type) when type in [:map, :optional_map] do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp map_items({:ok, rows}, mapper), do: {:ok, Enum.map(rows, mapper)}
  defp map_items({:error, reason}, _mapper), do: {:error, reason}

  defp item(kind, row, table, decision) do
    source_ref = row["id"]

    %{
      "data" => row,
      "decision" => decision,
      "id" => "#{kind}:#{source_ref}",
      "kind" => kind,
      "source" => %{
        "ref" => source_ref,
        "sha256" => CanonicalJSON.digest(row),
        "table" => table
      }
    }
  end

  defp filter_unexpired(rows, cutover_at) do
    Enum.filter(rows, fn row ->
      case utc_datetime(row["expires_at"]) do
        {:ok, expires_at} -> DateTime.compare(expires_at, cutover_at) == :gt
        :error -> false
      end
    end)
  end

  defp schema_version(%{"schema_version" => [%{"version" => version}]})
       when is_integer(version) and version > 0,
       do: {:ok, version}

  defp schema_version(_rows), do: {:error, :legacy_snapshot_schema_version_invalid}

  defp schema_identity(rows) do
    with {:ok, version} <- schema_version(rows),
         objects when is_list(objects) <- rows["schema_objects"],
         schema_sha256 <- CanonicalJSON.digest(objects),
         true <- LegacySchema.supported?(version, schema_sha256) do
      {:ok, %{sha256: schema_sha256, version: version}}
    else
      false -> {:error, :legacy_snapshot_schema_unsupported}
      {:error, _reason} = error -> error
      _invalid -> {:error, :legacy_snapshot_schema_fingerprint_invalid}
    end
  end

  defp manifest(settings, source_sha256, schema, items) do
    summary = items |> Enum.frequencies_by(& &1["kind"]) |> stringify_counts()

    %{
      "cutover_at" => DateTime.to_iso8601(settings.cutover_at),
      "items" => items,
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => schema.sha256,
        "schema_version" => schema.version,
        "sha256" => source_sha256
      },
      "summary" => summary,
      "version" => 1,
      "workspace_ref" => settings.workspace_ref
    }
  end

  defp stringify_counts(counts),
    do: Map.new(counts, fn {kind, count} -> {to_string(kind), count} end)

  defp unchanged(value, value), do: :ok
  defp unchanged(_before, _after), do: {:error, :legacy_snapshot_changed}

  defp file_sha256(path) do
    digest =
      path
      |> File.stream!([], 64 * 1_024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    _error -> {:error, :legacy_snapshot_read_failed}
  end

  defp utc_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, normalize(datetime)}
      _invalid -> :error
    end
  end

  defp utc_datetime(_value), do: :error

  defp normalize(%DateTime{microsecond: {microsecond, _precision}} = datetime),
    do: %{datetime | microsecond: {microsecond, 6}}

  defp valid_text?(value),
    do:
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
        String.trim(value) != ""

  defp system_command(executable, arguments),
    do: System.cmd(executable, arguments, stderr_to_stdout: true)
end
