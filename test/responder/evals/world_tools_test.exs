defmodule Responder.Evals.WorldToolsTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.{WorldCase, WorldCassette, WorldTools}
  alias Responder.StateTools.{Router, Tools}

  test "the operator a scenario declares is the only actor who can save its answer" do
    # Found 2026-09-12 running the judge lane for `missing-project-answer-is-remembered`:
    # three of four criteria passed and the fourth failed on "remember_answer was denied
    # with answer_memory_unauthorized". The world evaluation configured no answer
    # authorizer at all, so `Memories.confirm_answer/4` refused every save and no
    # scenario could ever prove the durable half of a remembered answer, however well
    # the model behaved.
    assert {:ok, scenario} = WorldCase.fetch("missing-project-answer-is-remembered")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert {:ok, prepared} =
             WorldTools.prepare(
               %{capabilities: [:event_waits, :publication, :schedules]},
               scenario,
               cassette
             )

    authorize = prepared.state_tools.answer_authorizer
    assert is_function(authorize, 1)

    operator = %{
      source_kind: "slack",
      source_ref: "TEVAL",
      actor_kind: :user,
      actor_ref: "U-operator"
    }

    assert authorize.(operator)
    refute authorize.(%{operator | actor_ref: "U-bystander"})
    refute authorize.(%{operator | source_ref: "TOTHER"})
    refute authorize.(%{operator | source_kind: "control_plane"})
    refute authorize.(%{operator | actor_kind: :bot})
  end

  test "a world with no discovery provider exposes fixed tools without an orphan callback" do
    assert {:ok, scenario} = WorldCase.fetch("missing-project-review-asks-for-context")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert {:ok, prepared} =
             WorldTools.prepare(
               %{capabilities: [:event_waits, :publication, :schedules]},
               scenario,
               cassette
             )

    assert prepared.state_tools.additional_tools == []
    assert is_nil(prepared.state_tools.additional_call)

    assert Router.init([token: "no-discovery-world-secret"] ++ Map.to_list(prepared.state_tools))
  end

  test "the model world exposes production schemas with inert platform authority" do
    assert {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})
    parent = self()

    platform_tool = %{
      "description" => "A production-shaped action that must remain inert in evals.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{"message_ref" => %{"type" => "string"}},
        "required" => ["message_ref"],
        "type" => "object"
      },
      "name" => "set_slack_reaction"
    }

    configured = %{
      additional_call: fn _name, _arguments, _binding ->
        send(parent, :production_callback_called)
        {:ok, %{"mutated" => true}}
      end,
      additional_tools: [platform_tool],
      capabilities: [:event_waits, :publication, :schedules],
      token_secret: "eval-state-secret"
    }

    assert {:ok, prepared} = WorldTools.prepare(configured, scenario, cassette)

    expected_fixed = Tools.list(capabilities: configured.capabilities)
    names = Enum.map(prepared.catalog["servers"] |> hd() |> Map.fetch!("tools"), & &1["name"])

    assert Enum.all?(expected_fixed, &(&1["name"] in names))
    assert "set_slack_reaction" in names
    assert "monitoring.query" in names
    assert prepared.catalog_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert {:error, %{"code" => "model_world_external_tool_disabled"}} =
             prepared.state_tools.additional_call.(
               "set_slack_reaction",
               %{"message_ref" => "1710000000.000100"},
               %{turn: "inert"}
             )

    refute_receive :production_callback_called

    assert {:ok,
            %{
              "alerts" => [],
              "source_ref" => "source:va1:alerts:20260815T150001Z"
            }} =
             prepared.state_tools.additional_call.(
               "monitoring.query",
               %{"environment" => "va1", "query" => "firing_alerts"},
               %{turn: "inert"}
             )

    assert [platform_call, source_call] = WorldCassette.calls(cassette)
    assert platform_call.outcome == :inert
    assert platform_call.result == %{"error" => "model_world_external_tool_disabled"}
    assert source_call.outcome == :result

    assert source_call.result == %{
             "alerts" => [],
             "source_ref" => "source:va1:alerts:20260815T150001Z"
           }
  end

  test "configured and fabricated tool names may never collide" do
    assert {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})
    [fabricated | _rest] = WorldCase.fabricated_tools(scenario)

    configured = %{
      additional_call: fn _name, _arguments -> {:error, "disabled"} end,
      additional_tools: [fabricated],
      capabilities: [:event_waits, :publication, :schedules],
      token_secret: "eval-state-secret"
    }

    assert WorldTools.prepare(configured, scenario, cassette) ==
             {:error, :model_world_tool_name_conflict}
  end

  test "the model world refuses a configured state-tool surface that differs from the scenario" do
    assert {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert {:error,
            {:model_world_state_tool_catalog_mismatch,
             %{
               configured: configured,
               scenario: scenario_names
             }}} =
             WorldTools.prepare(
               %{
                 additional_tools: [],
                 capabilities: [:publication, :schedules],
                 token_secret: "eval-state-secret"
               },
               scenario,
               cassette
             )

    refute "wait_for" in configured
    assert "wait_for" in scenario_names
  end

  test "the world tool gateway fails closed for malformed catalogs and unknown calls" do
    assert {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    assert {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert WorldTools.prepare(%{}, scenario, cassette) ==
             {:error, :model_world_state_tools_not_configured}

    assert WorldTools.prepare(
             %{
               additional_tools: [%{"name" => "missing-schema"}],
               capabilities: [:event_waits, :publication, :schedules]
             },
             scenario,
             cassette
           ) == {:error, :model_world_tool_name_conflict}

    assert {:ok, prepared} =
             WorldTools.prepare(
               %{
                 additional_tools: [],
                 capabilities: [:event_waits, :publication, :schedules]
               },
               scenario,
               cassette
             )

    assert prepared.state_tools.additional_call.("unknown.tool", %{}, %{}) ==
             {:error, %{"code" => "unknown_model_world_tool"}}
  end
end
