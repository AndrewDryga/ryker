defmodule Responder.Delivery.OperatorTaskTest do
  use ExUnit.Case, async: false

  test "the operator command starts only database dependencies" do
    script = """
    repo_config = Application.fetch_env!(:responder, Responder.Repo)

    Application.put_env(
      :responder,
      Responder.Repo,
      Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:responder, :delivery, :must_not_start)
    Application.put_env(:responder, :webhooks, :must_not_start)
    Mix.Task.run("responder.delivery", ["list"])

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

    json = output |> String.split("\n", trim: true) |> List.last()
    assert {:ok, _items} = Jason.decode(json)
  end
end
