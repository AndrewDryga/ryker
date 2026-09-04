defmodule Responder.Operator.MixTasksTest do
  use Responder.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Responder.{Doctor, OperatorSupport, Replay, Retry, Status}
  alias Mix.Tasks.Responder.Failures, as: FailuresTask
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.WorkProfile
  alias Responder.RuntimeConfiguration
  alias Responder.Slack.Input, as: SlackInput

  @occurred_at ~U[2026-09-04 08:00:00Z]

  test "read-only failure inspection starts only database dependencies" do
    script = """
    repo_config = Application.fetch_env!(:responder, Responder.Repo)

    Application.put_env(
      :responder,
      Responder.Repo,
      Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:responder, :admission, :must_not_start)
    Application.put_env(:responder, :work, :must_not_start)
    Application.put_env(:responder, :delivery, :must_not_start)
    Mix.Task.run("responder.failures", [])

    if Process.whereis(Responder.Supervisor), do: System.halt(73)
    """

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    documents =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, value} -> [value]
          {:error, _reason} -> []
        end
      end)

    assert [[]] = documents
  end

  test "failure inspection prints the shared empty projection in-process" do
    assert capture_io(fn -> FailuresTask.run([]) end) == "[]\n"
  end

  test "failure inspection rejects a relative runtime configuration" do
    assert_raise Mix.Error, ~r/configuration_path_must_be_absolute/, fn ->
      FailuresTask.run(["--config", "config/responder.yaml"])
    end
  end

  test "doctor requires an absolute runtime configuration" do
    assert_raise Mix.Error, ~r/configuration_path_must_be_absolute/, fn ->
      Doctor.run(["--config", "config/responder.yaml"])
    end
  end

  test "status requires an explicit runtime configuration" do
    assert_raise Mix.Error, ~r/configuration_path_required/, fn ->
      Status.run([])
    end
  end

  test "doctor and status accept one explicit current runtime configuration" do
    path = runtime_configuration!()

    doctor = capture_io(fn -> Doctor.run(["--config", path]) end) |> Jason.decode!()
    status = capture_io(fn -> Status.run(["--config", path]) end) |> Jason.decode!()

    assert doctor["status"] == "ok"
    assert status["preflight"]["status"] == "ok"
    assert is_map(status["failures"])
  end

  test "retry requires configuration before attempting a mutation" do
    assert_raise Mix.Error, ~r/configuration_path_required/, fn ->
      Retry.run(["publication", "publication:not-retryable"])
    end
  end

  test "replay rejects unsupported modes before opening the repository" do
    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Replay.run(["publish", "ingress-input:any"])
    end
  end

  test "replay show opens only the read-only lookup path" do
    assert_raise Mix.Error, ~r/slack_replay_not_found/, fn ->
      Replay.run(["show", "ingress-input:00000000-0000-0000-0000-000000000000"])
    end
  end

  test "mutating commands reject an identity absent from configured Slack operators" do
    path = runtime_configuration!()

    assert_raise Mix.Error, ~r/configured_slack_operator_required/, fn ->
      Retry.run([
        "admission",
        "ingress-input:any",
        "--config",
        path,
        "--operator",
        "U123",
        "--action-ref",
        "operator-action:retry"
      ])
    end

    assert_raise Mix.Error, ~r/configured_slack_operator_required/, fn ->
      Replay.run([
        "slack",
        "ingress-input:any",
        "request",
        "--config",
        path,
        "--operator",
        "U123",
        "--action-ref",
        "operator-action:replay"
      ])
    end
  end

  test "authorized retry and replay commands execute through audited custody" do
    path = runtime_configuration!(slack_operator: "U123")
    assert {:ok, input} = slack_input()
    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile!())

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("operator-mix-task-test", DateTime.utc_now(), 60)

    assert {:ok, _blocked} =
             Inbox.block(Inbox.ref(entry), lease_ref, "model_contract", "retained detail")

    retry =
      capture_io(fn ->
        Retry.run([
          "admission",
          Inbox.ref(entry),
          "--config",
          path,
          "--operator",
          "U123",
          "--action-ref",
          "operator-action:mix-retry"
        ])
      end)
      |> Jason.decode!()

    replay =
      capture_io(fn ->
        Replay.run([
          "slack",
          Inbox.ref(entry),
          "request",
          "--config",
          path,
          "--operator",
          "U123",
          "--action-ref",
          "operator-action:mix-replay"
        ])
      end)
      |> Jason.decode!()

    assert retry["status"] == "recorded"
    assert retry["outcome"]["status"] == "pending"
    assert replay["status"] == "recorded"

    replay_status =
      capture_io(fn -> Replay.run(["show", replay["outcome"]["replay_input_ref"]]) end)
      |> Jason.decode!()

    assert replay_status["execution_mode"] == "shadow"
    assert replay_status["source_input_ref"] == Inbox.ref(entry)
  end

  test "mutation identity comes only from a configured Slack operator" do
    configuration = %{slack: %{operators: ["U123"]}}

    assert {:ok, "slack:user:U123"} =
             OperatorSupport.authorized_actor(configuration, operator: "U123")

    assert {:error, :configured_slack_operator_required} =
             OperatorSupport.authorized_actor(configuration, operator: "U999")

    assert {:error, :configured_slack_operator_required} =
             OperatorSupport.authorized_actor(%{}, operator: "U123")
  end

  test "shared option parsing rejects duplicates and missing action identities" do
    assert {:ok, [config: "/tmp/runtime.yaml"], ["one"]} =
             OperatorSupport.parse(["one", "--config", "/tmp/runtime.yaml"], [config: :string], 1)

    assert {:error, :invalid_arguments} =
             OperatorSupport.parse(
               ["--config", "/one", "--config", "/two"],
               [config: :string],
               0
             )

    assert {:ok, nil} = OperatorSupport.configuration([])
    assert {:error, :configuration_path_required} = OperatorSupport.configuration([], true)

    assert {:ok, "action:one"} =
             OperatorSupport.required_option([action_ref: "action:one"], :action_ref)

    assert {:error, {:action_ref, :required}} = OperatorSupport.required_option([], :action_ref)

    assert {:error, :invalid_arguments} =
             OperatorSupport.parse(["one"], [config: :string], [0, 2])

    assert {:error, :configuration_path_required} =
             OperatorSupport.configuration(config: "")

    assert {:error, :configured_slack_operator_required} =
             OperatorSupport.authorized_actor(:invalid, [])
  end

  defp runtime_configuration!(options \\ []) do
    source = Path.expand("../../../testdata/release/responder-component.yaml", __DIR__)

    path =
      Path.join(
        System.tmp_dir!(),
        "responder-operator-#{System.unique_integer([:positive])}.yaml"
      )

    document =
      source
      |> File.read!()
      |> String.replace("__CONTROL_PLANE_PORT__", "4321")
      |> add_slack_configuration(Keyword.get(options, :slack_operator))

    File.write!(path, document)
    configuration = RuntimeConfiguration.load!(path)

    previous =
      Map.new(configuration, fn {key, _value} -> {key, Application.fetch_env(:responder, key)} end)

    on_exit(fn ->
      File.rm(path)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:responder, key, value, persistent: true)
        {key, :error} -> Application.delete_env(:responder, key, persistent: true)
      end)
    end)

    path
  end

  defp add_slack_configuration(document, nil), do: document

  defp add_slack_configuration(document, operator) do
    repositories =
      """
      repositories:
        responder:
          path: /tmp/responder-operator-repository
          github_repository: example/responder
          github_binding: responder-app
          base_branch: main
          conversation_policy:
            name: operator-conversation
            digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
          contributor_policy:
            name: operator-contributor
            digest: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
          schedule_policy:
            name: operator-schedule
            digest: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
      """

    String.replace(document, "repositories: {}", String.trim_trailing(repositories)) <>
      """

      slack:
        api_url: https://slack.com/api
        app_token_env: SLACK_APP_TOKEN
        bot_token_env: SLACK_BOT_TOKEN
        default_repository: responder
        identity:
          workspace_ref: T123
          bot_ref: A123
          bot_user_ref: U999
        incident_policy:
          name: operator-test
          digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        operators:
          - #{operator}
        watch_channels: []
      """
  end

  defp slack_input do
    SlackInput.new(%{
      actor: %{kind: :user, ref: "U123"},
      channel_ref: "C456",
      content: %{"slack_event_kind" => "message", "text" => "Investigate latency"},
      event_kind: :message,
      event_ref: "Ev-operator-mix-task",
      message_ref: "1788512400.000500",
      occurred_at: @occurred_at,
      revision: 1,
      thread_ref: "1788512390.000100",
      workspace_ref: "T123"
    })
  end

  defp work_profile! do
    assert {:ok, profile} =
             WorkProfile.new(%{
               policy: "operator-test-v1",
               policy_digest: String.duplicate("a", 64),
               repository_ref: "responder"
             })

    profile
  end
end
