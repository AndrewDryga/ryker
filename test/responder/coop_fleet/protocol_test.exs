defmodule Responder.CoopFleet.ProtocolTest do
  use ExUnit.Case, async: true

  alias Responder.CoopFleet.Protocol

  @fixture Path.expand("../../../testdata/protocol/coop-worker-v1.json", __DIR__)

  test "the versioned worker golden accepts bounded commands and ordered event replay" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert {:ok, poll} = Protocol.poll(fixture["poll"])
    assert poll["worker"]["id"] == "worker-a"
    assert Enum.map(hd(poll["event_batches"])["events"], & &1["sequence"]) == [1, 2]

    assert {:ok, response} = Protocol.response(fixture["response"])
    assert [command] = response["commands"]
    assert command["kind"] == "submit_turn"
    assert command["payload"]["submission"]["prompt"] == "Continue the selected episode."
    assert response["acknowledged_result_command_ids"] == ["command:create:1"]

    assert {:ok, encoded} = Protocol.encode_response(response)
    assert Jason.decode!(encoded) == response
    assert Protocol.version() == 1
  end

  test "unknown versions fields command kinds and sequence gaps fail before mutation" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    poll = fixture["poll"]
    response = fixture["response"]

    assert Protocol.poll(%{poll | "version" => 2}) ==
             {:error, {:unsupported_coop_worker_protocol, :version}}

    assert {:error, {:invalid_coop_worker_poll, :poll}} =
             Protocol.poll(Map.put(poll, "provider_credentials", ["must-not-cross"]))

    [batch] = poll["event_batches"]
    [first, second] = batch["events"]
    gapped = %{batch | "events" => [first, %{second | "sequence" => 3}]}

    assert Protocol.poll(%{poll | "event_batches" => [gapped]}) ==
             {:error, {:invalid_coop_worker_poll, :event_sequence}}

    [command] = response["commands"]

    assert Protocol.response(%{response | "commands" => [%{command | "kind" => "shell"}]}) ==
             {:error, {:invalid_coop_worker_protocol, :command_kind}}
  end

  test "wire documents are bounded and result shapes cannot claim success without a resource" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    poll = fixture["poll"]
    [result] = poll["command_results"]

    assert Protocol.decode_poll(String.duplicate("x", 1_048_577)) ==
             {:error, {:invalid_coop_worker_poll, :document}}

    invalid = %{result | "resource" => nil}

    assert Protocol.poll(%{poll | "command_results" => [invalid]}) ==
             {:error, {:invalid_coop_worker_poll, :command_result_shape}}
  end

  test "response bounds and worker authority advertisements are unambiguous" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    poll = fixture["poll"]
    response = fixture["response"]

    assert Protocol.response(%{response | "commands" => List.duplicate(%{}, 101)}) ==
             {:error, {:invalid_coop_worker_response, :commands}}

    repository = hd(poll["worker"]["repositories"])
    duplicate_repositories = put_in(poll, ["worker", "repositories"], [repository, repository])

    assert Protocol.poll(duplicate_repositories) ==
             {:error, {:invalid_coop_worker_poll, :repositories}}

    capability = hd(poll["worker"]["capabilities"])
    duplicate_capabilities = put_in(poll, ["worker", "capabilities"], [capability, capability])

    assert Protocol.poll(duplicate_capabilities) ==
             {:error, {:invalid_coop_worker_poll, :capabilities}}

    invalid_digest = put_in(poll, ["worker", "sandbox_digest"], String.duplicate("A", 64))

    assert Protocol.poll(invalid_digest) ==
             {:error, {:invalid_coop_worker_protocol, :sandbox_digest}}
  end

  test "a real Coop-sized frozen prompt fits while an oversized command does not" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    response = fixture["response"]
    [command] = response["commands"]

    prompt = String.duplicate("p", 200 * 1_024)
    large = put_in(command, ["payload", "submission", "prompt"], prompt)
    assert {:ok, _response} = Protocol.response(%{response | "commands" => [large]})

    oversized =
      put_in(command, ["payload", "submission", "prompt"], String.duplicate("p", 769 * 1_024))

    assert Protocol.response(%{response | "commands" => [oversized]}) ==
             {:error, {:invalid_coop_worker_protocol, :command_payload}}
  end

  test "only named semantic validation and operation fence mutations cross the wire" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    response = fixture["response"]
    [command] = response["commands"]

    for kind <- ~w(get_session get_turn validate_candidate fence_operation) do
      assert {:ok, _response} =
               Protocol.response(%{response | "commands" => [%{command | "kind" => kind}]})
    end
  end

  test "worker capacity identity and event fields fail closed independently" do
    poll = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("poll")

    invalid_polls = [
      {put_in(poll, ["worker", "capacity", "session_slots_free"], -1), :session_slots},
      {put_in(poll, ["worker", "capacity", "turn_slots_free"], 99), :turn_slots},
      {put_in(poll, ["worker", "capacity", "workspace_slots_total"], 10_001), :workspace_slots},
      {put_in(poll, ["worker", "capacity", "state"], "cooldown"), :cooldown_until},
      {put_in(poll, ["worker", "state"], "offline"), :worker_state},
      {put_in(poll, ["worker", "clock_at"], "now"), :clock_at},
      {put_in(poll, ["worker", "repositories", Access.at(0), "revision"], "bad revision"),
       :repository_revision},
      {put_in(poll, ["worker", "capabilities", Access.at(0), "version"], nil),
       :capability_version},
      {put_in(poll, ["event_batches", Access.at(0), "placement_generation"], 0),
       :placement_generation},
      {put_in(poll, ["event_batches", Access.at(0), "after_sequence"], -1), :after_sequence},
      {put_in(poll, ["event_batches", Access.at(0), "events", Access.at(0), "kind"], "tool"),
       :event_kind}
    ]

    Enum.each(invalid_polls, fn {invalid, field} ->
      assert {:error, {:invalid_coop_worker_protocol, ^field}} = Protocol.poll(invalid)
    end)

    assert {:error, {:invalid_coop_worker_poll, :policy_digests}} =
             Protocol.poll(put_in(poll, ["worker", "policy_digests"], []))

    cooldown =
      poll
      |> put_in(["worker", "capacity", "state"], "cooldown")
      |> put_in(["worker", "capacity", "cooldown_until"], "2026-08-29T12:00:00Z")

    assert {:ok, prepared} = Protocol.poll(cooldown)
    assert prepared["worker"]["capacity"]["state"] == "cooldown"
  end

  test "command responses reject malformed leases acknowledgements and payloads" do
    response = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("response")
    [command] = response["commands"]
    [ack] = response["event_acknowledgements"]

    invalid_responses = [
      {Map.put(response, "server_time", "later"), :server_time},
      {put_in(response, ["commands", Access.at(0), "placement_generation"], 0),
       :placement_generation},
      {put_in(response, ["commands", Access.at(0), "lease_expires_at"], nil), :lease_expires_at},
      {put_in(response, ["commands", Access.at(0), "payload"], "not-an-object"),
       :command_payload},
      {put_in(response, ["commands", Access.at(0), "idempotency_key"], "bad key"),
       :idempotency_key},
      {%{response | "event_acknowledgements" => [%{ack | "sequence" => -1}]}, :event_sequence}
    ]

    Enum.each(invalid_responses, fn {invalid, field} ->
      assert {:error, {:invalid_coop_worker_protocol, ^field}} = Protocol.response(invalid)
    end)

    assert {:error, {:invalid_coop_worker_response, :acknowledged_result_command_ids}} =
             Protocol.response(
               Map.put(response, "acknowledged_result_command_ids", ["same", "same"])
             )

    assert {:error, {:invalid_coop_worker_response, :document}} = Protocol.response([])
    assert {:error, {:invalid_coop_worker_poll, :document}} = Protocol.poll([])
    assert {:error, {:invalid_coop_worker_poll, :json}} = Protocol.decode_poll("{")

    assert {:ok, _} =
             Protocol.response(%{
               response
               | "commands" => [command],
                 "event_acknowledgements" => []
             })
  end

  test "nested worker protocol collections reject non-object members without crashing" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    poll = fixture["poll"]
    response = fixture["response"]

    invalid_polls = [
      {Map.put(poll, "worker", []), :worker},
      {put_in(poll, ["worker", "capacity"], []), :capacity},
      {put_in(poll, ["worker", "repositories"], [nil]), :repository},
      {put_in(poll, ["worker", "capabilities"], [nil]), :capability},
      {Map.put(poll, "command_results", [nil]), :command_result},
      {Map.put(poll, "event_batches", [nil]), :event_batch},
      {put_in(poll, ["event_batches", Access.at(0), "events"], [nil]), :event}
    ]

    Enum.each(invalid_polls, fn {invalid, field} ->
      assert {:error, {:invalid_coop_worker_poll, ^field}} = Protocol.poll(invalid)
    end)

    assert {:error, {:invalid_coop_worker_response, :command}} =
             Protocol.response(Map.put(response, "commands", [nil]))

    assert {:error, {:invalid_coop_worker_response, :event_acknowledgement}} =
             Protocol.response(Map.put(response, "event_acknowledgements", [nil]))

    empty_events = put_in(poll, ["event_batches", Access.at(0), "events"], [])
    assert {:ok, _} = Protocol.poll(empty_events)

    invalid_cooldown =
      put_in(poll, ["worker", "capacity", "cooldown_until"], "2026-08-29T12:00:00Z")

    assert {:error, {:invalid_coop_worker_protocol, :cooldown_until}} =
             Protocol.poll(invalid_cooldown)

    [result] = poll["command_results"]

    failed =
      result
      |> Map.put("state", "failed")
      |> Map.put("resource", nil)
      |> Map.put("error", %{"code" => "worker_failed"})

    assert {:ok, _} = Protocol.poll(Map.put(poll, "command_results", [failed]))

    unserializable =
      put_in(poll, ["event_batches", Access.at(0), "events", Access.at(0), "payload"], %{
        "pid" => self()
      })

    assert {:error, {:invalid_coop_worker_protocol, :event_payload}} =
             Protocol.poll(unserializable)
  end
end
