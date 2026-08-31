defmodule Responder.Cutover.LegacySnapshotTest do
  use ExUnit.Case, async: true

  alias Responder.CanonicalJSON
  alias Responder.Cutover.LegacySnapshot

  @cutover_at ~U[2026-08-30 12:00:00.000000Z]

  test "the current Go migration fixture is the exact supported cutover schema" do
    source = source_file!("go-schema-v90")

    compressed =
      Path.expand("../../../testdata/cutover/go-schema-v90.sqlite3.gz", __DIR__)
      |> File.read!()

    File.write!(source, :zlib.gunzip(compressed))

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               sqlite3: System.find_executable("sqlite3"),
               workspace_ref: "slack:T123"
             )

    assert envelope["manifest"]["items"] == []

    assert envelope["manifest"]["source"] == %{
             "kind" => "responder_sqlite",
             "schema_sha256" =>
               "e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535",
             "schema_version" => 90,
             "sha256" => sha256(source)
           }
  end

  test "a frozen legacy snapshot becomes a sealed necessary-live-state inventory" do
    source = source_file!("inventory")
    runner = runner(source_rows())

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner,
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert envelope["sha256"] == CanonicalJSON.digest(envelope["manifest"])

    manifest = envelope["manifest"]
    assert manifest["version"] == 1
    assert manifest["cutover_at"] == DateTime.to_iso8601(@cutover_at)
    assert manifest["workspace_ref"] == "slack:T123"
    assert manifest["source"]["kind"] == "responder_sqlite"
    assert manifest["source"]["schema_version"] == 90

    assert manifest["source"]["schema_sha256"] ==
             "e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535"

    assert manifest["source"]["sha256"] == sha256(source)

    assert manifest["summary"] == %{
             "behavior" => 2,
             "episode" => 1,
             "memory" => 1,
             "schedule" => 2,
             "wait" => 1
           }

    assert Enum.map(manifest["items"], & &1["id"]) ==
             Enum.sort(Enum.map(manifest["items"], & &1["id"]))

    assert Enum.all?(manifest["items"], fn item ->
             item["source"]["sha256"] == CanonicalJSON.digest(item["data"])
           end)

    refute Enum.any?(manifest["items"], &(&1["source"]["ref"] == "memory-expired"))
    refute Enum.any?(manifest["items"], &(&1["source"]["ref"] == "episode-complete"))

    assert %{"decision" => "import", "kind" => "memory"} =
             item!(manifest, "memory:memory-live")

    assert %{"decision" => "import", "kind" => "behavior"} =
             item!(manifest, "behavior:memory-guidance")

    assert %{"decision" => "review", "kind" => "episode"} =
             item!(manifest, "episode:episode-live")

    assert %{"decision" => "review", "kind" => "wait"} =
             item!(manifest, "wait:wakeup-live")
  end

  test "inventory refuses mutable, sidecar-backed, malformed, and untrusted snapshots" do
    source = source_file!("refusals")
    File.write!(source <> "-wal", "pending")

    assert LegacySnapshot.inventory(source,
             cutover_at: @cutover_at,
             runner: runner(source_rows()),
             sqlite3: "/usr/bin/sqlite3",
             workspace_ref: "slack:T123"
           ) == {:error, {:legacy_snapshot_not_frozen, :wal}}

    File.rm!(source <> "-wal")

    malformed = fn _executable, arguments ->
      if String.contains?(List.last(arguments), "FROM memory_entries") do
        {"not-json", 0}
      else
        runner(source_rows()).("/usr/bin/sqlite3", arguments)
      end
    end

    assert {:error, {:legacy_snapshot_invalid_json, "memory_entries"}} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: malformed,
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert {:error, {:invalid_legacy_snapshot, :path}} =
             LegacySnapshot.inventory("relative.db",
               cutover_at: @cutover_at,
               runner: runner(source_rows()),
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert {:error, {:invalid_legacy_snapshot, :workspace_ref}} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner(source_rows()),
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "T123"
             )
  end

  test "inventory detects a source that changes while rows are read" do
    source = source_file!("mutation")
    delegate = runner(source_rows())

    runner = fn executable, arguments ->
      result = delegate.(executable, arguments)

      if String.contains?(List.last(arguments), "FROM episode_wakeups") do
        File.write!(source, "changed", [:append])
      end

      result
    end

    assert {:error, :legacy_snapshot_changed} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner,
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )
  end

  test "empty sqlite json query output is an empty legacy table" do
    source = source_file!("empty-table")
    rows = %{source_rows() | schedules: []}

    runner =
      rows
      |> runner()
      |> override_runner("FROM scheduled_tasks", {"", 0})

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner,
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    refute Map.has_key?(envelope["manifest"]["summary"], "schedule")
    refute Enum.any?(envelope["manifest"]["items"], &(&1["kind"] == "schedule"))
  end

  test "a legacy standing rule without a workflow keeps its narrow action fallback" do
    source = source_file!("blank-workflow")

    rows =
      update_in(source_rows().behaviors, fn [behavior] ->
        [%{behavior | "workflow_json" => ""}]
      end)

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner(rows),
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert item!(envelope["manifest"], "behavior:rule-live")["data"]["workflow_json"] ==
             %{}
  end

  test "terminal episode history does not consume the unfinished-work inventory bound" do
    source = source_file!("terminal-history")
    delegate = runner(source_rows())

    runner = fn executable, arguments ->
      sql = List.last(arguments)

      if String.contains?(sql, "FROM work_episodes") do
        if String.contains?(sql, "e.lifecycle_state NOT IN") do
          {Jason.encode!([episode("episode-live", "working")]), 0}
        else
          {Jason.encode!(List.duplicate(episode("episode-complete", "completed"), 501)), 0}
        end
      else
        delegate.(executable, arguments)
      end
    end

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner,
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert [%{"id" => "episode:episode-live"}] =
             Enum.filter(envelope["manifest"]["items"], &(&1["kind"] == "episode"))
  end

  test "a non-weekly legacy schedule may omit weekdays" do
    source = source_file!("optional-weekdays")

    rows =
      update_in(source_rows().schedules, fn [active, paused, expired] ->
        [%{active | "recurrence" => "daily", "weekdays_json" => "null"}, paused, expired]
      end)

    assert {:ok, envelope} =
             LegacySnapshot.inventory(source,
               cutover_at: @cutover_at,
               runner: runner(rows),
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    assert item!(envelope["manifest"], "schedule:schedule-active")["data"]["weekdays_json"] ==
             []
  end

  test "inventory validates every operator-controlled setting before reading" do
    source = source_file!("settings")
    valid = inventory_options(source)

    invalid_cases = [
      {Keyword.put(valid, :unknown, true), {:invalid_legacy_snapshot, :options}},
      {valid ++ [workspace_ref: "slack:T456"], {:invalid_legacy_snapshot, :options}},
      {Keyword.put(valid, :cutover_at, nil), {:invalid_legacy_snapshot, :cutover_at}},
      {Keyword.put(valid, :workspace_ref, nil), {:invalid_legacy_snapshot, :workspace_ref}},
      {Keyword.put(valid, :workspace_ref, "slack:\0"),
       {:invalid_legacy_snapshot, :workspace_ref}},
      {Keyword.put(valid, :runner, :not_a_function), {:invalid_legacy_snapshot, :runner}},
      {Keyword.put(valid, :sqlite3, "sqlite3"), {:invalid_legacy_snapshot, :sqlite3}},
      {Keyword.put(valid, :sqlite3, "/missing/sqlite3"), {:invalid_legacy_snapshot, :sqlite3}}
    ]

    for {options, reason} <- invalid_cases do
      assert {:error, ^reason} = LegacySnapshot.inventory(source, options)
    end

    assert {:error, {:invalid_legacy_snapshot, :path}} =
             LegacySnapshot.inventory(nil, valid)
  end

  test "inventory fails closed on corrupt commands, invalid rows, and row floods" do
    source = source_file!("command-failures")
    delegate = runner(source_rows())

    cases = [
      {fn _executable, _arguments -> {"corrupt", 0} end,
       {:error, :legacy_snapshot_integrity_failed}},
      {override_runner(delegate, "FROM memory_entries", {"failed", 1}),
       {:error, :legacy_snapshot_query_failed}},
      {override_runner(delegate, "FROM memory_entries", :invalid),
       {:error, :legacy_snapshot_runner_invalid}},
      {override_runner(delegate, "FROM memory_entries", fn -> raise "runner failed" end),
       {:error, :legacy_snapshot_query_failed}},
      {override_runner(delegate, "FROM memory_entries", {Jason.encode!(%{}), 0}),
       {:error, {:legacy_snapshot_invalid_rows, "memory_entries"}}},
      {override_runner(delegate, "FROM memory_entries", {Jason.encode!(["row"]), 0}),
       {:error, {:legacy_snapshot_invalid_rows, "memory_entries"}}},
      {override_runner(
         delegate,
         "FROM memory_entries",
         {Jason.encode!(
            List.duplicate(memory("flood", "alias_of", "2099-01-01T00:00:00Z"), 1_001)
          ), 0}
       ), {:error, {:legacy_snapshot_too_many_rows, "memory_entries"}}}
    ]

    for {runner, expected} <- cases do
      assert LegacySnapshot.inventory(source, inventory_options(source, runner: runner)) ==
               expected
    end
  end

  test "inventory rejects invalid source fields and oversized items" do
    source = source_file!("invalid-fields")

    cases = [
      {%{source_rows() | schema: [%{"version" => 0}]},
       {:error, :legacy_snapshot_schema_version_invalid}},
      {%{
         source_rows()
         | memories: [
             %{memory("bad-json", "alias_of", "2099-01-01T00:00:00Z") | "value_json" => "{"}
           ]
       }, {:error, {:legacy_snapshot_invalid_field, "memory_entries", "value_json"}}},
      {%{
         source_rows()
         | behaviors: [
             %{List.first(source_rows().behaviors) | "workflow_json" => "{"}
           ]
       }, {:error, {:legacy_snapshot_invalid_field, "standing_rules", "workflow_json"}}},
      {%{
         source_rows()
         | schedules: [
             %{List.first(source_rows().schedules) | "weekdays_json" => nil}
           ]
       }, {:error, {:legacy_snapshot_invalid_field, "scheduled_tasks", "weekdays_json"}}},
      {%{
         source_rows()
         | schedules: [
             %{List.first(source_rows().schedules) | "weekdays_json" => "{"}
           ]
       }, {:error, {:legacy_snapshot_invalid_field, "scheduled_tasks", "weekdays_json"}}},
      {%{
         source_rows()
         | memories: [
             %{
               memory("oversized", "alias_of", "2099-01-01T00:00:00Z")
               | "value_json" => Jason.encode!(%{"value" => String.duplicate("x", 270_000)})
             }
           ]
       }, {:error, {:legacy_snapshot_item_too_large, "memory:oversized"}}}
    ]

    for {rows, expected} <- cases do
      assert LegacySnapshot.inventory(source, inventory_options(source, runner: runner(rows))) ==
               expected
    end
  end

  defp runner(rows) do
    fn _executable, arguments ->
      sql = List.last(arguments)

      cond do
        String.contains?(sql, "PRAGMA quick_check") -> {"ok\n", 0}
        String.contains?(sql, "FROM sqlite_schema") -> {schema_objects_json(), 0}
        String.contains?(sql, "FROM schema_version") -> {Jason.encode!(rows.schema), 0}
        String.contains?(sql, "FROM memory_entries") -> {Jason.encode!(rows.memories), 0}
        String.contains?(sql, "FROM scheduled_tasks") -> {Jason.encode!(rows.schedules), 0}
        String.contains?(sql, "FROM standing_rules") -> {Jason.encode!(rows.behaviors), 0}
        String.contains?(sql, "FROM work_episodes") -> {Jason.encode!(rows.episodes), 0}
        String.contains?(sql, "FROM episode_wakeups") -> {Jason.encode!(rows.waits), 0}
      end
    end
  end

  defp override_runner(delegate, pattern, result) do
    fn executable, arguments ->
      if String.contains?(List.last(arguments), pattern) do
        runner_result(result)
      else
        delegate.(executable, arguments)
      end
    end
  end

  defp runner_result(result) when is_function(result, 0), do: result.()
  defp runner_result(result), do: result

  defp inventory_options(_source, overrides \\ []) do
    Keyword.merge(
      [
        cutover_at: @cutover_at,
        runner: runner(source_rows()),
        sqlite3: "/usr/bin/sqlite3",
        workspace_ref: "slack:T123"
      ],
      overrides
    )
  end

  defp source_rows do
    %{
      schema: [%{"version" => 90}],
      memories: [
        memory("memory-live", "alias_of", "2099-08-30T12:00:00.000000Z"),
        memory("memory-guidance", "guidance", "2099-08-30T12:00:00.000000Z"),
        memory("memory-expired", "evidence_route", "2020-01-01T00:00:00.000000Z")
      ],
      schedules: [
        schedule("schedule-active", 1, "2099-08-30T12:00:00.000000Z"),
        schedule("schedule-paused", 0, "2099-08-30T12:00:00.000000Z"),
        schedule("schedule-expired", 1, "2020-01-01T00:00:00.000000Z")
      ],
      behaviors: [
        %{
          "action_name" => "monitor_terraform_lifecycle",
          "acted_count" => 8,
          "actor_id" => "U123",
          "channel_id" => "C456",
          "created_at" => "2026-08-01T00:00:00.000000Z",
          "enabled" => 1,
          "expires_at" => "2099-08-30T12:00:00.000000Z",
          "id" => "rule-live",
          "last_triggered_at" => "2026-08-29T00:00:00.000000Z",
          "quiet_count" => 2,
          "repository" => "responder",
          "source_kind" => "app",
          "source_ref" => "message:rule",
          "trigger_count" => 10,
          "trigger_name" => "terraform_lifecycle",
          "updated_at" => "2026-08-29T00:00:00.000000Z",
          "workflow_json" => "{}",
          "workflow_name" => ""
        }
      ],
      episodes: [
        episode("episode-live", "working"),
        episode("episode-complete", "completed")
      ],
      waits: [
        %{
          "created_at" => "2026-08-29T00:00:00.000000Z",
          "deadline" => "2099-08-30T12:00:00.000000Z",
          "due_at" => "2099-08-30T11:00:00.000000Z",
          "episode_id" => "episode-live",
          "event_matcher_json" => "{\"kind\":\"terraform_run\"}",
          "id" => "wakeup-live",
          "kind" => "event",
          "poll_after" => nil,
          "state" => "pending",
          "updated_at" => "2026-08-29T00:00:00.000000Z",
          "verification" => "Verify the exact routed services."
        }
      ]
    }
  end

  defp memory(id, predicate, expires_at) do
    %{
      "actor_id" => "U123",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "expires_at" => expires_at,
      "id" => id,
      "last_recalled_at" => nil,
      "last_reviewed_at" => nil,
      "predicate" => predicate,
      "recall_count" => 3,
      "scope_key" => "C456",
      "scope_kind" => "channel",
      "source_ref" => "message:#{id}",
      "source_revision" => "1",
      "subject_key" => "checkout",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "value_hash" => String.duplicate("a", 64),
      "value_json" => Jason.encode!(%{"value" => "payments"}),
      "visibility_id" => "C456",
      "visibility_kind" => "channel"
    }
  end

  defp schedule(id, enabled, expires_at) do
    %{
      "actor_id" => "U123",
      "catch_up" => "latest",
      "channel_id" => "C456",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "day_of_month" => 0,
      "delivery_channel_id" => "C789",
      "enabled" => enabled,
      "expires_at" => expires_at,
      "id" => id,
      "interval_seconds" => 3600,
      "last_outcome" => "completed",
      "last_run_at" => "2026-08-29T00:00:00.000000Z",
      "local_time" => "",
      "next_run_at" => "2099-08-30T13:00:00.000000Z",
      "prompt" => "Check the deployment.",
      "recurrence" => "interval",
      "repository" => "responder",
      "source_ref" => "message:#{id}",
      "start_at" => "2026-08-01T00:00:00.000000Z",
      "team_id" => "T123",
      "thread_ts" => "1788000000.000100",
      "timezone" => "UTC",
      "title" => "Deployment check",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "weekdays_json" => "[]"
    }
  end

  defp episode(id, state) do
    %{
      "agent_run_id" => "run-#{id}",
      "anchor_ts" => "1788000000.000100",
      "authority" => "read_only",
      "authority_snapshot_ref" => "authority:#{id}",
      "channel_id" => "C456",
      "completion_criteria_json" => "[]",
      "coop_turn_id" => "turn-#{id}",
      "created_at" => "2026-08-29T00:00:00.000000Z",
      "destination_channel_id" => "C456",
      "destination_thread_ts" => "1788000000.000100",
      "effort" => "focused_check",
      "id" => id,
      "latest_attempt_id" => "attempt-#{id}",
      "lifecycle_state" => state,
      "mode" => "check",
      "next_action" => "Continue the accepted work.",
      "objective" => "Inspect checkout health.",
      "parent_episode_id" => "",
      "phase" => "working",
      "platform" => "slack",
      "repository" => "responder",
      "required_coverage_json" => "[]",
      "run_state" => "running",
      "session_id" => "session-#{id}",
      "source_id" => "source-#{id}",
      "source_kind" => "slack",
      "status" => "Working",
      "thread_ts" => "1788000000.000100",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "visibility" => "channel",
      "workspace_id" => "workspace-#{id}"
    }
  end

  defp source_file!(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "responder-cutover-#{suffix}-#{System.unique_integer([:positive])}.db"
      )

    File.write!(path, "frozen legacy snapshot")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp schema_objects_json do
    Path.expand("../../../testdata/cutover/go-schema-v90.objects.json.gz", __DIR__)
    |> File.read!()
    |> :zlib.gunzip()
  end

  defp item!(manifest, id), do: Enum.find(manifest["items"], &(&1["id"] == id))
end
