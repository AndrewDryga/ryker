defmodule Responder.Evals.MixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.Postgres, as: Storage
  alias Mix.Tasks.Responder.Eval
  alias Responder.Evals.{AdmissionCase, WorkCase, WorldCase, WorldSuite}
  alias Responder.Repo

  test "offline pack commands emit every sanitized case without a model" do
    assert_pack("admission-pack", AdmissionCase)
    assert_pack("work-pack", WorkCase)
    assert_pack("world-pack", WorldCase)
  end

  test "live commands fail closed on unknown arguments and unconfigured authority" do
    # Nothing reaches a model before the local arguments and the dedicated
    # evaluation authority have both been resolved.
    assert_raise Mix.Error, ~r/admission eval failed: :invalid_arguments/, fn ->
      Eval.run(["admission", "--config", "/tmp/responder.yaml"])
    end

    assert_raise Mix.Error, ~r/work eval failed: :invalid_arguments/, fn ->
      Eval.run(["work", "extra"])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--unknown", "value"])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--results", "relative.json"])
    end

    assert_raise Mix.Error, ~r/admission eval failed: :model_eval_policies_not_configured/, fn ->
      Eval.run(["admission"])
    end

    assert_raise Mix.Error, ~r/usage: mix responder.eval/, fn ->
      Eval.run(["unknown"])
    end
  end

  test "a failed observation still leaves every later observation to run" do
    # One failing repeat of one case marked 29 scenarios unrun and failed a gate
    # whose own thresholds tolerate a failure. The campaign used to stop at the
    # first observation that was not :passed because every observation shared
    # one database and a failure preserved it; each observation now owns its
    # database, so a failed repeat is the data the gate exists to collect.
    parent = self()

    plan =
      for scenario_id <- ["alert-world", "review-world"],
          repeat_index <- 1..3,
          do: %{scenario_id: scenario_id, lane: :candidate, repeat_index: repeat_index}

    reports =
      Eval.run_world_plan(
        plan,
        fn observation ->
          send(parent, {:model_called, observation.scenario_id, observation.repeat_index})

          status =
            if observation == %{scenario_id: "alert-world", lane: :candidate, repeat_index: 2},
              do: :failed,
              else: :passed

          Map.put(observation, :status, status)
        end,
        fn observation, _stopped ->
          flunk("a failed repeat skipped #{inspect(observation)}")
        end
      )

    assert Enum.map(reports, &Map.take(&1, [:scenario_id, :repeat_index])) ==
             Enum.map(plan, &Map.take(&1, [:scenario_id, :repeat_index]))

    assert Enum.count(reports, &(&1.status == :failed)) == 1
    refute Enum.any?(reports, &(&1.status == :unrun))

    for %{scenario_id: scenario_id, repeat_index: repeat_index} <- plan do
      assert_received {:model_called, ^scenario_id, ^repeat_index}
    end
  end

  test "a harness fault stops the observations after it" do
    # :unrun is the host saying the observation never reached a model at all —
    # the tool catalog did not match, the database would not migrate, the
    # gateway would not start. Every later observation would fault the same way,
    # so the campaign stops instead of spending the rest of the matrix on it.
    parent = self()
    plan = Enum.map(1..3, &%{scenario_id: "alert-world", lane: :candidate, repeat_index: &1})

    reports =
      Eval.run_world_plan(
        plan,
        fn observation ->
          send(parent, {:model_called, observation.repeat_index})

          Map.put(
            observation,
            :status,
            if(observation.repeat_index == 1, do: :passed, else: :unrun)
          )
        end,
        fn observation, stopped ->
          observation |> Map.put(:status, :unrun) |> Map.put(:stopped_after, stopped.repeat_index)
        end
      )

    assert Enum.map(reports, & &1.status) == [:passed, :unrun, :unrun]
    assert List.last(reports).stopped_after == 2
    assert_received {:model_called, 2}
    refute_received {:model_called, 3}
  end

  test "a case that passes two of its three repeats qualifies" do
    # The thresholds the gate is invoked with (--repeat 3 --min-case-pass-rate
    # 0.667) say two of three repeats is a pass, but summarize fails on any
    # unrun observation, so halting the campaign at the first failed repeat
    # failed the gate its own thresholds had already tolerated.
    assert {:ok, cases} = WorldCase.all()
    assert {:ok, plan} = WorldSuite.plan(Enum.take(cases, 1), %{repeat: 3})

    reports =
      Eval.run_world_plan(
        plan,
        fn observation ->
          %{
            failures: [],
            lane: observation.lane,
            repeat_index: observation.repeat_index,
            scenario_id: observation.scenario.id,
            status: if(observation.repeat_index == 2, do: :failed, else: :passed)
          }
        end,
        fn observation, _stopped ->
          flunk("a failed repeat skipped repeat #{observation.repeat_index}")
        end
      )

    # The single-case plan is measured against the per-case rate the gate uses;
    # the overall rate is lowered to match because one case is the whole matrix.
    assert {:ok, summary} =
             WorldSuite.summarize(reports, %{
               min_case_pass_rate: 2 / 3,
               min_overall_pass_rate: 2 / 3
             })

    assert summary.candidate.unrun == 0
    assert summary.passed?
  end

  test "a passed observation's database is dropped and a failed one is preserved and named" do
    # Every observation shared the campaign's database, so a failure had to stop
    # the run to keep the next model off the failed case's surviving custody.
    # The database is per observation now: a pass leaves nothing behind, and a
    # failure keeps exactly its own rows under a name the report carries.
    template = "responder_world_eval_template_#{System.unique_integer([:positive])}"
    assert :ok = Storage.storage_up(storage(template))
    on_exit(fn -> Storage.storage_down(storage(template)) end)
    query!(template, "CREATE TABLE custody (id integer)")

    assert {:ok, %{database: nil}} =
             Eval.run_world_observation_database(template, observe(:passed))

    assert_received {:observation_database, passed}
    assert Storage.storage_status(storage(passed)) == :down

    assert {:ok, %{database: failed}} =
             Eval.run_world_observation_database(template, observe(:failed))

    assert_received {:observation_database, ^failed}
    assert failed != passed
    assert Storage.storage_status(storage(failed)) == :up

    # The preserved database carries the template's migrated schema, not an
    # empty database and not the previous observation's.
    assert %{rows: [["custody"]]} = query!(failed, "SELECT to_regclass('custody')::text")
  end

  defp observe(status) do
    parent = self()

    fn database ->
      on_exit(fn -> Storage.storage_down(storage(database)) end)
      send(parent, {:observation_database, database})
      %{status: status}
    end
  end

  defp storage(database), do: Keyword.put(Repo.config(), :database, database)

  defp query!(database, statement) do
    {:ok, connection} =
      database |> storage() |> Keyword.drop([:pool, :pool_size]) |> Postgrex.start_link()

    result = Postgrex.query!(connection, statement, [])
    GenServer.stop(connection)
    result
  end

  defp assert_pack(command, case_module) do
    assert {:ok, cases} = case_module.all()

    documents =
      capture_io(fn -> Eval.run([command]) end)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(documents) == length(cases)

    assert Enum.all?(documents, fn document ->
             is_map(document) and
               is_binary(document["eval_id"] || get_in(document, ["scenario", "id"]))
           end)
  end
end
