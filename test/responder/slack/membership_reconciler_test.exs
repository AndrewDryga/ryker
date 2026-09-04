defmodule Responder.Slack.MembershipReconcilerTest do
  use Responder.DataCase, async: true

  import ExUnit.CaptureLog

  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfigurations,
    ChannelMembership,
    ChannelSetup,
    ConfigurationSession,
    MembershipReconciler
  }

  defmodule API do
    def joined_conversations(agent), do: Agent.get(agent, &{:ok, &1.channels})

    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get(agent, fn state ->
        case Map.get(state.deliveries, {channel, thread, delivery_ref}) do
          nil -> :not_found
          message_ref -> {:ok, message_ref}
        end
      end)
    end

    def post_message(agent, channel, thread, _document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref = "#{map_size(state.deliveries) + 1}.000001"
        key = {channel, thread, delivery_ref}

        {{:ok, message_ref},
         %{
           state
           | deliveries: Map.put(state.deliveries, key, message_ref),
             posts: state.posts + 1
         }}
      end)
    end
  end

  defmodule FailingAPI do
    def joined_conversations(_client), do: {:error, :slack_unavailable}
  end

  defmodule StaticConfigurations do
    def reconcile_joined(_workspace_ref, _channels, _catalog) do
      {:ok, [%{session: %{status: :ready}}, %{configuration: %{status: :configured}}]}
    end

    def reconcile_absent(_workspace_ref, _channels, _snapshot_started_at), do: {:ok, 0}
  end

  test "a missed absent-to-present transition creates and posts exactly one durable setup" do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             channels: [%{channel_ref: "C456", external_shared: false, private: false}],
             deliveries: %{},
             posts: 0
           }
         end}
      )

    options = options(agent)

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 1, left: 0, prompted: 1}}

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.one!(ChannelMembership).private == false
    assert Repo.aggregate(ConfigurationSession, :count) == 1
    assert Agent.get(agent, & &1.posts) == 1

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 1, left: 0, prompted: 1}}

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.aggregate(ConfigurationSession, :count) == 1
    assert Agent.get(agent, & &1.posts) == 1
  end

  test "managed incident rooms are excluded from generic channel onboarding" do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             channels: [
               %{channel_ref: "C456", external_shared: false, private: false},
               %{channel_ref: "CINCIDENT", external_shared: false, private: false}
             ],
             deliveries: %{},
             posts: 0
           }
         end}
      )

    options =
      options(agent)
      |> Map.put(:managed_channel?, fn "T123", channel_ref ->
        channel_ref == "CINCIDENT"
      end)

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 2, left: 0, prompted: 1}}

    assert Repo.get_by!(ChannelMembership, channel_ref: "C456").status == :joined
    refute Repo.get_by(ChannelMembership, channel_ref: "CINCIDENT")
    assert Agent.get(agent, & &1.posts) == 1
  end

  test "the reconciler worker polls once immediately and rejects unsafe configuration" do
    agent =
      start_supervised!({Agent, fn -> %{channels: [], deliveries: %{}, posts: 0} end})

    valid =
      agent
      |> options()
      |> Map.merge(%{
        configurations: StaticConfigurations,
        interval_ms: 30_000,
        name: :membership_reconciler_test
      })

    assert MembershipReconciler.options!(Map.to_list(valid)).name == :membership_reconciler_test

    {:ok, worker} = start_supervised({MembershipReconciler, valid})
    Process.sleep(5)
    assert Process.alive?(worker)

    failing = %{valid | api: FailingAPI, name: :membership_reconciler_failure_test}

    log =
      capture_log(fn ->
        {:ok, failing_worker} = MembershipReconciler.start_link(failing)
        Process.sleep(5)
        GenServer.stop(failing_worker)
      end)

    assert log =~ "Slack membership reconciliation failed"

    for invalid <- [
          :invalid,
          [],
          [api: API, api: FailingAPI],
          Map.delete(valid, :api),
          %{valid | interval_ms: 1},
          Map.put(valid, :managed_channel?, :invalid),
          Map.put(valid, :unknown, true)
        ] do
      assert_raise ArgumentError, fn -> MembershipReconciler.options!(invalid) end
    end
  end

  test "already configured channels are counted without another setup prompt" do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             channels: [%{channel_ref: "C456", external_shared: false, private: false}],
             deliveries: %{},
             posts: 0
           }
         end}
      )

    configured = %{options(agent) | configurations: StaticConfigurations}

    assert MembershipReconciler.run_once(configured) ==
             {:ok, %{channels: 1, left: 0, prompted: 0}}

    assert Agent.get(agent, & &1.posts) == 0

    assert MembershipReconciler.run_once(%{configured | api: FailingAPI}) ==
             {:error, :slack_unavailable}
  end

  test "a complete snapshot repairs missed leaves without erasing channel configuration" do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             channels: [%{channel_ref: "C456", external_shared: false, private: false}],
             deliveries: %{},
             posts: 0
           }
         end}
      )

    options = options(agent)

    assert {:ok, %{left: 0}} = MembershipReconciler.run_once(options)
    membership = Repo.get_by!(ChannelMembership, channel_ref: "C456")
    session = Repo.one!(ConfigurationSession)

    Agent.update(agent, &%{&1 | channels: []})

    assert {:ok, %{channels: 0, left: 1, prompted: 0}} =
             MembershipReconciler.run_once(options)

    assert Repo.get!(ChannelMembership, membership.id).status == :left
    assert Repo.get!(ConfigurationSession, session.id).status == :cancelled
  end

  defp options(agent) do
    %{
      api: API,
      client: agent,
      configurations: ChannelConfigurations,
      setup_handler: ChannelSetup,
      setup_options: %{
        api: API,
        bot_user_ref: "U-BOT",
        catalog: %{
          default_repository: "infrastructure",
          repository_refs: ["infrastructure"]
        },
        client: agent,
        configurations: ChannelConfigurations,
        directory: nil,
        operators: MapSet.new()
      },
      workspace_ref: "T123"
    }
  end
end
