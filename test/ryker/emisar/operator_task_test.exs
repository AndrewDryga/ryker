defmodule Ryker.Emisar.OperatorTaskTest do
  use Ryker.DataCase, async: false

  alias Mix.Tasks.Ryker.EmisarApproval

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Shell.Process.flush()

    on_exit(fn ->
      Mix.Shell.Process.flush()
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "list is read-only and reports the durable blocked-monitor inventory" do
    EmisarApproval.run(["list"])

    assert_receive {:mix_shell, :info, [document]}
    assert Jason.decode!(document) == []

    assert_raise Mix.Error, ~r/usage: mix ryker.emisar_approval/, fn ->
      EmisarApproval.run(["approve", "apr-1"])
    end
  end

  test "show and rearm fail closed for unknown approval custody" do
    assert_raise Mix.Error, ~r/emisar_approval_not_found/, fn ->
      EmisarApproval.run(["show", "production/missing-approval"])
    end

    assert_raise Mix.Error, ~r/emisar_approval_not_found/, fn ->
      EmisarApproval.run(["rearm", "production/missing-approval"])
    end

    assert_raise Mix.Error, ~r/invalid_emisar_approval_operator/, fn ->
      EmisarApproval.run(["show", ""])
    end
  end

  test "the operator command starts only database dependencies" do
    script = """
    repo_config = Application.fetch_env!(:ryker, Ryker.Repo)

    Application.put_env(
      :ryker,
      Ryker.Repo,
      Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:ryker, :emisar, :must_not_start)
    Application.put_env(:ryker, :slack, :must_not_start)
    Mix.Task.run("ryker.emisar_approval", ["list"])

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

    json = output |> String.split("\n", trim: true) |> List.last()
    assert {:ok, _items} = Jason.decode(json)
  end
end
