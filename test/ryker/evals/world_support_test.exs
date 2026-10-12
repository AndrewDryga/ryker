defmodule Ryker.Evals.WorldSupportTest do
  use ExUnit.Case, async: false

  # Thousands of committed announcements were lost in a standalone paid campaign:
  # the normal test application had hidden absent PubSub and Bandit startup.
  test "standalone observations deliver committed announcements without starting Ryker" do
    script = """
    alias Ecto.Adapters.Postgres, as: Storage
    alias Mix.Tasks.Ryker.Eval
    alias Ryker.{PubSub, Repo}

    {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
    template = "ryker_test_eval_support_" <> String.replace(Ecto.UUID.generate(), "-", "")
    storage = Keyword.put(Repo.config(), :database, template)
    :ok = Storage.storage_up(storage)

    try do
      observations =
        for index <- 1..2 do
          observe = fn database ->
            {:ok, repo} = Repo.start_link(database: database, pool: DBConnection.ConnectionPool)

            try do
              topic = "eval-support-probe:" <> Integer.to_string(index)

              subscribed? =
                try do
                  PubSub.subscribe(topic) == :ok
                rescue
                  ArgumentError -> false
                end

              {:ok, :committed} =
                Repo.transaction(fn ->
                  :ok = Repo.after_commit(fn -> PubSub.broadcast(topic, {:committed, index}) end)
                  :committed
                end)

              announced? =
                receive do
                  {:committed, ^index} -> true
                after
                  200 -> false
                end

              %{
                status: :passed,
                subscribed?: subscribed?,
                announced?: announced?,
                clock?: :ets.whereis(Bandit.Clock) != :undefined,
                pubsub: Process.whereis(Ryker.PubSub.Server)
              }
            after
              Supervisor.stop(repo)
            end
          end

          {:ok, report} = Eval.run_world_observation_database(template, observe)
          report
        end

      [first, second] = observations

      receipt = %{
        announcements: Enum.map(observations, & &1.announced?),
        subscriptions: Enum.map(observations, & &1.subscribed?),
        date_caches: Enum.map(observations, & &1.clock?),
        idempotent_pubsub: is_pid(first.pubsub) and first.pubsub == second.pubsub,
        product_started: Enum.any?(Application.started_applications(), &(elem(&1, 0) == :ryker)),
        runtime_started: not is_nil(Process.whereis(Ryker.Runtime.Owner)) or
          not is_nil(Process.whereis(Ryker.Runtime.Supervisor)) or
          not is_nil(Process.whereis(Ryker.Supervisor)),
        databases_dropped: Enum.all?(observations, &is_nil(&1.database))
      }

      encoded_receipt = Jason.encode!(receipt)
      IO.puts(encoded_receipt)
    after
      :ok = Storage.storage_down(storage)
    end
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", script],
        env: [{"MIX_ENV", "test"}, {"RYKER_WORLD_EVAL", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert receipt["announcements"] == [true, true]
    assert receipt["subscriptions"] == [true, true]
    assert receipt["date_caches"] == [true, true]
    assert receipt["idempotent_pubsub"]
    assert receipt["databases_dropped"]
    refute receipt["product_started"]
    refute receipt["runtime_started"]
  end
end
