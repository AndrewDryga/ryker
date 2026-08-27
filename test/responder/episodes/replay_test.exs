defmodule Responder.Episodes.ReplayTest do
  use ExUnit.Case, async: true

  alias Responder.Episodes.Replay

  @source %{
    "database" => "blitz responder.db",
    "episode_ids" => ["episode_run_2ad8185d881fe0b6dc6cd30969331a9c"],
    "reason" => "Parser regression derived from the harvested Grafana lifecycle episode."
  }

  @fixture_paths Path.wildcard(Path.join(__DIR__, "fixtures/*.json"))
                 |> Enum.reject(&String.ends_with?(&1, ".golden.json"))
  if @fixture_paths == [], do: raise("episode replay fixtures are missing")

  for fixture_path <- @fixture_paths do
    @fixture_path fixture_path
    @golden_path Path.rootname(fixture_path) <> ".golden.json"

    test "replays #{Path.basename(fixture_path, ".json")}" do
      fixture = Replay.read!(@fixture_path)
      first = Replay.run!(fixture)
      second = Replay.run!(fixture)

      assert Replay.view(first) == fixture["expected"]
      assert Replay.encode_result!(first) == Replay.encode_result!(second)
      assert Replay.encode_golden!(first) == File.read!(@golden_path)
    end
  end

  test "rejects an unknown command instead of silently dropping it" do
    fixture = %{
      "schema_version" => 1,
      "source" => @source,
      "commands" => [%{"type" => "progress_tick"}],
      "expected" => %{}
    }

    assert_raise ArgumentError, ~r/unknown episode command "progress_tick"/, fn ->
      Replay.run!(fixture)
    end
  end

  test "rejects duplicate JSON fields before they become a map" do
    json = ~s({"schema_version":1,"schema_version":1,"commands":[],"expected":{}})

    assert_raise ArgumentError, ~r/duplicate JSON field "schema_version" at \$/, fn ->
      Replay.decode!(json)
    end
  end

  test "rejects unknown command fields instead of making fixtures accidentally inert" do
    fixture = %{
      "schema_version" => 1,
      "source" => @source,
      "commands" => [
        %{
          "type" => "confirm_delivery",
          "episode_key" => "episode-1",
          "expected_delivery_ref" => "delivery-1",
          "occurred_at" => "2026-08-27T12:00:00Z",
          "ignored" => true
        }
      ],
      "expected" => %{}
    }

    assert_raise ArgumentError, ~r/unknown fields: \["ignored"\]/, fn ->
      Replay.run!(fixture)
    end
  end

  test "rejects unknown nested routing fields" do
    fixture = %{
      "schema_version" => 1,
      "source" => @source,
      "commands" => [
        %{
          "type" => "admit_input",
          "actor_ref" => "slack:user:U1",
          "destination" => %{
            "transport" => "slack",
            "conversation_ref" => "C1",
            "thread_ref" => "1.1",
            "fallback_channel" => "C2"
          },
          "episode_id" => "01993d45-d400-7000-8000-000000000001",
          "episode_key" => "slack:C1:1.1",
          "native_input_id" => "Ev1",
          "occurred_at" => "2026-08-27T12:00:00Z",
          "payload" => %{},
          "revision" => 1,
          "turn_ref" => "turn-1"
        }
      ],
      "expected" => %{}
    }

    assert_raise ArgumentError, ~r/unknown fields: \["fallback_channel"\]/, fn ->
      Replay.run!(fixture)
    end
  end

  test "requires concrete corpus provenance for every promoted fixture" do
    fixture =
      Path.join(__DIR__, "fixtures/grafana_firing_resolved_cycle.json")
      |> Replay.read!()

    assert_raise ArgumentError, ~r/missing fields: \["source"\]/, fn ->
      fixture |> Map.delete("source") |> Replay.run!()
    end

    assert_raise ArgumentError, ~r/source must include at least one stable identity/, fn ->
      fixture
      |> Map.put("source", %{
        "database" => "blitz responder.db",
        "reason" => "This deliberately lacks a source identity."
      })
      |> Replay.run!()
    end
  end

  test "rejects unknown nested owner and wait fields" do
    terraform =
      Path.join(__DIR__, "fixtures/terraform_retry_to_final.json")
      |> Replay.read!()
      |> update_in(["commands", Access.at(1), "expected_owner"], &Map.put(&1, "lease", 2))

    assert_raise ArgumentError, ~r/unknown fields: \["lease"\]/, fn ->
      Replay.run!(terraform)
    end

    airflow =
      Path.join(__DIR__, "fixtures/airflow_scheduled_verification.json")
      |> Replay.read!()
      |> update_in(["commands", Access.at(3), "expected_wait"], &Map.put(&1, "source", "timer"))

    assert_raise ArgumentError, ~r/unknown fields: \["source"\]/, fn ->
      Replay.run!(airflow)
    end
  end

  test "goldens detect routing, deadline, and event-payload corruption" do
    fixture_path = Path.join(__DIR__, "fixtures/pending_wait_survives_restart.json")
    fixture = Replay.read!(fixture_path)
    result = Replay.run!(fixture)
    golden = File.read!(Path.rootname(fixture_path) <> ".golden.json")

    widened = %{result | episode: %{result.episode | destination_thread_ref: nil}}

    wrong_deadline = %{
      result
      | episode: %{
          result.episode
          | owner_deadline_at: DateTime.add(result.episode.owner_deadline_at, 1, :second)
        }
    }

    [first | rest] = result.events
    corrupted = %{result | events: [%{first | payload: %{"corrupted" => true}} | rest]}

    refute Replay.encode_golden!(widened) == golden
    refute Replay.encode_golden!(wrong_deadline) == golden
    refute Replay.encode_golden!(corrupted) == golden
  end

  test "linked history exists but never supplies the current destination" do
    for name <- ["grafana_new_cycle_links_history_only", "linked_incident_keeps_own_thread"] do
      result =
        Path.join(__DIR__, "fixtures/#{name}.json")
        |> Replay.read!()
        |> Replay.run!()

      assert [history] = result.linked_results
      assert result.episode.linked_episode_id == history.episode.id
      assert history.episode.state == :complete

      refute {result.episode.destination_conversation_ref, result.episode.destination_thread_ref} ==
               {history.episode.destination_conversation_ref,
                history.episode.destination_thread_ref}
    end
  end
end
