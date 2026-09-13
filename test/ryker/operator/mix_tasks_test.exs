defmodule Ryker.Operator.MixTasksTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ryker.{Doctor, OperatorSupport, Replay, Retry, Status}
  alias Mix.Tasks.Ryker.Failures, as: FailuresTask
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Runtime.Assembly
  alias Ryker.Settings
  alias Ryker.Slack.Input, as: SlackInput

  @occurred_at ~U[2026-09-04 08:00:00Z]

  test "read-only failure inspection starts only database dependencies" do
    script = """
    repo_config = Application.fetch_env!(:ryker, Ryker.Repo)

    Application.put_env(
      :ryker,
      Ryker.Repo,
      Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:ryker, :admission, :must_not_start)
    Application.put_env(:ryker, :work, :must_not_start)
    Application.put_env(:ryker, :delivery, :must_not_start)
    Mix.Task.run("ryker.failures", [])

    if Process.whereis(Ryker.Supervisor), do: System.halt(73)
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

  test "operator commands take no configuration path at all" do
    # Pointing an operator command at a file is how two sources of truth start.
    for task <- [FailuresTask, Doctor, Status] do
      assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
        task.run(["--config", "/etc/ryker/ryker-elixir.yaml"])
      end
    end
  end

  test "doctor and status read the installation's own durable settings" do
    settings!()

    doctor = capture_io(fn -> Doctor.run([]) end) |> Jason.decode!()
    status = capture_io(fn -> Status.run([]) end) |> Jason.decode!()

    assert doctor["status"] == "ok"
    assert status["preflight"]["status"] == "ok"
    assert is_map(status["failures"])
  end

  test "an uninitialized installation is reported rather than assumed" do
    assert_raise Mix.Error, ~r/settings_not_initialized/, fn -> Doctor.run([]) end

    assert_raise Mix.Error, ~r/settings_not_initialized/, fn ->
      Retry.run([
        "publication",
        "publication:not-retryable",
        "--operator",
        "U123",
        "--action-ref",
        "operator-action:retry"
      ])
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
    settings!()

    assert_raise Mix.Error, ~r/configured_slack_operator_required/, fn ->
      Retry.run([
        "admission",
        "ingress-input:any",
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
        "--operator",
        "U123",
        "--action-ref",
        "operator-action:replay"
      ])
    end
  end

  test "authorized retry and replay commands execute through audited custody" do
    settings!(slack_operator: "U123")
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

  test "mutation identity comes only from saved operator membership" do
    assert OperatorSupport.authorized_actor(operator: "U123") ==
             {:error, :settings_not_initialized}

    settings!(slack_operator: "U123")

    assert OperatorSupport.authorized_actor(operator: "U123") == {:ok, "slack:user:U123"}

    assert OperatorSupport.authorized_actor(operator: "U999") ==
             {:error, :configured_slack_operator_required}

    assert OperatorSupport.authorized_actor([]) ==
             {:error, :configured_slack_operator_required}
  end

  test "shared option parsing rejects duplicates and missing action identities" do
    assert {:ok, [operator: "U123"], ["one"]} =
             OperatorSupport.parse(["one", "--operator", "U123"], [operator: :string], 1)

    assert {:error, :invalid_arguments} =
             OperatorSupport.parse(
               ["--operator", "U1", "--operator", "U2"],
               [operator: :string],
               0
             )

    assert {:ok, "action:one"} =
             OperatorSupport.required_option([action_ref: "action:one"], :action_ref)

    assert {:error, {:action_ref, :required}} = OperatorSupport.required_option([], :action_ref)

    assert {:error, :invalid_arguments} =
             OperatorSupport.parse(["one"], [operator: :string], [0, 2])

    assert OperatorSupport.authorized_actor(:invalid) ==
             {:error, :configured_slack_operator_required}
  end

  # Operator commands read the installation's saved settings, so the fixture is
  # the settings themselves rather than a file the command is pointed at.
  defp settings!(options \\ []) do
    # An operator command runs with the deployment environment the release has.
    deployment = %{
      "DATABASE_URL" => "ecto://ryker:operator-test@127.0.0.1/ryker_operator_test",
      "RYKER_STATE_TOOLS_TOKEN" => "operator-test-state-tools-token"
    }

    Enum.each(deployment, fn {name, value} -> put_variable(name, value) end)

    actor = "control-plane:local"
    {:ok, saved} = Settings.initialize(actor)

    {:ok, saved} =
      Settings.put_repository(%{ref: "ryker"}, saved.installation.revision, actor)

    saved =
      case Keyword.get(options, :slack_operator) do
        nil ->
          saved

        operator ->
          {:ok, saved} =
            Settings.save_slack(
              %{
                enabled: false,
                workspace_ref: "T123",
                bot_ref: "A123",
                bot_user_ref: "U999",
                default_repository_ref: "ryker",
                operators: [operator]
              },
              saved.installation.revision,
              actor
            )

          saved
      end

    previous =
      Map.new(Assembly.managed_keys(), &{&1, Application.fetch_env(:ryker, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ryker, key, value, persistent: true)
        {key, :error} -> Application.delete_env(:ryker, key, persistent: true)
      end)
    end)

    saved
  end

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)

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
               repository_ref: "ryker"
             })

    profile
  end
end
