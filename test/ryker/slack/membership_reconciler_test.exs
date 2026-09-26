defmodule Ryker.Slack.MembershipReconcilerTest do
  use Ryker.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ryker.Fixtures.ChannelEnvironments
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

  alias Ryker.TestSupport.FakeSlackAPI

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

  defmodule UnavailableConfigurations do
    def reconcile_joined(_workspace_ref, _channels, _catalog),
      do: raise(DBConnection.ConnectionError, "connection not available")

    def reconcile_absent(_workspace_ref, _channels, _snapshot_started_at), do: {:ok, 0}
  end

  setup do
    ChannelEnvironments.environment!("infrastructure")
    :ok
  end

  # A periodic sweep runs every five minutes against every joined channel; it
  # may post a welcome only for a membership it repaired itself, never for one
  # that was already joined, or every configured channel gets a hello per sweep.
  test "a missed absent-to-present transition configures the channel and posts exactly one welcome" do
    agent =
      start_supervised!(
        {FakeSlackAPI, channels: [%{channel_ref: "C456", external_shared: false, private: false}]}
      )

    options = options(agent)

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 1, left: 0, prompted: 1}}

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.one!(ChannelMembership).private == false
    assert Repo.aggregate(ConfigurationSession, :count) == 0

    assert %ChannelConfiguration{
             environment_ref: "infrastructure",
             welcome_message_ref: "1.000001"
           } = Repo.one!(ChannelConfiguration)

    assert length(FakeSlackAPI.state(agent).posts) == 1

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 1, left: 0, prompted: 0}}

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.aggregate(ChannelConfiguration, :count) == 1
    assert length(FakeSlackAPI.state(agent).posts) == 1
    assert FakeSlackAPI.state(agent).updates == []
  end

  test "managed incident rooms are excluded from generic channel onboarding" do
    agent =
      start_supervised!(
        {FakeSlackAPI,
         channels: [
           %{channel_ref: "C456", external_shared: false, private: false},
           %{channel_ref: "CINCIDENT", external_shared: false, private: false}
         ]}
      )

    # An installation with no environments yet still onboards its channels.
    options =
      agent
      |> options(%{default_environment: nil, environments: []})
      |> Map.put(:managed_channel?, fn "T9E23FDA39DE5", channel_ref ->
        channel_ref == "CINCIDENT"
      end)

    assert MembershipReconciler.run_once(options) ==
             {:ok, %{channels: 2, left: 0, prompted: 1}}

    assert Repo.get_by!(ChannelMembership, channel_ref: "C456").status == :joined
    assert Repo.get_by!(ChannelConfiguration, channel_ref: "C456").environment_ref == nil
    refute Repo.get_by(ChannelMembership, channel_ref: "CINCIDENT")
    assert length(FakeSlackAPI.state(agent).posts) == 1
  end

  test "the reconciler worker polls once immediately and rejects unsafe configuration" do
    agent =
      start_supervised!({FakeSlackAPI, []})

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
          [api: FakeSlackAPI, api: FailingAPI],
          Map.delete(valid, :api),
          %{valid | interval_ms: 1},
          Map.put(valid, :managed_channel?, :invalid),
          Map.put(valid, :unknown, true)
        ] do
      assert_raise ArgumentError, fn -> MembershipReconciler.options!(invalid) end
    end
  end

  # The reconciler was the one poller the database backoff never covered. A pool
  # outage crashed it, its restart swept again at once and crashed again, and a
  # few of those spend the Slack supervisor's restart budget: the same cascade
  # that once stopped seventeen pollers in 328 ms and took Ryker down with them.
  test "membership reconciliation outlives a database outage" do
    agent =
      start_supervised!({FakeSlackAPI, []})

    options =
      agent
      |> options()
      |> Map.merge(%{configurations: UnavailableConfigurations, interval_ms: 30_000})

    log =
      capture_log(fn ->
        worker =
          start_supervised!(
            Supervisor.child_spec({MembershipReconciler, options}, restart: :temporary)
          )

        # The first sweep is queued when the process starts, ahead of this
        # read, so the read answers only after that sweep has run.
        survived? =
          try do
            _state = :sys.get_state(worker)
            true
          catch
            :exit, _reason -> false
          end

        assert survived?, "a database outage crashed the membership reconciler"
      end)

    assert log =~ "database polling unavailable; retrying after backoff (slack_membership"
  end

  test "already configured channels are counted without another setup prompt" do
    agent =
      start_supervised!(
        {FakeSlackAPI, channels: [%{channel_ref: "C456", external_shared: false, private: false}]}
      )

    configured = %{options(agent) | configurations: StaticConfigurations}

    assert MembershipReconciler.run_once(configured) ==
             {:ok, %{channels: 1, left: 0, prompted: 0}}

    assert FakeSlackAPI.state(agent).posts == []

    assert MembershipReconciler.run_once(%{configured | api: FailingAPI}) ==
             {:error, :slack_unavailable}
  end

  test "a complete snapshot repairs missed leaves without erasing channel configuration" do
    agent =
      start_supervised!(
        {FakeSlackAPI, channels: [%{channel_ref: "C456", external_shared: false, private: false}]}
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

    FakeSlackAPI.put_channels(agent, [])

    assert {:ok, %{channels: 0, left: 1, prompted: 0}} =
             MembershipReconciler.run_once(options)

    assert Repo.get!(ChannelMembership, membership.id).status == :left
    assert Repo.get!(ConfigurationSession, session.id).status == :cancelled
    assert Repo.get!(ChannelConfiguration, configuration.id).revision == 1
  end

  defp options(agent, catalog \\ nil) do
    catalog =
      catalog ||
        %{
          default_environment: "infrastructure",
          environments: [
            %{emisar: false, name: "Infrastructure", ref: "infrastructure", repositories: []}
          ]
        }

    %{
      api: FakeSlackAPI,
      client: agent,
      configurations: ChannelConfigurations,
      setup_handler: ChannelSetup,
      setup_options: %{
        api: FakeSlackAPI,
        bot_user_ref: "UBOT",
        catalog: catalog,
        client: agent,
        configurations: ChannelConfigurations,
        directory: nil,
        operators: chosen_operators([]),
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

  # The people chosen to manage Ryker, with the workspace's admins left out.
  defp chosen_operators(people),
    do:
      Ryker.Slack.Operators.new(
        chosen: people,
        workspace_admins: false,
        workspace_ref: "T9E23FDA39DE5"
      )
end
