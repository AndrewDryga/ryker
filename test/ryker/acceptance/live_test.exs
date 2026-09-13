defmodule Ryker.Acceptance.LiveTest do
  use ExUnit.Case, async: false

  alias Ryker.Acceptance.Live
  alias Ryker.Delivery.JSONClient
  alias Ryker.Slack.Client

  @now ~U[2026-08-30 15:00:00.000000Z]

  test "an immutable release proves an answer and contextual follow-up in one test thread" do
    parent = self()

    {:ok, observer} =
      Agent.start_link(fn ->
        %{
          "acceptance:first" => [
            :pending,
            {:ok, snapshot("episode-a", "session-a", "turn-a", "Answer one")}
          ],
          "acceptance:followup" => [
            {:ok, snapshot("episode-a", "session-b", "turn-b", "Answer two")}
          ]
        }
      end)

    operations = %{
      admit: fn envelope ->
        send(parent, {:envelope, envelope})
        {:ok, "ingress-input:#{get_in(envelope, ["payload", "event_id"])}"}
      end,
      conversation_info: fn "C-TEST" ->
        {:ok,
         %{
           "id" => "C-TEST",
           "is_archived" => false,
           "is_ext_shared" => false,
           "is_member" => true,
           "name" => "ryker-test"
         }}
      end,
      monotonic_ms: monotonic_counter(),
      now: fn -> @now end,
      observe: fn event_ref, _previous_turn_ids -> pop_observation(observer, event_ref) end,
      post_message: fn "C-TEST", nil, document, delivery_ref ->
        send(parent, {:root, document, delivery_ref})
        {:ok, "1788102000.100000"}
      end,
      ready: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    }

    assert {:ok, report} =
             Live.run(configuration(), "C-TEST",
               operations: operations,
               run_id: "acceptance",
               timeout_ms: 2_000
             )

    assert report.episode_id == "episode-a"
    assert report.session_id == "session-a"
    assert report.root_message_ref == "1788102000.100000"
    assert report.turn_ids == ["turn-a", "turn-b"]
    assert report.worker_placement == nil
    assert report.release_version == "0.1.0-dev"
    assert report.synthetic_inputs

    assert_receive {:root, %{"message" => root_message}, "live-acceptance:acceptance:root"}
    assert root_message =~ "Automated Ryker product acceptance"

    assert_receive {:envelope, first}
    assert_receive {:envelope, followup}

    assert get_in(first, ["payload", "event_id"]) == "acceptance:first"
    assert get_in(followup, ["payload", "event_id"]) == "acceptance:followup"
    assert get_in(first, ["payload", "event", "thread_ts"]) == "1788102000.100000"
    assert get_in(followup, ["payload", "event", "thread_ts"]) == "1788102000.100000"

    refute get_in(first, ["payload", "event", "ts"]) ==
             get_in(followup, ["payload", "event", "ts"])
  end

  # The harness asked the configuration for a `runtime_mode` key that assembly
  # never published; it read the absent key as "component" and so never once
  # required a remote placement against the fleet it was accepting. The
  # topology assembly does publish is `execution_mode`.
  test "fleet acceptance proves both turns used a valid remote worker placement" do
    first_placement = %{generation: 3, state: :active, worker_id: "worker-remote-a"}
    followup_placement = %{generation: 4, state: :active, worker_id: "worker-remote-b"}

    first =
      "episode-a"
      |> snapshot("session-a", "turn-a", "Remote answer one")
      |> Map.put(:worker_placement, first_placement)

    followup =
      "episode-a"
      |> snapshot("session-b", "turn-b", "Remote answer two")
      |> Map.put(:worker_placement, followup_placement)

    operations = snapshot_operations(self(), "fleet", first, followup)
    configuration = Map.put(configuration(), :execution_mode, :fleet)

    assert {:ok, report} =
             Live.run(configuration, "C-TEST",
               operations: operations,
               run_id: "fleet",
               timeout_ms: 1_000
             )

    assert report.worker_placement == first_placement

    missing = Map.put(followup, :worker_placement, nil)

    operations = snapshot_operations(self(), "missing-fleet", first, missing)

    assert Live.run(configuration, "C-TEST",
             operations: operations,
             run_id: "missing-fleet",
             timeout_ms: 1_000
           ) == {:error, :live_acceptance_remote_placement_missing}
  end

  test "unsafe or unjoined Slack channels are rejected before posting" do
    parent = self()

    for channel <- [
          %{"id" => "C1", "is_archived" => false, "is_member" => true, "name" => "general"},
          %{"id" => "C1", "is_archived" => false, "is_member" => false, "name" => "test"},
          %{"id" => "C1", "is_archived" => true, "is_member" => true, "name" => "test"},
          %{
            "id" => "C1",
            "is_archived" => false,
            "is_ext_shared" => true,
            "is_member" => true,
            "name" => "test"
          }
        ] do
      operations =
        base_operations(parent)
        |> Map.put(:conversation_info, fn "C1" -> {:ok, channel} end)

      assert Live.run(configuration(), "C1", operations: operations, run_id: "unsafe") ==
               {:error, :live_acceptance_channel_not_safe}

      refute_received :posted
      refute_received {:envelope, _envelope}
    end
  end

  test "a crossed episode fails the live proof" do
    {:ok, observer} =
      Agent.start_link(fn ->
        %{
          "crossed:first" => [
            {:ok, snapshot("episode-a", "session-a", "turn-a", "Answer one")}
          ],
          "crossed:followup" => [
            {:ok, snapshot("episode-b", "session-b", "turn-b", "Answer two")}
          ]
        }
      end)

    operations =
      base_operations(self())
      |> Map.put(:observe, fn event_ref, prior -> pop_observation(observer, event_ref, prior) end)

    assert Live.run(configuration(), "C-TEST",
             operations: operations,
             run_id: "crossed",
             timeout_ms: 1_000
           ) == {:error, :live_acceptance_followup_changed_episode}
  end

  test "invalid live acceptance configuration fails closed before any message is posted" do
    parent = self()

    invalid_cases = [
      {configuration(), nil, [], {:invalid_live_acceptance, :channel_ref}},
      {configuration(), "C-TEST", %{}, {:invalid_live_acceptance, :options}},
      {configuration(), "C-TEST", [run_id: "one", run_id: "two"],
       {:invalid_live_acceptance, :options}},
      {%{}, "C-TEST", [], :live_acceptance_slack_not_configured},
      {put_in(configuration(), [:slack, :identity], %{}), "C-TEST", [],
       {:invalid_live_acceptance, :identity}},
      {put_in(configuration(), [:slack, :operators], []), "C-TEST", [],
       :live_acceptance_operator_not_configured},
      {put_in(configuration(), [:slack, :operators], [" "]), "C-TEST", [],
       {:invalid_live_acceptance, :operator_ref}},
      {configuration(), "C-TEST", [run_id: ""], {:invalid_live_acceptance, :run_id}},
      {configuration(), "C-TEST", [timeout_ms: 0], {:invalid_live_acceptance, :timeout_ms}},
      {configuration(), "C-TEST", [operations: %{}], {:invalid_live_acceptance, :operations}},
      {configuration(), "C-TEST", [operations: :invalid], {:invalid_live_acceptance, :operations}}
    ]

    for {config, channel_ref, options, reason} <- invalid_cases do
      options =
        if is_list(options),
          do: Keyword.put_new(options, :operations, base_operations(parent)),
          else: options

      assert Live.run(config, channel_ref, options) ==
               {:error, reason}

      refute_received :posted
    end
  end

  test "callback failures are surfaced without escaping the acceptance boundary" do
    parent = self()

    cases = [
      {Map.put(base_operations(parent), :ready, fn -> {:error, :not_ready} end),
       {:error, :not_ready}},
      {Map.put(base_operations(parent), :ready, fn -> raise "broken readiness" end),
       {:error, {:live_acceptance_exception, "broken readiness"}}},
      {Map.put(base_operations(parent), :ready, fn -> throw(:broken_readiness) end),
       {:error, {:live_acceptance_caught, :throw, ":broken_readiness"}}},
      {Map.put(base_operations(parent), :conversation_info, fn _channel ->
         {:error, :conversation_failed}
       end), {:error, :conversation_failed}},
      {Map.put(base_operations(parent), :post_message, fn _, _, _, _ ->
         {:error, :post_failed}
       end), {:error, :post_failed}},
      {Map.put(base_operations(parent), :now, fn -> :not_a_datetime end),
       {:error, {:invalid_live_acceptance, :clock}}},
      {Map.put(base_operations(parent), :admit, fn _envelope -> {:error, :admit_failed} end),
       {:error, :admit_failed}}
    ]

    for {operations, expected} <- cases do
      assert Live.run(configuration(), "C-TEST",
               operations: operations,
               run_id: "callback-failure",
               timeout_ms: 1
             ) == expected
    end
  end

  test "invalid, empty, and timed out observations fail with an exact reason" do
    parent = self()

    cases = [
      {:unexpected, {:live_acceptance_observation_invalid, :unexpected}},
      {{:ok, %{}}, :live_acceptance_snapshot_invalid},
      {{:error, :observation_failed}, :observation_failed},
      {{:ok,
        put_in(
          snapshot("episode-a", "session-a", "turn-a", "ok"),
          [:delivery_document, "message"],
          "  "
        )}, :live_acceptance_empty_delivery},
      {:pending, {:live_acceptance_timeout, "observation:first"}}
    ]

    for {observation, reason} <- cases do
      operations =
        base_operations(parent)
        |> Map.put(:observe, fn _event_ref, _previous -> observation end)

      assert Live.run(configuration(), "C-TEST",
               operations: operations,
               run_id: "observation",
               timeout_ms: 1
             ) == {:error, reason}
    end
  end

  test "continuation identity and delivery destination are independently verified" do
    cases = [
      {snapshot("episode-a", "session-a", "turn-a", "one"),
       snapshot("episode-a", "session-a", "turn-a", "two"),
       :live_acceptance_followup_reused_turn},
      {put_in(
         snapshot("episode-a", "session-a", "turn-a", "one"),
         [:external_receipt, "conversation_ref"],
         "slack:T-OTHER:C-OTHER"
       ), snapshot("episode-a", "session-a", "turn-b", "two"),
       :live_acceptance_delivery_misrouted}
    ]

    for {first, followup, reason} <- cases do
      operations = snapshot_operations(self(), "identity", first, followup)

      assert Live.run(configuration(), "C-TEST",
               operations: operations,
               run_id: "identity",
               timeout_ms: 1_000
             ) == {:error, reason}
    end
  end

  test "the production harness requires the exact running release at readiness" do
    {port, server} = ready_server(200, "crossed-release")

    assert Live.run(production_configuration(port), "C-TEST", run_id: "production") ==
             {:error, :live_acceptance_release_version_mismatch}

    Task.await(server)

    {port, server} = ready_server(503, nil)

    assert Live.run(production_configuration(port), "C-TEST", run_id: "production") ==
             {:error, {:live_acceptance_deployment_not_ready, 503}}

    Task.await(server)

    assert Live.run(production_configuration(nil), "C-TEST", run_id: "production") ==
             {:error, :live_acceptance_control_plane_not_configured}

    {ready_port, ready} = ready_server(200, "0.1.0-dev")
    {slack_url, slack} = json_server(~s({"ok":false,"error":"acceptance-stop"}))

    assert Live.run(production_configuration(ready_port, slack_url), "C123", run_id: "production") ==
             {:error, {:slack_api_error, "acceptance-stop"}}

    Task.await(ready)
    Task.await(slack)
  end

  test "the environment entrypoint rejects malformed paths and timeout values" do
    variables = ~w(RYKER_LIVE_CHANNEL RYKER_LIVE_TIMEOUT_SECONDS)
    previous = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("RYKER_LIVE_CHANNEL", "C-TEST")
    System.put_env("RYKER_LIVE_TIMEOUT_SECONDS", "600")

    # The harness observes a running deployment, so it takes no configuration
    # path at all; a malformed channel or timeout still fails before any work.
    System.delete_env("RYKER_LIVE_CHANNEL")

    assert_raise RuntimeError,
                 ~r/live acceptance failed: \{:invalid_live_acceptance, :channel_ref\}/,
                 fn -> Live.run_from_env!() end

    System.put_env("RYKER_LIVE_CHANNEL", "C-TEST")

    for timeout <- ["invalid", "0", "10seconds"] do
      System.put_env("RYKER_LIVE_TIMEOUT_SECONDS", timeout)
      assert_raise RuntimeError, "live acceptance timeout is invalid", &Live.run_from_env!/0
    end
  end

  defp configuration do
    %{
      execution_mode: :direct,
      slack: %{
        default_repository: "ryker",
        identity: %{
          bot_ref: "B-RYKER",
          bot_user_ref: "U-RYKER",
          workspace_ref: "T-TEST"
        },
        operators: ["U-OPERATOR"]
      }
    }
  end

  defp production_configuration(port, slack_url \\ "https://slack.com/api") do
    {:ok, http} =
      JSONClient.new(%{
        base_url: slack_url,
        finch: Ryker.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, "xoxb-test"} end
      })

    {:ok, bot_client} = Client.new(http: http, requester: JSONClient)

    configuration = %{
      execution_mode: :fleet,
      slack: %{
        app_http: http,
        bot_client: bot_client,
        default_repository: "ryker",
        identity: %{
          bot_ref: "B123",
          bot_user_ref: "U999",
          workspace_ref: "T123"
        },
        incident_policy: %{digest: String.duplicate("c", 64), name: "incident-observe"},
        operators: ["U123"],
        repositories: %{
          "ryker" => %{
            contributor_policy: %{
              digest: String.duplicate("b", 64),
              name: "ryker-contributor"
            }
          }
        },
        default_participation: :proactive
      }
    }

    if port,
      do: Map.put(configuration, :control_plane, %{ip: {127, 0, 0, 1}, port: port}),
      else: configuration
  end

  defp base_operations(parent) do
    %{
      admit: fn envelope ->
        send(parent, {:envelope, envelope})
        {:ok, "ingress-input:accepted"}
      end,
      conversation_info: fn "C-TEST" ->
        {:ok,
         %{
           "id" => "C-TEST",
           "is_archived" => false,
           "is_ext_shared" => false,
           "is_member" => true,
           "name" => "test"
         }}
      end,
      monotonic_ms: monotonic_counter(),
      now: fn -> @now end,
      observe: fn _event_ref, _previous -> :pending end,
      post_message: fn _channel, _thread, _document, _delivery_ref ->
        send(parent, :posted)
        {:ok, "1788102000.100000"}
      end,
      ready: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    }
  end

  defp snapshot_operations(parent, run_id, first, followup) do
    {:ok, observer} =
      Agent.start_link(fn ->
        %{
          "#{run_id}:first" => [{:ok, first}],
          "#{run_id}:followup" => [{:ok, followup}]
        }
      end)

    base_operations(parent)
    |> Map.put(:observe, fn event_ref, prior -> pop_observation(observer, event_ref, prior) end)
  end

  defp snapshot(episode_id, session_id, turn_id, message) do
    %{
      delivery_document: %{"message" => message},
      episode_id: episode_id,
      external_receipt: %{
        "conversation_ref" => "slack:T-TEST:C-TEST",
        "delivery_ref" => "delivery:#{turn_id}",
        "message_ref" => "1788102000.#{if(turn_id == "turn-a", do: "200000", else: "300000")}",
        "thread_ref" => "1788102000.100000",
        "transport" => "slack"
      },
      session_id: session_id,
      turn_id: turn_id,
      worker_placement: nil
    }
  end

  defp pop_observation(observer, event_ref, _prior \\ []) do
    Agent.get_and_update(observer, fn state ->
      [next | rest] = Map.fetch!(state, event_ref)
      {next, Map.put(state, event_ref, rest)}
    end)
  end

  defp monotonic_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    fn -> Agent.get_and_update(counter, &{&1, &1 + 250}) end
  end

  defp ready_server(status, version) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        phrase = if(status == 200, do: "OK", else: "Unavailable")
        version_header = if version, do: "x-ryker-version: #{version}\r\n", else: ""

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} #{phrase}\r\n#{version_header}content-length: 0\r\nconnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {port, server}
  end

  defp json_server(body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", server}
  end
end
