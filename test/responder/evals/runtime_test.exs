defmodule Responder.Evals.RuntimeTest do
  # An evaluation runs beside a production installation on the same host. The
  # whole point of this module is that it builds its world from the evaluation
  # environment and shipped defaults alone, so a run can never pick up the
  # installation's repositories, destinations or reviewed grants.
  use ExUnit.Case, async: false

  alias Responder.Defaults
  alias Responder.Evals.Runtime

  @certificates Path.join(System.tmp_dir!(), "responder-eval-runtime-certificates")
  @files %{
    "RESPONDER_WORKER_CA_FILE" => "ca.pem",
    "RESPONDER_WORKER_CA_KEY_FILE" => "ca-key.pem",
    "RESPONDER_WORKER_CERT_FILE" => "cert.pem",
    "RESPONDER_WORKER_KEY_FILE" => "key.pem"
  }

  setup do
    File.mkdir_p!(@certificates)
    Enum.each(@files, fn {_name, file} -> File.write!(Path.join(@certificates, file), "x") end)
    on_exit(fn -> File.rm_rf!(@certificates) end)

    Enum.each(environment(), fn {name, value} -> put_variable(name, value) end)
    :ok
  end

  test "an evaluation world is built from the evaluation environment alone" do
    assert {:ok, world} = Runtime.world()

    assert world.state_tools_endpoint == "https://eval-worker.example/v1/state-tools/mcp"
    assert world.state_tools_secret == "eval-state-tools-token-long-enough"
    assert world.state_tools.token == world.state_tools_secret
    assert world.state_tools.port == 4418
    assert byte_size(world.gateway.checkpoint_key) == 32
    assert world.gateway.public_url == "https://eval-worker.example"

    # The capability set is the shipped one the recorded catalogs were generated
    # against, never a list an installation happens to be running with.
    assert world.state_tools.capabilities == [:event_waits, :publication, :schedules]
    refute :emisar_approvals in world.state_tools.capabilities

    # Nothing an operator saved can reach the world, because the world carries
    # no place to put it: no repositories, destinations, policies or workspace.
    assert Enum.sort(Map.keys(world)) ==
             [:gateway, :state_tools, :state_tools_endpoint, :state_tools_secret]

    refute Map.has_key?(world.gateway, :work_profile)
    refute Map.has_key?(world.state_tools, :answer_authorizer)
    refute Map.has_key?(world.state_tools, :additional_tools)

    # An evaluation checkpoint is never scanned against deployment secrets,
    # because an isolated world holds none of them.
    assert world.gateway.checkpoint_secrets == []
  end

  test "an evaluation without a worker gateway is named rather than half-started" do
    Enum.each(Map.keys(@files), &System.delete_env/1)
    System.delete_env("RESPONDER_WORKER_PUBLIC_URL")

    assert Runtime.world() == {:error, :model_world_gateway_not_configured}
  end

  test "an unusable evaluation environment is reported with the input that is wrong" do
    System.put_env("RESPONDER_CHECKPOINT_KEY", "not-base64-for-thirty-two-bytes")

    assert {:error, {:model_eval_environment_invalid, message}} = Runtime.world()
    assert message =~ "RESPONDER_CHECKPOINT_KEY"
    refute message =~ "not-base64-for-thirty-two-bytes"
  end

  test "an evaluation Coop client waits exactly as long as the shipped default" do
    assert Runtime.receive_timeout_ms() == Defaults.fetch!(:coop).receive_timeout_ms
  end

  defp environment do
    Map.merge(
      %{
        "DATABASE_URL" => "ecto://responder:eval@127.0.0.1/responder_eval_test",
        "RESPONDER_CHECKPOINT_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
        "RESPONDER_STATE_TOOLS_TOKEN" => "eval-state-tools-token-long-enough",
        "RESPONDER_STATE_TOOLS_PORT" => "4418",
        "RESPONDER_WORKER_PUBLIC_URL" => "https://eval-worker.example"
      },
      Map.new(@files, fn {name, file} -> {name, Path.join(@certificates, file)} end)
    )
  end

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
