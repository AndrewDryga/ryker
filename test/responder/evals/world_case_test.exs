defmodule Responder.Evals.WorldCaseTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.{WorldCase, WorldCassette}
  alias Responder.StateTools.Tools

  @scenario_root "testdata/scenarios"
  @health_scenario "va1-health-review-repairs-and-finishes"

  @tag :grafana_scope
  test "the fabricated Grafana endpoint discloses its scope without rewriting source evidence" do
    # Three real-model runs correctly refused to guess the missing environment;
    # the cassette accepted only production/prod. Tool-world setup must disclose
    # that scope without altering original messages, responses, or expectations.
    id = "grafana-firing-resolved-stays-in-cycle"
    assert {:ok, scenario} = WorldCase.fetch(id)
    assert {:ok, shared} = WorldCase.fetch(@health_scenario)
    tools = WorldCase.fabricated_tools(scenario)
    original = WorldCase.fabricated_tools(shared)
    query = Enum.find(tools, &(&1["name"] == "monitoring.query"))
    assert query["description"] =~ "scoped to the production environment (alias prod)"
    assert query["description"] =~ "historical replay observations"

    without_query_description = fn definitions ->
      Enum.map(definitions, fn
        %{"name" => "monitoring.query"} = tool -> Map.delete(tool, "description")
        tool -> tool
      end)
    end

    assert without_query_description.(tools) == without_query_description.(original)
    assert WorldCase.state_tools(scenario) == WorldCase.state_tools(shared)

    refute Enum.find(original, &(&1["name"] == "monitoring.query"))["description"] =~
             "This fabricated monitoring endpoint"

    source = File.read!(Path.join([@scenario_root, id, "scenario.json"]))

    assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) ==
             "3cd6f0ace1aa08dfa2cae2ee116536e96442708b34a6408d96d42c9e0829b80f"
  end

  test "Airflow verification includes its pinned GCP scope before asking for live observations" do
    # The real model refused to guess an environment that the old scenario had
    # removed, and its Nomad facade contradicted the original GCP repository.
    assert {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")
    payload = hd(scenario.events)["payload"]
    assert [production, va1] = payload["repository_excerpts"]
    assert production["commit"] == "99183465ac95a33f1312a4f4973b66b736a55606"
    assert production["path"] == "terraform/environments/production/app_datalake.tf"
    assert production["text"] =~ "module \"airflow\""
    assert production["text"] =~ "google-cloud/container"
    assert va1["text"] =~ "deliberately NOT ported"
    assert va1["text"] =~ "stays in GCP"
    assert payload["source_message"]["text"] =~ "run-vMEdeDLHwpWZsBYH"
    tools = WorldCase.fabricated_tools(scenario) |> Enum.map(& &1["name"])
    assert "gcp.deployment" in tools
    assert "gcp.backend_health" in tools
    refute Enum.any?(tools, &String.starts_with?(&1, "nomad."))
    assert Enum.any?(scenario.expect["hard"], &(&1["tool"] == "record_finding"))
  end

  test "compiles the versioned model-world scenario matrix" do
    assert {:ok, scenarios} = WorldCase.all(@scenario_root)
    assert length(scenarios) == 21
    assert {:ok, scenario} = WorldCase.fetch(@health_scenario, @scenario_root)

    assert scenario.id == "va1-health-review-repairs-and-finishes"
    assert scenario.provenance["kind"] == "production"
    assert "model-world" in scenario.tags
    assert scenario.host_replay["model_events"] != []
    assert scenario.world["tool_rules"] != []
    assert scenario.tool_catalog_digest =~ ~r/\A[0-9a-f]{64}\z/

    document = WorldCase.document(scenario)
    assert document["scenario"]["id"] == scenario.id
    assert document["tool_catalog_sha256"] == scenario.tool_catalog_digest
  end

  test "the missing-project scenario retains the actual review without invented discovery results" do
    original =
      "testdata/work/missing-project-clarification.json" |> File.read!() |> Jason.decode!()

    assert {:ok, scenario} = WorldCase.fetch("missing-project-review-asks-for-context")
    assert scenario.provenance["kind"] == "synthetic"
    assert scenario.provenance["episode_refs"] == [original["source"]["episode_id"]]
    assert [event] = scenario.events
    assert event["payload"]["retained_review"]["message"] == original["candidate"]["message"]

    assert event["payload"]["original_terraform_notification"] ==
             original["inputs"]["rows"] |> hd() |> Enum.at(4)

    assert scenario.world["tool_rules"] == []
    assert WorldCase.fabricated_tools(scenario) == []
    assert scenario.host_replay["model_events"] == []
    assert Enum.any?(scenario.expect["hard"], &(&1["tool"] == "request_input"))
    assert Enum.any?(scenario.expect["hard"], &(&1["tool"] == "wait_for"))
  end

  test "host replay scenarios carry recorded model actions in the same versioned unit" do
    assert {:ok, scenarios} = WorldCase.all(@scenario_root)

    replayed = Enum.filter(scenarios, &("host-replay" in &1.tags))

    assert MapSet.new(replayed, & &1.id) ==
             MapSet.new([
               "airflow-verification-arms-wait",
               "application-errors-follow-the-current-signal",
               "artifact-delivery-survives-work-handoff",
               "creative-request-needs-no-fake-evidence",
               "concurrent-human-feedback-serializes",
               "current-uptime-check-uses-fresh-source",
               "grafana-firing-resolved-stays-in-cycle",
               "github-pr-review-remains-in-thread",
               "noisy-context-keeps-current-request",
               "ordinary-thread-question-gets-natural-answer",
               "terraform-run-update-stays-in-one-session",
               "universal-webhook-unknown-payload",
               "va1-health-review-repairs-and-finishes",
               "worker-loss-reconciles-frozen-turn"
             ])

    assert Enum.all?(replayed, &(&1.host_replay["model_events"] != []))
  end

  test "worker-loss fault injection is not leaked into the model-visible request" do
    assert {:ok, scenario} =
             WorldCase.fetch("worker-loss-reconciles-frozen-turn", @scenario_root)

    assert Enum.any?(scenario.host_replay["model_events"], fn event ->
             "crash_after_submit" in Map.get(event, "faults", [])
           end)

    [input] = scenario.events
    request = input["payload"]["text"]

    refute request =~ ~r/worker|retry|crash|failover/i
  end

  test "the Airflow world preserves both production rechecks and their bounded source evidence" do
    assert {:ok, scenario} =
             WorldCase.fetch("airflow-verification-arms-wait", @scenario_root)

    assert length(scenario.world["scheduled_events"]) == 2
    assert length(scenario.host_replay["model_events"]) == 3

    assert Enum.all?(scenario.world["scheduled_events"], fn event ->
             event["kind"] == "wait_wakeup" and
               Enum.sort(Map.keys(event)) == ~w(kind occurred_at)
           end)

    assert Enum.find(scenario.actors, &(&1["authority"] == "source_event"))["actor_ref"] ==
             "slack:bot:B08N64XSHNU"

    refute Enum.any?(scenario.actors, &(&1["input_profile"]["source"]["kind"] == "system"))

    assert MapSet.new(scenario.world["tool_rules"], & &1["tool"]) ==
             MapSet.new(["monitoring.query", "gcp.deployment", "gcp.backend_health"])

    assert {:ok, cassette} = WorldCassette.start_link(scenario)
    on_exit(fn -> if Process.alive?(cassette), do: GenServer.stop(cassette) end)

    # Wrong-scope reads must not receive production health from the cassette.
    for tool <- ["gcp.deployment", "gcp.backend_health", "monitoring.query"] do
      assert {:error, %{"code" => "unmatched_fabricated_tool_call"}} =
               WorldCassette.call(cassette, tool, %{
                 "environment" => "va1",
                 "service" => "airflow",
                 "query" => "airflow revision 99183465"
               })
    end

    for {tool, arguments} <- [
          {"gcp.deployment", %{"environment" => "production"}},
          {"gcp.backend_health", %{"environment" => "production", "service" => "airflow"}},
          {"monitoring.query",
           %{
             "environment" => "production",
             "query" => "airflow revision 99183465"
           }}
        ] do
      assert {:ok, first} = WorldCassette.call(cassette, tool, arguments)
      assert {:ok, second} = WorldCassette.call(cassette, tool, arguments)
      assert first["source_ref"] != second["source_ref"]

      assert {:ok, first_at, 0} = DateTime.from_iso8601(first["observed_at"])
      assert {:ok, second_at, 0} = DateTime.from_iso8601(second["observed_at"])
      assert DateTime.compare(first_at, second_at) == :lt
    end
  end

  test "scheduled wakeups cannot supply a source actor or external authority" do
    invalid_actors = [
      %{
        "actor_ref" => "slack:user:U-operator",
        "authority" => "operator",
        "input_profile" => %{
          "actor" => %{"kind" => "user", "ref" => "U-operator"},
          "event_kind" => "message",
          "occurred_at_source" => "source",
          "source" => %{"kind" => "slack", "ref" => "TEVAL"},
          "source_capabilities" => %{"react" => %{"emoji_names" => nil}}
        },
        "kind" => "human"
      },
      %{
        "actor_ref" => "slack:bot:B-automation",
        "authority" => "source_event",
        "input_profile" => %{
          "actor" => %{"kind" => "bot", "ref" => "B-automation"},
          "event_kind" => "message",
          "occurred_at_source" => "source",
          "source" => %{"kind" => "slack", "ref" => "TEVAL"},
          "source_capabilities" => %{"react" => %{"emoji_names" => nil}}
        },
        "kind" => "automation"
      },
      %{
        "actor_ref" => "github:user:501",
        "authority" => "repository_write_offer",
        "input_profile" => %{
          "actor" => %{"kind" => "user", "ref" => "501"},
          "event_kind" => "message",
          "occurred_at_source" => "source",
          "source" => %{"kind" => "github", "ref" => "eval"},
          "source_capabilities" => %{"react" => %{"emoji_names" => ["+1"]}}
        },
        "kind" => "human"
      }
    ]

    Enum.each(invalid_actors, fn invalid_actor ->
      {fixture, case_id, scenario_path} =
        copy_scenario_fixture!("airflow-verification-arms-wait")

      on_exit(fn -> File.rm_rf!(fixture) end)

      scenario = scenario_path |> File.read!() |> Jason.decode!()
      source_actor = hd(scenario["actors"])

      scenario =
        scenario
        |> Map.put("actors", [source_actor, invalid_actor])
        |> update_in(["world", "scheduled_events"], fn events ->
          Enum.map(events, &Map.put(&1, "actor_ref", invalid_actor["actor_ref"]))
        end)

      File.write!(scenario_path, Jason.encode!(scenario))

      assert {:error, {:invalid_world_case, ^case_id, :scheduled_events}} =
               WorldCase.all(fixture)
    end)
  end

  test "scheduled wakeups reject the replaced poll fallback shape and injected envelopes" do
    for injected <- [
          %{"kind" => "poll_fallback"},
          %{"actor_ref" => "system:system:event-wait-timer"},
          %{"authority" => "operator"},
          %{"payload" => %{"kind" => "timer_due"}},
          %{"input_profile" => %{"source" => %{"kind" => "system", "ref" => "responder"}}}
        ] do
      {fixture, case_id, scenario_path} =
        copy_scenario_fixture!("airflow-verification-arms-wait")

      on_exit(fn -> File.rm_rf!(fixture) end)

      scenario = scenario_path |> File.read!() |> Jason.decode!()

      event =
        Map.merge(
          %{"kind" => "wait_wakeup", "occurred_at" => "2026-08-27T20:28:13Z"},
          injected
        )

      scenario = put_in(scenario, ["world", "scheduled_events"], [event])
      File.write!(scenario_path, Jason.encode!(scenario))

      assert {:error, {:invalid_world_case, ^case_id, :scheduled_events}} =
               WorldCase.all(fixture)
    end
  end

  test "GitHub reaction authority requires an exact top-level fixture item" do
    for mutate <- [
          fn scenario ->
            update_in(scenario, ["events", Access.at(0)], &Map.delete(&1, "source_item_ref"))
          end,
          fn scenario ->
            put_in(
              scenario,
              ["events", Access.at(0), "source_item_ref"],
              "github:issue_comment:not-an-id"
            )
          end
        ] do
      {fixture, case_id, scenario_path} =
        copy_scenario_fixture!("github-pr-review-remains-in-thread")

      on_exit(fn -> File.rm_rf!(fixture) end)

      scenario = scenario_path |> File.read!() |> Jason.decode!() |> mutate.()
      File.write!(scenario_path, Jason.encode!(scenario))

      assert {:error, {:invalid_world_case, ^case_id, :events}} = WorldCase.all(fixture)
    end
  end

  test "the current uptime world returns a host-issued reference that can be cited" do
    assert {:ok, scenario} =
             WorldCase.fetch("current-uptime-check-uses-fresh-source", @scenario_root)

    assert {:ok, cassette} = WorldCassette.start_link(scenario)
    on_exit(fn -> if Process.alive?(cassette), do: GenServer.stop(cassette) end)

    assert {:ok, observation} =
             WorldCassette.call(cassette, "monitoring.query", %{
               "environment" => "production",
               "query" => "time() - node_boot_time_seconds{instance=\"nomad-hvn03\"}"
             })

    assert observation["source_ref"] == "source:nomad-hvn03:health:20260830T142003Z"
    assert observation["observed_at"] == "2026-08-30T14:20:03Z"
    assert observation["uptime_seconds"] == 734_400
  end

  test "free-form monitoring queries never depend on hidden exact phrase aliases" do
    assert {:ok, scenarios} = WorldCase.all(@scenario_root)

    query_patterns =
      Enum.flat_map(scenarios, fn scenario ->
        rules =
          for %{"match" => %{"query" => query}, "tool" => "monitoring.query"} <-
                scenario.world["tool_rules"],
              do: {scenario.id, query}

        trajectory =
          for %{"arguments" => %{"query" => query}, "tool" => "monitoring.query"} <-
                scenario.expect["trajectory"],
              do: {scenario.id, query}

        rules ++ trajectory
      end)

    assert query_patterns != []

    refute Enum.any?(query_patterns, fn {_scenario_id, pattern} ->
             match?(%{"$one_of" => aliases} when is_list(aliases), pattern) and
               Enum.all?(pattern["$one_of"], &is_binary/1)
           end)
  end

  test "the scenario's Responder state-tool catalog is an exact production snapshot" do
    assert {:ok, scenarios} = WorldCase.all(@scenario_root)

    assert Enum.all?(scenarios, fn scenario ->
             WorldCase.state_tools(scenario) ==
               Tools.list(capabilities: [:event_waits, :publication, :schedules])
           end)
  end

  test "a scenario may reuse one bounded in-root captured tool catalog" do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "responder-world-catalog-#{System.unique_integer([:positive])}"
      )

    source = Path.join(@scenario_root, @health_scenario)
    scenario_dir = Path.join(fixture, @health_scenario)
    shared_catalog = Path.join(fixture, "shared-tool-catalog.json")
    File.mkdir_p!(scenario_dir)
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.cp!(Path.join(source, "scenario.json"), Path.join(scenario_dir, "scenario.json"))
    File.cp!(Path.join(source, "tool-catalog.json"), shared_catalog)

    File.write!(
      Path.join(scenario_dir, "tool-catalog.json"),
      Jason.encode!(%{"catalog_ref" => "../shared-tool-catalog.json", "version" => 1})
    )

    assert {:ok, [scenario]} = WorldCase.all(fixture)
    assert scenario.tool_catalog_digest =~ ~r/\A[0-9a-f]{64}\z/

    File.write!(
      Path.join(scenario_dir, "tool-catalog.json"),
      Jason.encode!(%{"catalog_ref" => "../../outside.json", "version" => 1})
    )

    assert {:error, {:invalid_world_case, @health_scenario, :tool_catalog_reference}} =
             WorldCase.all(fixture)
  end

  test "rejects path traversal and a catalog whose digest was edited" do
    fixture =
      Path.join(System.tmp_dir!(), "responder-world-case-#{System.unique_integer([:positive])}")

    case_id = "va1-health-review-repairs-and-finishes"
    scenario_dir = Path.join(fixture, case_id)
    File.mkdir_p!(scenario_dir)

    on_exit(fn -> File.rm_rf!(fixture) end)

    source = Path.join(@scenario_root, case_id)
    File.cp!(Path.join(source, "scenario.json"), Path.join(scenario_dir, "scenario.json"))
    File.cp!(Path.join(source, "tool-catalog.json"), Path.join(scenario_dir, "tool-catalog.json"))

    scenario_path = Path.join(scenario_dir, "scenario.json")
    scenario = scenario_path |> File.read!() |> Jason.decode!()

    scenario
    |> put_in(["world", "repositories"], [
      %{"path" => "../outside", "ref" => "fixture", "sha256" => String.duplicate("a", 64)}
    ])
    |> then(&File.write!(scenario_path, Jason.encode!(&1)))

    assert {:error, {:invalid_world_case, ^case_id, :repository_path}} = WorldCase.all(fixture)

    File.cp!(Path.join(source, "scenario.json"), scenario_path)
    File.write!(Path.join(scenario_dir, "tool-catalog.json"), "{}")

    assert {:error, {:invalid_world_case, ^case_id, :tool_catalog}} = WorldCase.all(fixture)
  end

  test "a declared repository is content-addressed and pinned to one Coop commit" do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "responder-world-repository-#{System.unique_integer([:positive])}"
      )

    case_id = "rivals-engineering-task-offer"
    source = Path.join(@scenario_root, case_id)
    scenario_dir = Path.join(fixture, case_id)
    repository_dir = Path.join(scenario_dir, "repository")
    File.mkdir_p!(repository_dir)
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.cp!(Path.join(source, "scenario.json"), Path.join(scenario_dir, "scenario.json"))
    File.cp!(Path.join(source, "tool-catalog.json"), Path.join(scenario_dir, "tool-catalog.json"))
    File.write!(Path.join(repository_dir, "gate.py"), "def timeout_window():\n    return 300\n")

    scenario_path = Path.join(scenario_dir, "scenario.json")

    scenario =
      scenario_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["world", "repositories"], [
        %{
          "base_commit" => "41af103a96d71c93887fe2b4dc9eed2d75f8fcb7",
          "path" => "repository",
          "ref" => "blitz-rivals-scraper",
          "sha256" => repository_digest(repository_dir)
        }
      ])

    File.write!(scenario_path, Jason.encode!(scenario))

    assert {:ok, [compiled]} = WorldCase.all(fixture)

    assert WorldCase.repository_requirements(compiled) == [
             %{
               "base_commit" => "41af103a96d71c93887fe2b4dc9eed2d75f8fcb7",
               "name" => "blitz-rivals-scraper"
             }
           ]

    File.write!(Path.join(repository_dir, "gate.py"), "def timeout_window():\n    return 600\n")

    assert {:error, {:invalid_world_case, ^case_id, :repository_digest}} =
             WorldCase.all(fixture)
  end

  test "rejects malformed scenario contracts at each authority boundary" do
    cases = [
      {fn scenario -> Map.put(scenario, "version", 2) end, :version},
      {fn scenario -> Map.put(scenario, "id", "different-case") end, :id},
      {fn scenario -> put_in(scenario, ["provenance", "kind"], "guess") end, :provenance},
      {fn scenario -> put_in(scenario, ["clock", "start"], "tomorrow") end, :clock},
      {fn scenario -> Map.put(scenario, "clock", %{}) end, :clock},
      {fn scenario -> Map.put(scenario, "actors", "operator") end, :actors},
      {fn scenario -> Map.put(scenario, "actors", ["operator"]) end, :actors},
      {fn scenario ->
         update_in(scenario, ["actors", Access.at(0)], &Map.delete(&1, "input_profile"))
       end, :actors},
      {fn scenario ->
         put_in(scenario, ["actors", Access.at(0), "input_profile", "actor", "ref"], "other")
       end, :actors},
      {fn scenario ->
         put_in(
           scenario,
           ["actors", Access.at(0), "input_profile", "source_capabilities", "react"],
           %{"emoji_names" => []}
         )
       end, :actors},
      {fn scenario -> put_in(scenario, ["actors", Access.at(0), "authority"], "root") end,
       :actors},
      {fn scenario ->
         duplicate = hd(scenario["actors"])
         Map.update!(scenario, "actors", &(&1 ++ [duplicate]))
       end, :actors},
      {fn scenario -> Map.put(scenario, "events", ["not-an-event"]) end, :object_list},
      {fn scenario ->
         update_in(scenario, ["events", Access.at(0)], &Map.delete(&1, "destination"))
       end, :events},
      {fn scenario -> put_in(scenario, ["world", "repositories"], %{}) end, :repositories},
      {fn scenario ->
         put_in(scenario, ["world", "scheduled_events"], [
           %{
             "actor_ref" => "system:system:event-wait-poll_fallback",
             "kind" => "source_event",
             "occurred_at" => "2026-08-15T15:30:00Z"
           }
         ])
       end, :scheduled_events},
      {fn scenario -> put_in(scenario, ["world", "tool_rules"], %{}) end, :tool_rules},
      {fn scenario ->
         put_in(
           scenario,
           ["world", "tool_rules", Access.at(0), "match", "environment"],
           %{"$one_of" => []}
         )
       end, :tool_rule_match},
      {fn scenario ->
         put_in(
           scenario,
           ["world", "tool_rules", Access.at(0), "responses"],
           [%{"kind" => "unknown"}]
         )
       end, :tool_response},
      {fn scenario -> Map.put(scenario, "host_replay", %{}) end, :fields},
      {fn scenario ->
         update_in(
           scenario,
           ["host_replay", "model_events", Access.at(0), "calls", Access.at(0)],
           &Map.delete(&1, "tool")
         )
       end, :fields},
      {fn scenario ->
         put_in(
           scenario,
           ["host_replay", "model_events", Access.at(0), "calls", Access.at(0), "kind"],
           "shell"
         )
       end, :model_call},
      {fn scenario ->
         put_in(
           scenario,
           ["host_replay", "model_events", Access.at(0), "candidates", Access.at(0)],
           %{"kind" => "final"}
         )
       end, :fields},
      {fn scenario ->
         put_in(
           scenario,
           ["host_replay", "model_events", Access.at(0), "preflight_candidate_index"],
           1
         )
       end, :preflight_candidate},
      {fn scenario ->
         put_in(
           scenario,
           ["host_replay", "model_events", Access.at(0), "input_index"],
           2
         )
       end, :input_index},
      {fn scenario -> Map.update!(scenario, "tags", &List.delete(&1, "host-replay")) end,
       :host_replay},
      {fn scenario -> put_in(scenario, ["expect", "hard"], "pass") end, :hard},
      {fn scenario -> Map.put(scenario, "tags", ["model-world", "model-world"]) end, :tags}
    ]

    Enum.each(cases, fn {mutate, expected_field} ->
      {fixture, case_id, scenario_path} = copy_scenario_fixture!()
      on_exit(fn -> File.rm_rf!(fixture) end)

      scenario = scenario_path |> File.read!() |> Jason.decode!() |> mutate.()
      File.write!(scenario_path, Jason.encode!(scenario))

      assert {:error, {:invalid_world_case, ^case_id, ^expected_field}} =
               WorldCase.all(fixture)
    end)
  end

  test "captured output artifacts are exact bounded image bytes" do
    source = Path.join(@scenario_root, "artifact-delivery-survives-work-handoff")

    for mutate <- [
          fn scenario ->
            put_in(
              scenario,
              [
                "host_replay",
                "model_events",
                Access.at(0),
                "output_artifacts",
                Access.at(0),
                "data_base64"
              ],
              "not-base64"
            )
          end,
          fn scenario ->
            put_in(
              scenario,
              [
                "host_replay",
                "model_events",
                Access.at(0),
                "output_artifacts",
                Access.at(0),
                "sha256"
              ],
              String.duplicate("0", 64)
            )
          end,
          fn scenario ->
            update_in(
              scenario,
              ["host_replay", "model_events", Access.at(0), "output_artifacts"],
              &(&1 ++ &1)
            )
          end
        ] do
      fixture =
        Path.join(
          System.tmp_dir!(),
          "responder-world-artifact-#{System.unique_integer([:positive])}"
        )

      destination = Path.join(fixture, "artifact-delivery-survives-work-handoff")
      File.mkdir_p!(destination)
      on_exit(fn -> File.rm_rf!(fixture) end)
      File.cp!(Path.join(source, "scenario.json"), Path.join(destination, "scenario.json"))

      health_catalog =
        Path.join(@scenario_root, "va1-health-review-repairs-and-finishes/tool-catalog.json")

      File.cp!(health_catalog, Path.join(destination, "tool-catalog.json"))

      scenario_path = Path.join(destination, "scenario.json")
      scenario = scenario_path |> File.read!() |> Jason.decode!() |> mutate.()
      File.write!(scenario_path, Jason.encode!(scenario))

      assert {:error,
              {:invalid_world_case, "artifact-delivery-survives-work-handoff", :output_artifacts}} =
               WorldCase.all(fixture)
    end
  end

  test "rejects missing, empty, and non-path scenario roots" do
    empty =
      Path.join(System.tmp_dir!(), "responder-empty-world-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert {:error, {:invalid_world_cases, :empty}} = WorldCase.all(empty)
    assert {:error, {:invalid_world_cases, :enoent}} = WorldCase.all(empty <> "-missing")
    assert {:error, {:invalid_world_cases, :root}} = WorldCase.all(nil)
    assert {:error, {:invalid_world_case, "unknown", :directory}} = WorldCase.load(nil)
    assert {:error, {:world_case_not_found, "missing"}} = WorldCase.fetch("missing")
    assert {:error, {:world_case_not_found, nil}} = WorldCase.fetch(nil)
  end

  test "rejects malformed, scalar, and oversized scenario documents at the file boundary" do
    fixture =
      Path.join(System.tmp_dir!(), "responder-world-json-#{System.unique_integer([:positive])}")

    scenario_dir = Path.join(fixture, "bounded-scenario")
    scenario_path = Path.join(scenario_dir, "scenario.json")
    File.mkdir_p!(scenario_dir)
    on_exit(fn -> File.rm_rf!(fixture) end)

    for {bytes, expected} <- [
          {"[]", :json_object},
          {"{", :json},
          {String.duplicate(" ", 512 * 1_024 + 1), :too_large}
        ] do
      File.write!(scenario_path, bytes)

      assert {:error, {:invalid_world_case, "bounded-scenario", ^expected}} =
               WorldCase.load(scenario_dir)
    end
  end

  test "fetch propagates an invalid scenario-root error" do
    empty =
      Path.join(System.tmp_dir!(), "responder-empty-fetch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert {:error, {:invalid_world_cases, :empty}} = WorldCase.fetch("missing", empty)
  end

  defp copy_scenario_fixture!(case_id \\ @health_scenario) do
    fixture =
      Path.join(System.tmp_dir!(), "responder-world-case-#{System.unique_integer([:positive])}")

    scenario_dir = Path.join(fixture, case_id)
    source = Path.join(@scenario_root, case_id)
    File.mkdir_p!(scenario_dir)
    File.cp!(Path.join(source, "scenario.json"), Path.join(scenario_dir, "scenario.json"))
    File.cp!(Path.join(source, "tool-catalog.json"), Path.join(scenario_dir, "tool-catalog.json"))

    {fixture, case_id, Path.join(scenario_dir, "scenario.json")}
  end

  defp repository_digest(directory) do
    entries =
      directory
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(fn name ->
        bytes = File.read!(Path.join(directory, name))

        %{
          "bytes" => byte_size(bytes),
          "path" => name,
          "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        }
      end)

    entries
    |> Responder.CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
