defmodule Responder.Cutover.ImporterTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Cutover.{Importer, Item, Ledger, LegacySchema, Rollback, Run}
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.State.{Behavior, MemoryEntry, Record, Schedule}
  alias Responder.Work.Session

  @cutover_at ~U[2026-08-30 12:00:00.000000Z]
  @policy_digest String.duplicate("d", 64)

  test "reviewed necessary live state is imported once with explicit cutover provenance" do
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert {:ok, %{status: :applied, run: %Run{id: run_id}}} =
             Importer.apply(run.id, work_profiles: work_profiles())

    assert run_id == run.id

    assert Repo.aggregate(
             from(item in Item, where: item.run_id == ^run.id and item.status == :applied),
             :count
           ) == 6

    memory = Repo.one!(from(value in MemoryEntry, where: not is_nil(value.cutover_item_id)))
    assert memory.offer_record_id == nil
    assert memory.kind == :alias
    assert memory.payload["value"] == "payments"
    assert memory.scope_ref == "slack:T123:C456"

    behaviors =
      Repo.all(
        from(value in Behavior,
          where: not is_nil(value.cutover_item_id),
          order_by: [asc: value.kind]
        )
      )

    assert Enum.map(behaviors, & &1.kind) == [:guidance, :standing_assignment]

    assert Enum.find(behaviors, &(&1.kind == :guidance)).payload["text"] ==
             "Prefer concise fixes."

    schedules =
      Repo.all(
        from(value in Schedule,
          where: not is_nil(value.cutover_item_id),
          order_by: [asc: value.ref]
        )
      )

    assert Enum.map(schedules, & &1.recurrence["weekday"]) == ["monday", "wednesday"]
    assert Enum.all?(schedules, &(&1.offer_record_id == nil and &1.source_episode_id == nil))

    episode = Repo.one!(from(value in Episode, where: not is_nil(value.cutover_item_id)))
    assert episode.state == :waiting_for_event
    assert episode.destination_transport == "slack"
    assert episode.destination_conversation_ref == "slack:T123:C456"
    assert episode.destination_thread_ref == "1788000000.000100"

    record = Repo.one!(from(value in Record, where: not is_nil(value.cutover_item_id)))
    assert record.turn_id == nil
    assert record.episode_id == episode.id
    assert record.kind == "event_wait"
    assert record.ref == episode.owner_ref
    assert record.payload["event_matcher"] == %{"kind" => "terraform_run"}

    session = Repo.one!(from(value in Session, where: value.episode_id == ^episode.id))
    assert session.policy == "responder-read-only-v1"
    assert session.policy_digest == @policy_digest
    assert session.repository_ref == "responder"

    assert {:ok, %{status: :duplicate}} =
             Importer.apply(run.id, work_profiles: work_profiles())

    assert Repo.aggregate(MemoryEntry, :count) == 1
    assert Repo.aggregate(Behavior, :count) == 2
    assert Repo.aggregate(Schedule, :count) == 2
    assert Repo.aggregate(Episode, :count) == 1
    assert Repo.aggregate(Record, :count) == 1
  end

  test "missing trusted episode placement rolls the complete import back" do
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert Importer.apply(run.id, work_profiles: %{}) ==
             {:error, {:cutover_work_profile_missing, "read_only", "responder"}}

    assert Repo.get!(Run, run.id).status == :prepared
    assert Repo.aggregate(MemoryEntry, :count) == 0
    assert Repo.aggregate(Behavior, :count) == 0
    assert Repo.aggregate(Schedule, :count) == 0
    assert Repo.aggregate(Episode, :count) == 0

    assert Repo.aggregate(
             from(item in Item, where: item.run_id == ^run.id and item.status == :pending),
             :count
           ) == 6
  end

  test "a repository-bearing legacy schedule remains read-only after cutover" do
    # Legacy schedules used a repository as context while the Go runtime always
    # executed them read-only. Treating that field as authority silently grants
    # write access during the one irreversible production transition.
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert {:ok, %{status: :applied}} =
             Importer.apply(run.id, work_profiles: work_profiles())

    schedules = Repo.all(from(value in Schedule, order_by: [asc: value.ref]))

    assert Enum.map(schedules, &{&1.authority, &1.repository}) == [
             {:read_only, "responder"},
             {:read_only, "responder"}
           ]
  end

  test "an untouched complete import rolls back every target while retaining the reviewed ledger" do
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert {:ok, %{status: :applied}} =
             Importer.apply(run.id, work_profiles: work_profiles())

    assert Repo.aggregate(MemoryEntry, :count) == 1
    assert Repo.aggregate(Behavior, :count) == 2
    assert Repo.aggregate(Schedule, :count) == 2
    assert Repo.aggregate(Episode, :count) == 1
    assert Repo.aggregate(Record, :count) == 1
    assert Repo.aggregate(Session, :count) == 1

    assert {:ok, %{status: :rolled_back, run: rolled_back}} =
             Rollback.rollback(run.id, "operator:andrew")

    assert rolled_back.rolled_back_by == "operator:andrew"
    assert Repo.aggregate(MemoryEntry, :count) == 0
    assert Repo.aggregate(Behavior, :count) == 0
    assert Repo.aggregate(Schedule, :count) == 0
    assert Repo.aggregate(Episode, :count) == 0
    assert Repo.aggregate(Record, :count) == 0
    assert Repo.aggregate(Session, :count) == 0

    assert Repo.aggregate(
             from(item in Item, where: item.run_id == ^run.id and item.status == :rolled_back),
             :count
           ) == 6
  end

  test "an unknown legacy standing-rule source cannot widen into any actor" do
    data = Map.put(standing_rule(), "source_kind", "external_integration")
    behavior = item("behavior", "legacy-rule", "standing_rules", "import", data)

    manifest = %{
      "cutover_at" => DateTime.to_iso8601(@cutover_at),
      "items" => [behavior],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{"behavior" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    envelope = %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}

    review = %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }

    assert {:ok, %{run: run}} = Ledger.prepare(envelope, review)

    assert Importer.apply(run.id) ==
             {:error, {:cutover_mapping_invalid, :source_kind}}

    assert Repo.get!(Run, run.id).status == :prepared
    assert Repo.aggregate(Behavior, :count) == 0
    assert Repo.one!(from(value in Item, where: value.run_id == ^run.id)).status == :pending
  end

  test "every supported legacy schedule cadence keeps its timing contract" do
    schedules = [
      {"once", %{"recurrence" => "once", "next_run_at" => "2026-08-31T13:00:00.000000Z"}},
      {"interval",
       %{
         "interval_seconds" => 3_600,
         "recurrence" => "interval",
         "start_at" => "2026-08-30T10:30:00.000000Z"
       }},
      # The retained Blitz schedule uses the legacy HH:MM representation. A
      # cutover rehearsal used to reject the complete atomic import here.
      {"daily", %{"local_time" => "13:00", "recurrence" => "daily"}},
      {"monthly", %{"day_of_month" => 31, "local_time" => "13:00:00", "recurrence" => "monthly"}}
    ]

    items =
      Enum.map(schedules, fn {name, recurrence} ->
        data =
          schedule()
          |> Map.merge(recurrence)
          |> Map.put("id", "legacy-schedule-#{name}")

        item("schedule", "legacy-schedule-#{name}", "scheduled_tasks", "import", data)
      end)

    manifest = %{
      "cutover_at" => DateTime.to_iso8601(@cutover_at),
      "items" => Enum.sort_by(items, & &1["id"]),
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{"schedule" => length(items)},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    envelope = %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}

    review = %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }

    assert {:ok, %{run: run}} = Ledger.prepare(envelope, review)
    assert {:ok, %{status: :applied}} = Importer.apply(run.id)

    imported =
      Schedule
      |> Repo.all()
      |> Enum.sort_by(& &1.recurrence["kind"])

    assert Enum.map(imported, & &1.recurrence) == [
             %{"kind" => "daily", "time" => "13:00:00"},
             %{
               "every_seconds" => 3_600,
               "kind" => "interval",
               "starts_at" => "2026-08-30T10:30:00.000000Z"
             },
             %{"day" => 31, "kind" => "monthly", "time" => "13:00:00"},
             %{"at" => "2026-08-31T13:00:00.000000Z", "kind" => "once"}
           ]

    assert Enum.map(imported, & &1.next_occurrence_at) == [
             ~U[2026-08-30 13:00:00.000000Z],
             ~U[2026-08-30 12:30:00.000000Z],
             ~U[2026-08-31 13:00:00.000000Z],
             ~U[2026-08-31 13:00:00.000000Z]
           ]
  end

  test "supported legacy scopes, disabled automation, and input waits keep their semantics" do
    repository_memory =
      memory()
      |> Map.merge(%{
        "id" => "legacy-repository-memory",
        "predicate" => "repository_binding",
        "scope_key" => "responder",
        "scope_kind" => "repository",
        "source_ref" => "message:repository-memory",
        "subject_key" => "checkout",
        "value_json" => "responder",
        "visibility_kind" => "public"
      })

    workspace_memory =
      memory()
      |> Map.merge(%{
        "id" => "legacy-workspace-memory",
        "predicate" => "evidence_route",
        "scope_kind" => "workspace",
        "source_ref" => "message:workspace-memory",
        "subject_key" => "deploy_evidence",
        "value_json" => %{"channel" => "C789"},
        "visibility_kind" => "workspace"
      })

    relationship_memory =
      memory()
      |> Map.merge(%{
        "id" => "legacy-relationship-memory",
        "predicate" => "entity_relationship_correction",
        "scope_kind" => "public",
        "source_ref" => "message:relationship-memory",
        "subject_key" => "payments_owner",
        "value_json" => "team-platform",
        "visibility_kind" => "public"
      })

    disabled_rule =
      standing_rule()
      |> Map.merge(%{
        "enabled" => 0,
        "source_kind" => "human",
        "workflow_json" => %{}
      })

    paused_schedule =
      schedule()
      |> Map.merge(%{
        "catch_up" => "skip",
        "enabled" => 0,
        "local_time" => "13:00:00",
        "recurrence" => "daily"
      })

    input_wait =
      wait()
      |> Map.merge(%{
        "deadline" => nil,
        "due_at" => nil,
        "event_matcher_json" => nil,
        "kind" => "input",
        "verification" => "Choose the deployment window."
      })

    items = [
      item("behavior", "legacy-rule", "standing_rules", "import", disabled_rule),
      item("episode", "legacy-episode", "work_episodes", "review", episode()),
      item(
        "memory",
        "legacy-relationship-memory",
        "memory_entries",
        "import",
        relationship_memory
      ),
      item(
        "memory",
        "legacy-repository-memory",
        "memory_entries",
        "import",
        repository_memory
      ),
      item(
        "memory",
        "legacy-workspace-memory",
        "memory_entries",
        "import",
        workspace_memory
      ),
      item("schedule", "legacy-schedule", "scheduled_tasks", "import", paused_schedule),
      item("wait", "legacy-wait", "episode_wakeups", "review", input_wait)
    ]

    manifest = %{
      "cutover_at" => DateTime.to_iso8601(@cutover_at),
      "items" => Enum.sort_by(items, & &1["id"]),
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{
        "behavior" => 1,
        "episode" => 1,
        "memory" => 3,
        "schedule" => 1,
        "wait" => 1
      },
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    envelope = %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}

    review = %{
      "decisions" => %{
        "episode:legacy-episode" => "import",
        "wait:legacy-wait" => "import"
      },
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }

    assert {:ok, %{run: run}} = Ledger.prepare(envelope, review)

    assert {:ok, %{status: :applied}} =
             Importer.apply(run.id, work_profiles: work_profiles())

    memories = Repo.all(from(value in MemoryEntry, order_by: [asc: value.subject]))

    assert Enum.map(memories, &{&1.kind, &1.scope_kind, &1.scope_ref, &1.visibility}) == [
             {:repository_binding, :repository, "responder", :workspace},
             {:evidence_route, :workspace, "slack:T123", :workspace},
             {:entity_relationship, :workspace, "slack:T123", :workspace}
           ]

    assert Enum.map(memories, & &1.payload["value"]) == [
             "responder",
             ~s({"channel":"C789"}),
             "team-platform"
           ]

    behavior = Repo.one!(Behavior)
    assert behavior.status == :disabled
    assert behavior.payload["source_filter"] == "human"
    assert behavior.payload["task"] == "review_terraform_plan"

    imported_schedule = Repo.one!(Schedule)
    assert imported_schedule.status == :paused
    assert imported_schedule.catch_up == :skip
    assert imported_schedule.recurrence == %{"kind" => "daily", "time" => "13:00:00"}

    imported_wait = Repo.one!(Record)
    assert imported_wait.kind == "input_request"

    assert imported_wait.payload == %{
             "choices" => [],
             "question" => "Choose the deployment window."
           }

    imported_episode = Repo.one!(Episode)
    assert imported_episode.state == :waiting_for_input
    assert imported_episode.owner_ref == imported_wait.ref
  end

  test "unsupported legacy memory shapes and invalid importer arguments fail closed" do
    assert Importer.apply("not-a-uuid") == {:error, {:invalid_cutover_import, :run_id}}
    assert Importer.apply(Ecto.UUID.generate()) == {:error, :cutover_run_not_found}

    assert Importer.apply(Ecto.UUID.generate(), unknown: true) ==
             {:error, {:invalid_cutover_import, :options}}

    assert Importer.apply(Ecto.UUID.generate(), work_profiles: []) ==
             {:error, {:invalid_cutover_import, :work_profiles}}

    cases = [
      {Map.put(memory(), "predicate", "freeform_note"),
       {:cutover_memory_predicate_unsupported, "freeform_note"}},
      {Map.put(memory(), "scope_kind", "organization"),
       {:cutover_mapping_invalid, :memory_scope}},
      {Map.put(memory(), "visibility_kind", "team"),
       {:cutover_mapping_invalid, :memory_visibility}},
      {Map.put(memory(), "value_json", String.duplicate("x", 4_001)),
       {:cutover_mapping_invalid, :memory_value}}
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{data, expected}, index} ->
      envelope = single_memory_envelope(data, index)
      memory_review = envelope |> review() |> Map.put("decisions", %{})
      {:ok, %{run: run}} = Ledger.prepare(envelope, memory_review)

      assert Importer.apply(run.id) == {:error, expected}
      assert Repo.get!(Run, run.id).status == :prepared
    end)

    assert Repo.aggregate(MemoryEntry, :count) == 0
  end

  test "a reviewed skip stays state-free through apply and rollback" do
    envelope =
      memory()
      |> single_memory_envelope(9)
      |> reseal_items(fn item -> Map.put(item, "decision", "review") end)

    skipped_review =
      envelope
      |> review()
      |> Map.put("decisions", %{"memory:legacy-memory-9" => "skip"})

    assert {:ok, %{run: run}} = Ledger.prepare(envelope, skipped_review)
    assert {:ok, %{status: :applied}} = Importer.apply(run.id)
    assert Repo.aggregate(MemoryEntry, :count) == 0

    item = Repo.one!(from(value in Item, where: value.run_id == ^run.id))
    assert item.status == :skipped
    assert item.target_refs == nil

    assert {:ok, %{status: :rolled_back}} = Rollback.rollback(run.id, "operator:andrew")

    assert Importer.apply(run.id) ==
             {:error, {:cutover_run_not_applicable, :rolled_back}}
  end

  test "an unsupported legacy schedule cadence fails the atomic import" do
    envelope =
      envelope()
      |> reseal_items(fn
        %{"kind" => "schedule"} = item ->
          data = Map.put(item["data"], "recurrence", "yearly")

          item
          |> Map.put("data", data)
          |> put_in(["source", "sha256"], CanonicalJSON.digest(data))

        item ->
          item
      end)

    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert Importer.apply(run.id, work_profiles: work_profiles()) ==
             {:error, :invalid_recurrence}

    assert Repo.get!(Run, run.id).status == :prepared
    assert Repo.aggregate(MemoryEntry, :count) == 0
    assert Repo.aggregate(Behavior, :count) == 0
    assert Repo.aggregate(Schedule, :count) == 0
    assert Repo.aggregate(Episode, :count) == 0
  end

  defp work_profiles do
    %{
      {"read_only", "responder"} => %{
        policy: "responder-read-only-v1",
        policy_digest: @policy_digest,
        repository_ref: "responder"
      }
    }
  end

  defp envelope do
    items = [
      item("behavior", "legacy-guidance", "memory_entries", "import", guidance()),
      item("behavior", "legacy-rule", "standing_rules", "import", standing_rule()),
      item("episode", "legacy-episode", "work_episodes", "review", episode()),
      item("memory", "legacy-memory", "memory_entries", "import", memory()),
      item("schedule", "legacy-schedule", "scheduled_tasks", "import", schedule()),
      item("wait", "legacy-wait", "episode_wakeups", "review", wait())
    ]

    manifest = %{
      "cutover_at" => DateTime.to_iso8601(@cutover_at),
      "items" => Enum.sort_by(items, & &1["id"]),
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{
        "behavior" => 2,
        "episode" => 1,
        "memory" => 1,
        "schedule" => 1,
        "wait" => 1
      },
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end

  defp single_memory_envelope(data, index) do
    source_ref = "legacy-memory-#{index}"
    item = item("memory", source_ref, "memory_entries", "import", Map.put(data, "id", source_ref))

    manifest = %{
      "cutover_at" => DateTime.to_iso8601(@cutover_at),
      "items" => [item],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate(Integer.to_string(index), 64)
      },
      "summary" => %{"memory" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end

  defp reseal_items(envelope, update) do
    manifest = Map.update!(envelope["manifest"], "items", &Enum.map(&1, update))
    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end

  defp review(envelope) do
    %{
      "decisions" => %{
        "episode:legacy-episode" => "import",
        "wait:legacy-wait" => "import"
      },
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }
  end

  defp item(kind, source_ref, table, decision, data) do
    %{
      "data" => data,
      "decision" => decision,
      "id" => "#{kind}:#{source_ref}",
      "kind" => kind,
      "source" => %{
        "ref" => source_ref,
        "sha256" => CanonicalJSON.digest(data),
        "table" => table
      }
    }
  end

  defp memory do
    %{
      "actor_id" => "U123",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "expires_at" => "2099-08-30T12:00:00.000000Z",
      "id" => "legacy-memory",
      "last_recalled_at" => nil,
      "last_reviewed_at" => nil,
      "predicate" => "alias_of",
      "recall_count" => 3,
      "scope_key" => "C456",
      "scope_kind" => "channel",
      "source_ref" => "message:memory",
      "source_revision" => "1",
      "subject_key" => "checkout",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "value_hash" => String.duplicate("a", 64),
      "value_json" => %{"value" => "payments"},
      "visibility_id" => "C456",
      "visibility_kind" => "channel"
    }
  end

  defp guidance do
    memory()
    |> Map.merge(%{
      "id" => "legacy-guidance",
      "predicate" => "guidance",
      "source_ref" => "message:guidance",
      "subject_key" => "fix_style",
      "value_json" => %{"value" => "Prefer concise fixes."}
    })
  end

  defp standing_rule do
    %{
      "action_name" => "review_terraform_plan",
      "acted_count" => 8,
      "actor_id" => "U123",
      "channel_id" => "C456",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "enabled" => 1,
      "expires_at" => "2099-08-30T12:00:00.000000Z",
      "id" => "legacy-rule",
      "last_triggered_at" => "2026-08-29T00:00:00.000000Z",
      "quiet_count" => 2,
      "repository" => "responder",
      "source_kind" => "app",
      "source_ref" => "message:rule",
      "trigger_count" => 10,
      "trigger_name" => "terraform_plan",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "workflow_json" => %{"task" => "Review the Terraform plan."},
      "workflow_name" => "terraform-review"
    }
  end

  defp schedule do
    %{
      "actor_id" => "U123",
      "catch_up" => "latest",
      "channel_id" => "C456",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "day_of_month" => 0,
      "delivery_channel_id" => "C789",
      "enabled" => 1,
      "expires_at" => "2099-08-30T12:00:00.000000Z",
      "id" => "legacy-schedule",
      "interval_seconds" => 0,
      "last_outcome" => "completed",
      "last_run_at" => "2026-08-29T00:00:00.000000Z",
      "local_time" => "09:30:00",
      "next_run_at" => "2026-08-31T09:30:00.000000Z",
      "prompt" => "Check the deployment.",
      "recurrence" => "weekly",
      "repository" => "responder",
      "source_ref" => "message:schedule",
      "start_at" => "2026-08-01T00:00:00.000000Z",
      "team_id" => "T123",
      "thread_ts" => "1788000000.000100",
      "timezone" => "UTC",
      "title" => "Deployment check",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "weekdays_json" => ["monday", "wednesday"]
    }
  end

  defp episode do
    %{
      "agent_run_id" => "run-legacy-episode",
      "anchor_ts" => "1788000000.000100",
      "authority" => "read_only",
      "authority_snapshot_ref" => "authority:legacy-episode",
      "channel_id" => "C456",
      "completion_criteria_json" => [],
      "coop_turn_id" => "turn-legacy-episode",
      "created_at" => "2026-08-29T00:00:00.000000Z",
      "destination_channel_id" => "C456",
      "destination_thread_ts" => "1788000000.000100",
      "effort" => "focused_check",
      "id" => "legacy-episode",
      "latest_attempt_id" => "attempt-legacy-episode",
      "lifecycle_state" => "working",
      "mode" => "check",
      "next_action" => "Continue the accepted work.",
      "objective" => "Inspect checkout health.",
      "parent_episode_id" => "",
      "phase" => "working",
      "platform" => "slack",
      "repository" => "responder",
      "required_coverage_json" => [],
      "run_state" => "running",
      "session_id" => "session-legacy-episode",
      "source_id" => "source-legacy-episode",
      "source_kind" => "slack",
      "status" => "Working",
      "thread_ts" => "1788000000.000100",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "visibility" => "channel",
      "workspace_id" => "workspace-legacy-episode"
    }
  end

  defp wait do
    %{
      "created_at" => "2026-08-29T00:00:00.000000Z",
      "deadline" => "2099-08-30T12:00:00.000000Z",
      "due_at" => "2099-08-30T11:00:00.000000Z",
      "episode_id" => "legacy-episode",
      "event_matcher_json" => %{"kind" => "terraform_run"},
      "id" => "legacy-wait",
      "kind" => "event",
      "poll_after" => nil,
      "state" => "pending",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "verification" => "Verify the exact routed services."
    }
  end
end
