defmodule Ryker.Evals.WorldCassetteTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.{WorldCase, WorldCassette}

  setup do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    {:ok, cassette} =
      start_supervised(%{
        id: {:alias_cassette, make_ref()},
        start: {WorldCassette, :start_link, [scenario]}
      })

    %{cassette: cassette}
  end

  test "specific metric observations remain reachable before the empty-series fallback" do
    # Two full-world observations lost alert inventory and resource evidence:
    # their valid queries reached the alphabetically earlier catch-all instead.
    {:ok, scenario} = WorldCase.fetch("deep-check-finds-its-sources-through-search")
    {:ok, cassette} = start_supervised({WorldCassette, scenario})

    queries = [
      {"sum by (folder) (grafana_alerting_rule_group_rules)",
       %{"rules_scheduled" => 148, "evaluation_failures_last_hour" => 0}},
      {"1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
       %{"max_memory_percent" => 66, "oom_kills_24h" => 0}},
      {"sum by (service) (rate(http_requests_total{status=~\"5..\"}[1h])) / sum by (service) (rate(http_requests_total[1h]))",
       %{
         "services" => [
           %{"service" => "arena", "error_ratio" => 0.945},
           %{"service" => "website", "error_ratio" => 1.0e-7}
         ]
       }}
    ]

    Enum.each(queries, fn {query, expected} ->
      assert {:ok, %{"runs" => [%{"structured_output" => result}]}} =
               WorldCassette.call(cassette, "run_action", %{
                 "action_id" => "vm.query_instant",
                 "args" => %{"query" => query}
               })

      assert Map.take(result, Map.keys(expected)) == expected
    end)
  end

  # Audit F01, 2026-10-12: the world answered run_action with the bare output,
  # where Emisar answers with the operation and each run's link, so a turn that
  # read all 148 alert rules had nothing to cite.
  test "an Emisar action answers with its operation and each run's link, as Emisar does" do
    {:ok, scenario} = WorldCase.fetch("deep-check-finds-its-sources-through-search")
    {:ok, cassette} = start_supervised({WorldCassette, scenario})

    arguments = %{
      "action_id" => "vm.query_instant",
      "args" => %{"query" => "sum by (folder) (grafana_alerting_rule_group_rules)"}
    }

    assert {:ok, first} = WorldCassette.call(cassette, "run_action", arguments)
    assert {:ok, second} = WorldCassette.call(cassette, "run_action", arguments)

    assert %{
             "action_id" => "vm.query_instant",
             "ok" => true,
             "operation_id" => "op_" <> _operation,
             "runs" => [
               %{
                 "run_url" => "https://emisar.example/app/world/runs/run_" <> _run,
                 "status" => "succeeded",
                 "structured_output" => %{"rules_scheduled" => 148}
               }
             ]
           } = first

    # Each call is its own operation, and a rerun of the case names the same ones.
    refute first["operation_id"] == second["operation_id"]
    assert [%{result: recorded} | _rest] = WorldCassette.calls(cassette)
    assert recorded["operation_id"] == first["operation_id"]
  end

  test "matches an explicitly reviewed set of normalized argument aliases" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    scenario =
      update_in(scenario.world["tool_rules"], fn rules ->
        Enum.map(rules, fn
          %{"id" => "grafana-firing-alerts"} = rule ->
            put_in(rule["match"], %{
              "environment" => %{"$one_of" => ["va1", "production"]},
              "query" => %{"$one_of" => ["firing_alerts", "active_alerts"]}
            })

          rule ->
            rule
        end)
      end)

    {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert {:ok,
            %{
              "alerts" => [],
              "source_ref" => "source:va1:alerts:20260815T150001Z"
            }} =
             WorldCassette.call(cassette, "monitoring.query", %{
               "environment" => "production",
               "query" => "active_alerts"
             })

    assert {:error, %{"code" => "unmatched_fabricated_tool_call"}} =
             WorldCassette.call(cassette, "monitoring.query", %{
               "environment" => "staging",
               "query" => "active_alerts"
             })
  end

  test "production-shaped free-form source queries match reviewed concepts" do
    {:ok, airflow} = WorldCase.fetch("airflow-verification-arms-wait")
    {:ok, checkout} = WorldCase.fetch("application-errors-follow-the-current-signal")
    {:ok, grafana} = WorldCase.fetch("grafana-firing-resolved-stays-in-cycle")
    {:ok, uptime} = WorldCase.fetch("current-uptime-check-uses-fresh-source")
    {:ok, va1} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    {:ok, airflow_cassette} =
      start_supervised(%{
        id: {:natural_query_cassette, :airflow},
        start: {WorldCassette, :start_link, [airflow]}
      })

    {:ok, checkout_cassette} =
      start_supervised(%{
        id: {:natural_query_cassette, :checkout},
        start: {WorldCassette, :start_link, [checkout]}
      })

    {:ok, grafana_cassette} =
      start_supervised(%{
        id: {:natural_query_cassette, :grafana},
        start: {WorldCassette, :start_link, [grafana]}
      })

    {:ok, uptime_cassette} =
      start_supervised(%{
        id: {:natural_query_cassette, :uptime},
        start: {WorldCassette, :start_link, [uptime]}
      })

    {:ok, va1_cassette} =
      start_supervised(%{
        id: {:natural_query_cassette, :va1},
        start: {WorldCassette, :start_link, [va1]}
      })

    assert {:ok, %{"status" => "insufficient_history"}} =
             WorldCassette.call(airflow_cassette, "monitoring.query", %{
               "environment" => "production",
               "query" =>
                 "Airflow revision 756bb648 health, errors, and availability during the bounded window"
             })

    assert {:ok,
            %{
              "current_error_rate" => 0.0011,
              "source_ref" => "source:checkout-errors:20260830T143000Z"
            }} =
             WorldCassette.call(checkout_cassette, "monitoring.query", %{
               "environment" => "production",
               "query" => "checkout error rate over the last 15 minutes compared with baseline"
             })

    arguments = %{
      "environment" => "production",
      "query" => "load balancer 5xx ratio for alert rule-2"
    }

    assert {:ok,
            %{
              "source_ref" => "source:grafana:rule-2:cycle-1:firing",
              "state" => "firing"
            }} =
             WorldCassette.call(grafana_cassette, "monitoring.query", arguments)

    assert {:ok,
            %{
              "source_ref" => "source:grafana:rule-2:cycle-1:resolved",
              "state" => "resolved"
            }} =
             WorldCassette.call(grafana_cassette, "monitoring.query", arguments)

    assert {:ok, %{"uptime_seconds" => 734_400}} =
             WorldCassette.call(uptime_cassette, "monitoring.query", %{
               "query" => "What is the current uptime for nomad-hst03 in production?"
             })

    assert {:ok, %{"alerts" => []}} =
             WorldCassette.call(va1_cassette, "monitoring.query", %{
               "environment" => "VA1",
               "query" => "current active alerts and firing alerts"
             })

    assert {:ok, %{"dependencies" => dependencies}} =
             WorldCassette.call(va1_cassette, "monitoring.query", %{
               "environment" => "VA1",
               "query" => "dependency health status"
             })

    assert Enum.all?(dependencies, &(&1["status"] == "healthy"))

    assert {:ok, %{"checks" => [%{"status" => "passing"}]}} =
             WorldCassette.call(va1_cassette, "monitoring.query", %{
               "environment" => "VA1",
               "query" => "representative functional checks and synthetic probes"
             })
  end

  test "matches important arguments without requiring one global call order", %{
    cassette: cassette
  } do
    assert {:ok,
            %{
              "alerts" => [],
              "source_ref" => "source:va1:alerts:20260815T150001Z"
            }} =
             WorldCassette.call(cassette, "monitoring.query", %{
               "environment" => "va1",
               "query" => "firing_alerts",
               "unimportant_client_field" => true
             })

    assert {:ok, %{"deployments" => [%{"status" => "successful"}]}} =
             WorldCassette.call(cassette, "nomad.deployments", %{"environment" => "va1"})

    assert Enum.map(WorldCassette.calls(cassette), & &1.tool) == [
             "monitoring.query",
             "nomad.deployments"
           ]

    assert Enum.map(WorldCassette.calls(cassette), & &1.result) == [
             %{
               "alerts" => [],
               "source_ref" => "source:va1:alerts:20260815T150001Z"
             },
             %{
               "deployments" => [%{"status" => "successful"}],
               "source_ref" => "source:va1:deployments:20260815T150001Z"
             }
           ]
  end

  test "plays a rule's controlled failure sequence and never invents unmatched data", %{
    cassette: cassette
  } do
    arguments = %{"environment" => "va1", "service" => "realtime-gateway"}

    assert {:error, %{"code" => "timeout", "message" => "recorded source timeout"}} =
             WorldCassette.call(cassette, "nomad.service_health", arguments)

    assert {:ok, %{"allocations" => [%{"desired" => "run", "status" => "running"}]}} =
             WorldCassette.call(cassette, "nomad.service_health", arguments)

    assert {:error, %{"code" => "rule_exhausted"}} =
             WorldCassette.call(cassette, "nomad.service_health", arguments)

    assert {:error, %{"code" => "unmatched_fabricated_tool_call"}} =
             WorldCassette.call(cassette, "nomad.service_health", %{
               "environment" => "production",
               "service" => "unknown"
             })

    assert Enum.all?(WorldCassette.calls(cassette), &is_binary(&1.arguments_sha256))

    assert Enum.map(WorldCassette.calls(cassette), & &1.result) == [
             %{"error" => %{"code" => "timeout", "message" => "recorded source timeout"}},
             %{
               "allocations" => [%{"desired" => "run", "status" => "running"}],
               "source_ref" => "source:va1:realtime-gateway:20260815T150001Z"
             },
             %{"error" => %{"code" => "rule_exhausted"}},
             %{"error" => %{"code" => "unmatched_fabricated_tool_call"}}
           ]
  end
end
