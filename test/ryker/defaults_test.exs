defmodule Ryker.DefaultsTest do
  use ExUnit.Case, async: true

  alias Ryker.Defaults

  test "every owner keeps the exact operational value its YAML loader validated" do
    # An installation that never set these fields must not silently change
    # behavior at the cutover, so the preserved values are asserted literally
    # rather than compared against the code that produces them.
    assert Defaults.fetch!(:admission) == %{
             concurrency: 4,
             decision_timeout_ms: 30_000,
             poll_interval_ms: 250
           }

    assert Defaults.fetch!(:work) == %{
             capability_names: ["responder-state"],
             concurrency: 4,
             poll_interval_ms: 250
           }

    assert Defaults.fetch!(:coop) == %{receive_timeout_ms: 30_000}
    assert Defaults.fetch!(:event_waits) == %{poll_interval_ms: 1_000}
    assert Defaults.fetch!(:coop_worker_gateway) == %{certificate_ttl_seconds: 86_400}
    assert Defaults.fetch!(:webhooks) == %{max_body_bytes: 40_000, max_clock_skew_seconds: 300}
    assert Defaults.fetch!(:retention).poll_interval_ms == 60_000
    assert Defaults.fetch!(:retention).lease_seconds == 300
    assert Defaults.fetch!(:retention).disposable_bytes_limit == 10_737_418_240
    assert Defaults.fetch!(:delivery).max_attempts == 8
    assert Defaults.fetch!(:publication).followup_interval_seconds == 120
    assert Defaults.fetch!(:emisar).poll_seconds == 3
    assert Defaults.fetch!(:schedules).misfire_grace_seconds == 900
    assert Defaults.fetch!(:learning).batch_size == 16
    assert Defaults.fetch!(:slack).maximum_open_incidents == 25
    assert Defaults.fetch!(:github).max_body_bytes == 40_000
  end

  test "retention horizons are never an operational default" do
    # History, memory and audit durations are product settings owned by
    # PostgreSQL; shipping them here would recreate a second writer.
    horizons =
      ~w(operational_data_seconds conversation_memory_seconds closed_work_seconds episode_history_seconds audit_data_seconds)a

    for owner <- Defaults.owners(), horizon <- horizons do
      refute Map.has_key?(Defaults.fetch!(owner), horizon)
    end

    for owner <- Defaults.owners(),
        product <- ~w(operators watch_channels default_repository policy policy_digest enabled)a do
      refute Map.has_key?(Defaults.fetch!(owner), product)
    end
  end

  test "defaults that must agree cannot drift apart" do
    assert Defaults.validate!() == :ok
  end

  test "merging supplies runtime bindings without losing an unset default" do
    merged = Defaults.merge(:work, %{api: Ryker.CoopFleet.Client, concurrency: 2})

    assert merged.concurrency == 2
    assert merged.poll_interval_ms == 250
    assert merged.api == Ryker.CoopFleet.Client

    assert_raise ArgumentError, ~r/no operational defaults own :nonsense/, fn ->
      Defaults.fetch!(:nonsense)
    end
  end

  test "the build chooses the execution topology, and tests are isolated from the fleet" do
    assert Defaults.execution() == :direct
    assert Application.get_env(:ryker, :execution) == :direct
  end
end
