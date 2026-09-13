defmodule Ryker.ControlPlane.ServerTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.Server

  @profile %Ryker.Ingress.WorkProfile{
    policy: "control-plane-read",
    policy_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    repository_ref: nil
  }
  @task_policies %{
    "ryker" => %{
      digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      name: "ryker-contributor"
    }
  }

  test "builds an explicit loopback-only Phoenix listener on Bandit" do
    options =
      Server.options!(port: 4_090, task_policies: @task_policies, work_profile: @profile)

    assert options.ip == {127, 0, 0, 1}
    assert options.port == 4_090
    assert options.coop_api == nil
    assert options.coop_client == nil
    assert options.task_policies == @task_policies
    assert byte_size(options.csrf_secret) == 32

    assert %{
             id: Server,
             start: {Ryker.ControlPlane.Endpoint, :start_link, [endpoint_options]}
           } =
             Server.child_spec(
               port: 4_090,
               task_policies: @task_policies,
               work_profile: @profile
             )

    assert endpoint_options[:http] == [ip: {127, 0, 0, 1}, port: 4_090]
    assert "//localhost:4090" in endpoint_options[:check_origin]
    refute endpoint_options[:check_origin] == false
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

    # A fresh installation has no reviewed policy yet; the console still starts
    # so setup is reachable, and simply has no profile to submit Work with.
    assert Server.options!(port: 4_090).work_profile == nil

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, work_profile: %{policy: "browser-choice"})
    end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, coop_api: Ryker.Coop.Client, work_profile: @profile)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(
        port: 4_090,
        task_policies: %{"ryker" => %{name: "browser-choice"}},
        work_profile: @profile
      )
    end
  end
end
