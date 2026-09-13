defmodule Ryker.Slack.MembershipReconcilerTest do
  use Ryker.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ryker.Repo

  alias Ryker.Slack.{
    ChannelConfiguration,
    ChannelConfigurations,
    ChannelMembership,
    ChannelSettings,
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

    def update_message(agent, _channel, _message_ref, _document, _delivery_ref) do
      Agent.update(agent, &Map.update(&1, :updates, 1, fn count -> count + 1 end))
    end
  end

  defmodule FailingAPI do
    def joined_conversations(_client), do: {:error, :slack_unavailable}
  end

  defmodule StaticConfigurations do
    def reconcile_joined(_workspace_ref, _channels, _catalog) do
      {:ok,
       [
         %{configuration: %{revision: 1}, status: :unchanged},
         %{configuration: nil, status: :left}
       ]}
    end

    def reconcile_absent(_workspace_ref, _channels, _snapshot_started_at), do: {:ok, 0}
  end

  # A periodic sweep runs every five minutes against every joined channel; it
  # may post a welcome only for a membership it repaired itself, never for one
  # that was already joined, or every configured channel gets a hello per sweep.
  test "a missed absent-to-present transition configures the channel and posts exactly one welcome" do
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
    assert Repo.aggregate(ConfigurationSession, :count) == 0

    assert %ChannelConfiguration{welcome_message_ref: "1.000001"} =
             Repo.one!(ChannelConfiguration)

    assert Agent.get(agent, & &1.posts) == 1

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 1, left: 0, prompted: 0}}

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.aggregate(ChannelConfiguration, :count) == 1
    assert Agent.get(agent, & &1.posts) == 1
    assert Agent.get(agent, &Map.get(&1, :updates, 0)) == 0
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
      |> Map.put(:managed_channel?, fn "T9E23FDA39DE5", channel_ref ->
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
    configuration = Repo.one!(ChannelConfiguration)

    assert {:ok, %{session: session}} =
             ChannelConfigurations.start_reconfiguration(
               %{
                 actor_ref: "U123",
                 channel_ref: "C456",
                 event_ref: "event:reconfigure",
                 occurred_at: DateTime.utc_now(),
                 thread_ref: nil,
                 workspace_ref: "T9E23FDA39DE5"
               },
               options.setup_options.catalog
             )

    Agent.update(agent, &%{&1 | channels: []})

    assert {:ok, %{channels: 0, left: 1, prompted: 0}} =
             MembershipReconciler.run_once(options)

    assert Repo.get!(ChannelMembership, membership.id).status == :left
    assert Repo.get!(ConfigurationSession, session.id).status == :cancelled
    assert Repo.get!(ChannelConfiguration, configuration.id).revision == 1
  end

  defp options(agent) do
    %{
      api: API,
      client: agent,
      configurations: ChannelConfigurations,
      setup_handler: ChannelSetup,
      setup_options: %{
        api: API,
        bot_user_ref: "UBOT",
        catalog: %{
          default_repository: "infrastructure",
          repository_refs: ["infrastructure"]
        },
        client: agent,
        configurations: ChannelConfigurations,
        directory: nil,
        operators: MapSet.new(),
        settings_overrides: fn workspace_ref, channel_ref ->
          ChannelSettings.effective(
            workspace_ref,
            "slack:#{workspace_ref}:#{channel_ref}",
            :mentions
          )
        end
      },
      workspace_ref: "T9E23FDA39DE5"
    }
  end
end
