defmodule Ryker.ControlPlane.ServerTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]

  alias Ryker.ControlPlane.Server
  alias Ryker.Ingress.WorkProfile

  @outside %{
    policy: "control-plane-read",
    policy_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    repository_ref: nil
  }
  @repositories ["ryker", "docs"]

  test "builds an explicit loopback-only Phoenix listener on Bandit" do
    options = Server.options!(configuration())

    assert options.ip == {127, 0, 0, 1}
    assert options.port == 4_090
    assert options.coop_api == nil
    assert options.coop_client == nil
    assert options.task_policies == task_policies()
    assert byte_size(options.csrf_secret) == 32

    assert %{
             id: Server,
             start: {Ryker.ControlPlane.Endpoint, :start_link, [endpoint_options]}
           } = Server.child_spec(configuration())

    assert endpoint_options[:http] == [ip: {127, 0, 0, 1}, port: 4_090]
    assert "//localhost:4090" in endpoint_options[:check_origin]
    refute endpoint_options[:check_origin] == false
  end

  # Each Chat conversation picks its environment, so the console keeps the
  # Work profile of every environment that can run work, and the profile of
  # work outside any for a conversation that chose none or whose environment
  # cannot run work right now. It used to keep one profile, the default
  # environment's, which every conversation ran in whatever it had chosen.
  test "Chat keeps each environment's Work profile and the one outside any" do
    chat = Server.options!(configuration()).chat

    assert %WorkProfile{environment_ref: "platform", repositories: @repositories} =
             chat.environments["platform"]

    assert %WorkProfile{environment_ref: nil, repositories: []} = chat.fallback_work_profile

    # A fresh installation has no reviewed policy yet; the console still starts
    # so setup is reachable, and simply has nothing to submit Work with.
    assert Server.options!(port: 4_090).chat == %{environments: %{}, fallback_work_profile: nil}

    # A profile placed in another environment is not this one's.
    for invalid <- [
          put_in(
            configuration(),
            [:environments, "platform", :work_profile, :environment_ref],
            "ops"
          ),
          put_in(configuration(), [:environments, "platform"], %{work_profile: @outside}),
          %{configuration() | fallback_work_profile: %{policy: "browser-choice"}}
        ] do
      assert_raise ArgumentError, fn -> Server.options!(invalid) end
    end
  end

  test "refuses public, ambiguous, or malformed listener configuration" do
    assert_raise ArgumentError, fn -> Server.options!(%{configuration() | port: 0}) end

    assert_raise ArgumentError, fn ->
      Server.options!(Map.put(configuration(), :ip, {0, 0, 0, 0}))
    end

    assert_raise ArgumentError, fn ->
      Server.options!(Map.put(configuration(), :ip, {0, 0, 0, 0, 0, 0, 0, 0}))
    end

    assert_raise ArgumentError, fn ->
      Server.options!(Map.put(configuration(), :unknown, true))
    end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_090, port: 4_091, fallback_work_profile: @outside)
    end

    assert_raise ArgumentError, fn ->
      Server.options!(Map.put(configuration(), :coop_api, Ryker.CoopFleet.Client))
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{configuration() | task_policies: %{"ryker" => %{name: "browser-choice"}}})
    end
  end

  # Work in an environment may change any of its repositories, so the running
  # configuration hands the console one contributor policy per repository of
  # each environment since 2026-09-25, each placing the task in exactly that
  # repository. A policy keyed by environment alone, the first pass's shape,
  # named only the first repository, so a Chat task about any other one ran
  # against the wrong working copy; it is refused at start rather than at the
  # first confirmation.
  test "task policies are keyed by environment, then by the repository each task changes" do
    policy = task_policies()["platform"]["docs"]

    for invalid <- [
          %{"platform" => policy},
          %{"platform" => %{"docs" => Map.delete(policy, :repository_ref)}},
          %{"platform" => %{"ryker" => policy}},
          %{"staging" => %{"docs" => policy}},
          %{"platform" => %{"docs" => %{policy | repository_context: %{}}}}
        ] do
      assert_raise ArgumentError, fn ->
        Server.options!(%{configuration() | task_policies: invalid})
      end
    end
  end

  test "accepts a container network listener only when bootstrap marks it explicitly" do
    options =
      Server.options!(
        access: :network,
        ip: {0, 0, 0, 0},
        port: 4_090,
        fallback_work_profile: @outside
      )

    assert options.access == :network
    assert options.ip == {0, 0, 0, 0}
  end

  # The control-plane configuration Assembly builds for an installation with
  # one environment, "platform", holding ryker and docs.
  defp configuration do
    %{
      environments: %{
        "platform" => %{
          display_name: "Platform",
          work_profile: %{
            environment_ref: "platform",
            parallel_goal_limit: 2,
            policies:
              Map.new(@repositories, fn repository ->
                policy = %{
                  policy: "platform-#{repository}-read",
                  policy_digest: digest(repository)
                }

                {repository, %{conversational: policy, deep: policy, standard: policy}}
              end),
            repositories: @repositories
          }
        }
      },
      fallback_work_profile: @outside,
      port: 4_090,
      task_policies: task_policies()
    }
  end

  defp task_policies do
    %{
      "platform" =>
        Map.new(@repositories, fn repository ->
          {repository,
           %{
             digest: digest("#{repository}-contributor"),
             environment_ref: "platform",
             name: "platform-#{repository}-contributor",
             repository_context: %{
               "context_ref" => "platform",
               "parallel_goal_limit" => 2,
               "primary_repository" => repository,
               "read_only_repositories" => List.delete(@repositories, repository)
             },
             repository_ref: repository
           }}
        end)
    }
  end
end
