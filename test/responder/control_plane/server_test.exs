defmodule Responder.ControlPlane.ServerTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.Server

  @profile %Responder.Ingress.WorkProfile{
    policy: "control-plane-read",
    policy_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    repository_ref: nil
  }
  @task_policies %{
    "responder" => %{
      digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      name: "responder-contributor"
    }
  }

  test "builds an explicit loopback-only Bandit listener" do
    options =
      Server.options!(port: 4_090, task_policies: @task_policies, work_profile: @profile)

    assert options.ip == {127, 0, 0, 1}
    assert options.port == 4_090
    assert options.coop_api == nil
    assert options.coop_client == nil
    assert options.task_policies == @task_policies
    assert byte_size(options.csrf_secret) == 32

    assert %{id: Server, start: {Bandit, :start_link, [_options]}} =
             Server.child_spec(
               port: 4_090,
               task_policies: @task_policies,
               work_profile: @profile
             )
  end

  test "refuses public, ambiguous, or malformed listener configuration" do
    assert_raise ArgumentError, fn -> Server.options!(port: 0, work_profile: @profile) end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, ip: {0, 0, 0, 0}, work_profile: @profile)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, ip: {0, 0, 0, 0, 0, 0, 0, 0}, work_profile: @profile)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, work_profile: @profile, unknown: true)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, port: 4_091, work_profile: @profile)
    end

    assert_raise ArgumentError, fn -> Server.options!(port: 4_090) end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, coop_api: Responder.Coop.Client, work_profile: @profile)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(
        port: 4_090,
        task_policies: %{"responder" => %{name: "browser-choice"}},
        work_profile: @profile
      )
    end
  end
end
