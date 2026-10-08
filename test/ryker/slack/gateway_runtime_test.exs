defmodule Ryker.Slack.GatewayRuntimeTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Fixtures.SlackVoice
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.{AttachmentIngestor, Gateway}
  alias Ryker.TestTranscriber
  alias Ryker.Transcription.Worker, as: TranscriptionWorker

  defmodule Transport do
    @behaviour Ryker.Slack.SocketTransport

    @impl true
    def connect(%{connect_results: connect_results, observer: observer} = options) do
      result =
        Agent.get_and_update(connect_results, fn
          [result | remaining] -> {result, remaining}
          [] -> {:ok, []}
        end)

      case result do
        :ok ->
          send(observer, {:socket_connected, self()})
          {:ok, options}

        {:error, reason} ->
          send(observer, {:socket_connect_failed, self(), reason})
          {:error, reason}
      end
    end

    def connect(%{observer: observer} = options) do
      send(observer, {:socket_connected, self()})
      {:ok, options}
    end

    @impl true
    def stream(_state, :socket_stream_error), do: {:error, :socket_failed}
    def stream(state, {:socket_frame, frame}), do: {:ok, state, [frame]}
    def stream(state, _message), do: {:unknown, state}

    @impl true
    def send_frame(%{observer: observer, send_error: true}, frame) do
      send(observer, {:socket_send_failed, frame})
      {:error, :socket_write_failed}
    end

    def send_frame(%{observer: observer} = state, frame) do
      send(observer, {:socket_sent, frame})
      {:ok, state}
    end

    @impl true
    def close(%{observer: observer}) do
      send(observer, {:socket_closed, self()})
      :ok
    end
  end

  defmodule Directory do
    @behaviour Ryker.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "T123"), do: {:ok, true}
  end

  defmodule InteractionHandler do
    def handle(_interaction, %{observer: observer, result: result}) do
      send(observer, :interaction_started)
      result
    end
  end

  defmodule HeldTranscriber do
    @behaviour Ryker.Transcription

    # Runs until the test lets it finish, so a transcription can be held in
    # progress for as long as the test needs.
    @impl true
    def transcribe(_data, _options) do
      send(Ryker.Slack.GatewayRuntimeTest, {:transcribing, self()})

      receive do
        {:finish_transcription, words} -> {:ok, words}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  test "acknowledges an event only after its normalized input is durable" do
    gateway = start_gateway(settings())
    assert_receive {:socket_connected, ^gateway}
    Sandbox.allow(Ryker.Repo, self(), gateway)

    send(gateway, {:socket_frame, {:text, Jason.encode!(message_envelope())}})

    assert_receive {:socket_sent, {:text, acknowledgement}}, 1_000
    assert %{"envelope_id" => "env-event"} = Jason.decode!(acknowledgement)

    assert [%{status: :pending, event_ref: "Ev-1"}] =
             Ryker.Repo.all(Inbox.Entry)
  end

  # The gateway takes one envelope at a time. A voice message transcribed
  # inside it held every later Slack event for up to a minute, and Slack
  # delivered a clip longer than about 25 s twice (2026-09-27). Transcription
  # runs beside the gateway now, after the acknowledgement.
  test "another Slack event is acknowledged while a voice message is being transcribed" do
    Process.register(self(), __MODULE__)
    file = %{SlackVoice.file() | "duration_ms" => 95_000}

    settings =
      settings()
      |> Map.put(:attachment_ingestor, AttachmentIngestor)
      |> Map.put(
        :attachment_options,
        SlackVoice.attachment_options({:ok, file, TestTranscriber.recording("unheard")})
      )

    gateway = start_gateway(settings)
    assert_receive {:socket_connected, ^gateway}
    worker = start_supervised!({TranscriptionWorker, transcriber: HeldTranscriber})

    voice = SlackVoice.envelope("Ev-voice", file: file, workspace_ref: "T123")
    send(gateway, {:socket_frame, {:text, Jason.encode!(voice)}})
    assert_receive {:socket_sent, {:text, acknowledgement}}, 1_000
    assert %{"envelope_id" => "env-Ev-voice"} = Jason.decode!(acknowledgement)

    assert_receive {:transcribing, ^worker}, 1_000

    send(gateway, {:socket_frame, {:text, Jason.encode!(message_envelope())}})
    assert_receive {:socket_sent, {:text, acknowledgement}}, 1_000
    assert %{"envelope_id" => "env-event"} = Jason.decode!(acknowledgement)

    [voice_entry] =
      Ryker.Repo.all(from(entry in Inbox.Entry, where: entry.event_ref == "Ev-voice"))

    assert [%{"transcript_pending" => true}] = voice_entry.content["files"]

    :ok = Inbox.subscribe_inputs()
    send(worker, {:finish_transcription, "Roll back the payments deploy"})
    id = voice_entry.id
    assert_receive {:input_updated, ^id}, 1_000

    assert {:ok, transcribed} = Inbox.fetch(Inbox.ref(voice_entry))
    assert [%{"transcript" => "Roll back the payments deploy"}] = transcribed.content["files"]
  end

  test "does not acknowledge a transient host-control failure" do
    settings =
      settings()
      |> Map.put(:interaction_handler, InteractionHandler)
      |> Map.put(:interaction_options, %{observer: self(), result: {:error, :database_down}})

    gateway = start_gateway(settings)
    assert_receive {:socket_connected, ^gateway}
    Sandbox.allow(Ryker.Repo, self(), gateway)

    send(gateway, {:socket_frame, {:text, Jason.encode!(interaction_envelope())}})

    assert_receive :interaction_started
    refute_receive {:socket_sent, _frame}, 50
  end

  test "answers ping frames and reconnects after a close frame" do
    gateway = start_gateway(settings(), reconnect_ms: 10)
    assert_receive {:socket_connected, ^gateway}

    send(gateway, {:socket_frame, {:ping, "probe"}})
    assert_receive {:socket_sent, {:pong, "probe"}}

    send(gateway, {:socket_frame, {:close, 1001, "refresh_requested"}})
    assert_receive {:socket_closed, ^gateway}
    assert_receive {:socket_connected, ^gateway}, 1_000
  end

  test "rejects malformed runtime configuration" do
    base = [
      handler_settings: settings(),
      transport: Transport,
      transport_options: %{observer: self()}
    ]

    assert_raise ArgumentError, fn -> Gateway.options!(Keyword.put(base, :reconnect_ms, 0)) end

    assert_raise ArgumentError, fn ->
      Gateway.options!(Keyword.put(base, :receive_timeout_ms, 400_000))
    end

    assert_raise ArgumentError, fn ->
      Gateway.options!(Keyword.put(base, :transport, :missing))
    end

    assert_raise ArgumentError, fn -> Gateway.options!(%{unknown: true}) end
    assert_raise ArgumentError, fn -> Gateway.options!(:invalid) end
    assert_raise ArgumentError, fn -> Gateway.options!(base ++ [transport: Transport]) end
  end

  test "malformed, binary, and disconnect frames cannot be acknowledged as platform work" do
    gateway = start_gateway(settings(), reconnect_ms: 10)
    assert_receive {:socket_connected, ^gateway}

    send(gateway, {:socket_frame, {:text, "not-json"}})
    refute_receive {:socket_sent, _frame}, 20

    send(gateway, {:socket_frame, {:binary, <<1, 2, 3>>}})
    assert_receive {:socket_closed, ^gateway}
    assert_receive {:socket_connected, ^gateway}, 1_000

    send(gateway, {
      :socket_frame,
      {:text, Jason.encode!(%{"type" => "disconnect", "reason" => "refresh_requested"})}
    })

    assert_receive {:socket_closed, ^gateway}
    assert_receive {:socket_connected, ^gateway}, 1_000
  end

  test "an idle or failed stream is closed and reconnected" do
    gateway = start_gateway(settings(), receive_timeout_ms: 10, reconnect_ms: 10)
    assert_receive {:socket_connected, ^gateway}
    assert_receive {:socket_closed, ^gateway}, 1_000
    assert %{reconnect_failures: 0} = :sys.get_state(gateway)
    assert_receive {:socket_connected, ^gateway}, 1_000

    send(gateway, :socket_stream_error)
    assert_receive {:socket_closed, ^gateway}
    assert_receive {:socket_connected, ^gateway}, 1_000

    send(gateway, {:socket_frame, {:pong, "alive"}})
    send(gateway, {:socket_frame, {:unexpected, "frame"}})
    assert_receive {:socket_closed, ^gateway}
  end

  # Setup, Integrations and Chat say whether Slack is connected. The
  # connection is the gateway's own state, not a row, so no trigger ever saw
  # it change and an open page caught up only on its five-second poll. The
  # gateway now announces it connecting and dropping the connection.
  test "the connection coming up and going down reaches the pages that say whether Slack works" do
    :ok = Gateway.subscribe_connection()
    gateway = start_gateway(settings(), reconnect_ms: 10)
    assert_receive {:socket_connected, ^gateway}
    assert_receive {:slack_connection_changed, true}

    send(gateway, :socket_stream_error)
    assert_receive {:socket_closed, ^gateway}
    assert_receive {:slack_connection_changed, false}
    assert_receive {:slack_connection_changed, true}, 1_000
  end

  test "recovers a failed connection and ignores stale runtime messages" do
    connect_results = start_supervised!({Agent, fn -> [{:error, :offline}, :ok] end})

    gateway =
      start_gateway(settings(),
        name: :slack_gateway_reconnect_test,
        reconnect_ms: 10,
        transport_options: %{connect_results: connect_results, observer: self()}
      )

    assert Process.whereis(:slack_gateway_reconnect_test) == gateway
    assert_receive {:socket_connect_failed, ^gateway, :offline}
    assert_receive {:socket_connected, ^gateway}, 1_000
    %{connection: connection} = :sys.get_state(gateway)

    send(gateway, :connect)
    send(gateway, {:socket_idle, make_ref()})
    send(gateway, :unknown_socket_message)

    # Handled, and the socket it had is the socket it keeps.
    assert %{connection: ^connection} = :sys.get_state(gateway)
    refute_receive {:socket_closed, ^gateway}, 20
  end

  test "a failed acknowledgement and oversized frame close the uncertain connection" do
    gateway =
      start_gateway(settings(),
        reconnect_ms: 10,
        transport_options: %{observer: self(), send_error: true}
      )

    assert_receive {:socket_connected, ^gateway}
    Sandbox.allow(Ryker.Repo, self(), gateway)

    send(gateway, {:socket_frame, {:text, Jason.encode!(message_envelope())}})
    assert_receive {:socket_send_failed, {:text, _acknowledgement}}
    assert_receive {:socket_closed, ^gateway}
    assert_receive {:socket_connected, ^gateway}, 1_000

    send(gateway, {:socket_frame, {:text, String.duplicate("x", 1_048_577)}})
    assert_receive {:socket_closed, ^gateway}
  end

  test "a failed pong also reconnects instead of claiming a healthy socket" do
    gateway =
      start_gateway(settings(),
        reconnect_ms: 10,
        transport_options: %{observer: self(), send_error: true}
      )

    assert_receive {:socket_connected, ^gateway}
    send(gateway, {:socket_frame, {:ping, "probe"}})
    assert_receive {:socket_send_failed, {:pong, "probe"}}
    assert_receive {:socket_closed, ^gateway}
  end

  test "non-envelope JSON and messages received while disconnected stay inert" do
    connect_results = start_supervised!({Agent, fn -> [{:error, :offline}] end})

    gateway =
      start_gateway(settings(),
        reconnect_ms: 5_000,
        transport_options: %{connect_results: connect_results, observer: self()}
      )

    assert_receive {:socket_connect_failed, ^gateway, :offline}
    send(gateway, {:socket_frame, {:text, "[]"}})
    assert %{connection: nil} = :sys.get_state(gateway)
    stop_supervised(Gateway)

    connected = start_gateway(settings())
    assert_receive {:socket_connected, ^connected}
    send(connected, {:socket_frame, {:text, "[]"}})
    refute_receive {:socket_sent, _frame}, 20
  end

  # Found live 2026-09-27 22:23 UTC: after a deploy the first connect failed,
  # the retry failed too, and the gateway never tried again. The retry was
  # still marked as scheduled, so the second failure scheduled nothing and
  # Slack stayed "Connecting" until someone restarted Ryker.
  test "a connection that keeps failing keeps being retried until it connects" do
    connect_results =
      start_supervised!(
        {Agent, fn -> [{:error, :offline}, {:error, :still_offline}, {:error, :again}, :ok] end}
      )

    gateway =
      start_gateway(settings(),
        name: :slack_gateway_retry_test,
        reconnect_ms: 5,
        transport_options: %{connect_results: connect_results, observer: self()}
      )

    assert_receive {:socket_connect_failed, ^gateway, :offline}
    assert_receive {:socket_connect_failed, ^gateway, :still_offline}, 1_000
    assert_receive {:socket_connect_failed, ^gateway, :again}, 1_000
    assert_receive {:socket_connected, ^gateway}, 1_000
    assert Gateway.connected?(:slack_gateway_retry_test)
  end

  test "immediate Slack disconnects keep increasing reconnect backoff" do
    gateway = start_gateway(settings(), reconnect_ms: 5_000)
    assert_receive {:socket_connected, ^gateway}

    for expected_failures <- 1..2 do
      send(gateway, {
        :socket_frame,
        {:text, Jason.encode!(%{"type" => "disconnect", "reason" => "too_many_websockets"})}
      })

      assert_receive {:socket_closed, ^gateway}
      assert %{connection: nil, reconnect_failures: ^expected_failures} = :sys.get_state(gateway)

      # Overtake the long retry so the next short-lived connection exercises
      # the same path without waiting for the timer.
      send(gateway, :connect)
      assert_receive {:socket_connected, ^gateway}
    end
  end

  test "direct reconnect overtakes a pending retry and termination closes only live sockets" do
    connect_results =
      start_supervised!({Agent, fn -> [{:error, :offline}, {:error, :still_offline}] end})

    gateway =
      start_gateway(settings(),
        reconnect_ms: 5_000,
        transport_options: %{connect_results: connect_results, observer: self()}
      )

    assert_receive {:socket_connect_failed, ^gateway, :offline}
    send(gateway, :connect)
    assert_receive {:socket_connect_failed, ^gateway, :still_offline}
    assert Gateway.terminate(:shutdown, :sys.get_state(gateway)) == :ok

    assert_raise ArgumentError, fn ->
      Gateway.options!(%{
        handler_settings: settings(),
        transport: "not-a-module",
        transport_options: %{}
      })
    end

    stop_supervised(Gateway)
    live = start_gateway(settings(), name: :live_termination_gateway)
    assert_receive {:socket_connected, ^live}
    caller = self()
    assert Gateway.terminate(:shutdown, :sys.get_state(live)) == :ok
    assert_receive {:socket_closed, ^caller}
  end

  defp start_gateway(handler_settings, overrides \\ []) do
    options =
      Keyword.merge(
        [
          handler_settings: handler_settings,
          reconnect_ms: 50,
          receive_timeout_ms: 5_000,
          transport: Transport,
          transport_options: %{observer: self()}
        ],
        overrides
      )

    start_supervised!({Gateway, options})
  end

  defp settings do
    %{
      client: :client,
      directory: Directory,
      identity: %{bot_ref: "B-BOT", bot_user_ref: "UBOT", workspace_ref: "T123"},
      inbox: Inbox,
      interaction_handler: Ryker.Slack.InteractionHandler,
      interaction_options: %{},
      effective_settings: &installation_participation/2
    }
  end

  defp message_envelope do
    %{
      "envelope_id" => "env-event",
      "payload" => %{
        "event" => %{
          "channel" => "C456",
          "event_ts" => "1787832001.000200",
          "text" => "<@UBOT> investigate",
          "ts" => "1787832001.000200",
          "type" => "app_mention",
          "user" => "U123"
        },
        "event_id" => "Ev-1",
        "event_time" => 1_787_832_001,
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp interaction_envelope do
    %{
      "envelope_id" => "env-interaction",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "ryker_start_engineering_task",
            "type" => "button",
            "value" => "record:task_offer:abc123"
          }
        ],
        "container" => %{
          "channel_id" => "C456",
          "is_ephemeral" => false,
          "message_ts" => "1787832001.000200",
          "thread_ts" => "1787832000.000100",
          "type" => "message"
        },
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end

  defp installation_participation(_workspace_ref, _conversation_ref) do
    %{
      proactive: %{source: :installation, value: false},
      shadow: %{source: :installation, value: false}
    }
  end
end
