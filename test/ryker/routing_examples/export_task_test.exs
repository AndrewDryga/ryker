defmodule Ryker.RoutingExamples.ExportTaskTest do
  @moduledoc """
  `mix ryker.routing_examples` writes the file the Data retention page
  downloads. It runs as its own short-lived database client, so it is run
  the way an operator runs it, against a committed example.
  """
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL

  defmodule CommittedRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @at ~N[2026-09-27 12:00:00.000000]

  test "the export command writes each kept example as one line, without starting Ryker" do
    repo = start_committed_repo!()
    id = Ecto.UUID.generate()

    path =
      Path.join(System.tmp_dir!(), "routing-examples-#{System.unique_integer([:positive])}.jsonl")

    try do
      example!(repo, id)

      script = """
      repo_config = Application.fetch_env!(:ryker, Ryker.Repo)

      Application.put_env(
        :ryker,
        Ryker.Repo,
        Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
      )

      Mix.Task.run("ryker.routing_examples", ["--output", #{inspect(path)}])

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
      assert output =~ "Wrote 1 routing examples to #{path}"

      assert [line] = path |> File.read!() |> String.split("\n", trim: true)
      document = Jason.decode!(line)

      assert document["messages"] == [
               %{"role" => "user", "content" => ~s({"instructions":"Decide."})},
               %{"role" => "assistant", "content" => ~s({"action":"ignore"})}
             ]

      assert document["labels"]["example_id"] == id
    after
      SQL.query!(repo, "DELETE FROM routing_examples WHERE id = $1", [Ecto.UUID.dump!(id)])
      File.rm(path)
    end
  end

  defp example!(repo, id) do
    SQL.query!(
      repo,
      """
      INSERT INTO routing_examples
        (id, input_id, source_identity, transport, conversation_ref, execution_mode, policy,
         policy_digest, prompt, output_schema, answer, rejected_answers, decision, outcome, usage,
         decided_at, inserted_at, updated_at)
      VALUES ($1, $1, repeat('a', 64), 'slack', 'slack:T1:C1', 'live', 'ryker-admission',
              repeat('b', 64), $2, '{}', $3, '[]', '{"action":"ignore"}', '{}', '{}', $4, $4, $4)
      """,
      [Ecto.UUID.dump!(id), ~s({"instructions":"Decide."}), ~s({"action":"ignore"}), @at]
    )
  end

  defp start_committed_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)

    start_supervised!({CommittedRepo, config})
    CommittedRepo
  end
end
