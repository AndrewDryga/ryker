defmodule Ryker.Improvement.EvalCasesTaskTest do
  @moduledoc """
  `mix ryker.eval_cases --output DIR` writes the files Memory › Feedback ›
  What to fix downloads. It runs as its own short-lived database client, so
  it is run the way a developer runs it, against a committed accepted case.
  """
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Ryker.Evals.WorldCase
  alias Ryker.Improvement.{Candidate, Export}

  defmodule CommittedRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @at ~N[2026-09-27 12:00:00.000000]
  @catalog "testdata/scenarios/va1-health-review-repairs-and-finishes/tool-catalog.json"

  test "the export command writes each accepted case as a world scenario, without starting Ryker" do
    repo = start_committed_repo!()
    id = Ecto.UUID.generate()
    root = Path.join(System.tmp_dir!(), "eval-cases-#{System.unique_integer([:positive])}")
    output = Path.join(root, "cases")

    try do
      candidate!(repo, id)

      script = """
      repo_config = Application.fetch_env!(:ryker, Ryker.Repo)

      Application.put_env(
        :ryker,
        Ryker.Repo,
        Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
      )

      Mix.Task.run("ryker.eval_cases", ["--output", #{inspect(output)}])

      if Process.whereis(Ryker.Supervisor), do: System.halt(73)
      """

      {log, status} =
        System.cmd(
          "mix",
          ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", script],
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      assert log =~ "Wrote 1 eval cases to #{output}"

      case_id =
        Export.case_id(%Candidate{id: id, decided_at: DateTime.from_naive!(@at, "Etc/UTC")})

      File.mkdir_p!(Path.join(output, "va1-health-review-repairs-and-finishes"))

      File.cp!(
        @catalog,
        Path.join([output, "va1-health-review-repairs-and-finishes", "tool-catalog.json"])
      )

      assert {:ok, scenario} = WorldCase.load(Path.join(output, case_id))
      assert [%{"payload" => %{"text" => "Is the staging database healthy?"}}] = scenario.events

      assert scenario.expect["quality_rubric"] == [
               %{"criterion" => "Checks the staging database, not production.", "weight" => 3}
             ]

      assert File.read!(Path.join([output, case_id, "PROVENANCE.md"])) =~
               "Before adding this case"
    after
      SQL.query!(repo, "DELETE FROM improvement_candidates WHERE id = $1", [Ecto.UUID.dump!(id)])
      File.rm_rf!(root)
    end
  end

  test "the export command needs somewhere to write" do
    {log, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "-e",
          ~S{Mix.Task.run("ryker.eval_cases", [])}
        ],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute status == 0
    assert log =~ "eval case export"
  end

  defp candidate!(repo, id) do
    evidence = %{
      "version" => 1,
      "request" => %{"kind" => "work", "channel" => "slack", "state" => "complete"},
      "events" => [
        %{
          "at" => "2026-09-27T11:00:00.000000Z",
          "actor" => %{"kind" => "user", "ref" => "UTASKPERSON"},
          "source" => %{"kind" => "slack", "ref" => "TTASKWORKSPACE"},
          "destination" => %{
            "transport" => "slack",
            "conversation_ref" => "slack:TTASKWORKSPACE:CTASKCHANNEL",
            "thread_ref" => "1790300000.000100"
          },
          "event_kind" => "message",
          "bot_user_ref" => nil,
          "text" => "Is the staging database healthy?"
        }
      ],
      "conversation" => [],
      "routing" => [],
      "feedback" => []
    }

    SQL.query!(
      repo,
      """
      INSERT INTO improvement_candidates
        (id, episode_id, request_ref, transport, conversation_ref, reasons, signal_count,
         first_signal_at, last_signal_at, status, decided_at, decided_by, case_evidence,
         expected, inserted_at, updated_at)
      VALUES ($1, $1, 'improvement-task:request', 'slack', 'slack:TTASKWORKSPACE:CTASKCHANNEL',
              ARRAY['frustrated'], 1, $2, $2, 'accepted', $2, 'control-plane:local', $3,
              'Checks the staging database, not production.', $2, $2)
      """,
      [Ecto.UUID.dump!(id), @at, Jason.encode!(evidence)]
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
