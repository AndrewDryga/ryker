defmodule Responder.Evals.MixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.Postgres, as: Storage
  alias Mix.Tasks.Responder.Eval
  alias Responder.Evals.{AdmissionCase, WorkCase, WorldCase, WorldReport, WorldSuite}
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

  test "a shard names one slice of a count or is refused before anything runs" do
    # The matrix runs as N separate VMs, each handed `--shard I/N` by the
    # orchestrator. A malformed shard must be a usage error at the argument
    # boundary: an out-of-range slice that silently ran nothing, or ran
    # everything, would either leave observations out of the merged report or
    # count them twice.
    for shard <- ["3/2", "0/4", "1/0", "a/b", "2", "1/2/3", "-1/2", "1/-2", " 1/2"] do
      assert_raise Mix.Error, ~r{--shard must be I/N}, fn ->
        Eval.run(["world", "--results", "/absolute/world.json", "--shard", shard])
      end
    end

    # A well-formed shard passes argument validation and stops at the next
    # gate, the unconfigured evaluation authority, without reaching a model.
    assert_raise Mix.Error, ~r/world eval failed: :model_eval_policies_not_configured/, fn ->
      Eval.run(["world", "--results", "/absolute/world.json", "--shard", "2/4"])
    end
  end

  test "world-shards previews exactly the shards a plan fills" do
    # The orchestrator asks for this before it creates a database or binds a
    # port per shard, so a small plan (`--repeat 1 --case X`) never starts an
    # empty VM that would then fail for having nothing to observe.
    shards =
      world_shards([
        "--shards",
        "4",
        "--tag",
        "smoke",
        "--repeat",
        "1",
        "--paired-baseline"
      ])

    assert Enum.map(shards, & &1["shard"]) == [1, 2, 3, 4]
    assert Enum.sum(Enum.map(shards, & &1["observations"])) == 18
    assert Enum.all?(shards, &(rem(&1["observations"], 2) == 0))

    assert [%{"observations" => 1, "shard" => 1}] =
             world_shards([
               "--shards",
               "4",
               "--case",
               "ordinary-thread-question-gets-natural-answer",
               "--repeat",
               "1"
             ])

    assert_raise Mix.Error, ~r/world shards failed: :invalid_arguments/, fn ->
      Eval.run(["world-shards"])
    end

    assert_raise Mix.Error, ~r/world shards failed: :invalid_arguments/, fn ->
      Eval.run(["world-shards", "--shards", "0"])
    end

    assert_raise Mix.Error, ~r/world shards failed: :invalid_arguments/, fn ->
      Eval.run(["world-shards", "--shards", "2", "--min-overall-pass-rate", "1"])
    end
  end

  test "a merged report carries the summary a single run computes over the same results" do
    # Shards write partial results without a verdict; the thresholds belong to
    # the merged report. The merge must produce byte-for-byte the results and
    # summary one sequential run would have written, or --paired-baseline,
    # --min-case-pass-rate and the trend tooling would be reading a different
    # kind of report depending on how the matrix happened to be scheduled.
    root = report_root!()

    reports =
      for scenario_id <- ["case-a", "case-b"],
          repeat_index <- 1..2,
          lane <- [:baseline, :candidate] do
        status =
          if {scenario_id, repeat_index, lane} == {"case-a", 2, :candidate},
            do: :failed,
            else: :passed

        merge_report(scenario_id, repeat_index, lane, status)
      end

    thresholds = %{
      max_paired_regression: 0.5,
      min_case_pass_rate: 0.5,
      min_overall_pass_rate: 0.5,
      paired_baseline: true
    }

    single = Path.join(root, "single.json")
    assert {:ok, summary} = WorldSuite.summarize(reports, thresholds)
    assert :ok = WorldReport.write(single, reports, summary: summary)

    # Pairs stay together, and the shard order is not the plan order.
    {first, second} = Enum.split_with(reports, &(&1.repeat_index == 2))
    partials = [Path.join(root, "shard-1.json"), Path.join(root, "shard-2.json")]
    assert :ok = WorldReport.write(Enum.at(partials, 0), first, summary: nil)
    assert :ok = WorldReport.write(Enum.at(partials, 1), second, summary: nil)

    merged = Path.join(root, "merged.json")

    output =
      capture_io(fn ->
        Eval.run(
          [
            "world-merge",
            "--results",
            merged,
            "--paired-baseline",
            "--min-overall-pass-rate",
            "0.5",
            "--min-case-pass-rate",
            "0.5",
            "--max-paired-regression",
            "0.5"
          ] ++ partials
        )
      end)

    merged_document = merged |> File.read!() |> Jason.decode!()
    single_document = single |> File.read!() |> Jason.decode!()

    assert merged_document["results"] == single_document["results"]
    assert merged_document["summary"] == single_document["summary"]
    assert merged_document["kind"] == "responder_model_world"
    assert merged_document["version"] == 2
    assert {:ok, _generated_at, 0} = DateTime.from_iso8601(merged_document["generated_at"])
    assert Enum.sort(Map.keys(merged_document)) == Enum.sort(Map.keys(single_document))
    assert output =~ "world evals: 3/4 passed"
    assert output =~ ~s("world_summary")

    # The merged report is qualified exactly as a single run is: the same
    # thresholds fail it the same way, with a non-zero exit.
    assert_raise Mix.Error, ~r/model-world qualification failed/, fn ->
      capture_io(fn ->
        Eval.run(
          [
            "world-merge",
            "--results",
            merged,
            "--paired-baseline",
            "--min-overall-pass-rate",
            "1"
          ] ++
            partials
        )
      end)
    end
  end

  test "the merge names every preserved database the shards left behind" do
    # A failed observation keeps its database, and each shard announces its own
    # on the way out — into its own log. The operator reads the merged run, so
    # the merge repeats every announcement and the merged results carry the
    # names.
    root = report_root!()

    first = [
      merge_report("case-a", 1, :candidate, :failed)
      |> Map.put(:database, "responder_world_eval_1_o7"),
      merge_report("case-b", 1, :candidate, :passed) |> Map.put(:database, nil)
    ]

    second = [
      merge_report("case-a", 2, :candidate, :failed)
      |> Map.put(:database, "responder_world_eval_2_o3"),
      merge_report("case-b", 2, :candidate, :passed)
    ]

    partials = [Path.join(root, "shard-1.json"), Path.join(root, "shard-2.json")]
    assert :ok = WorldReport.write(Enum.at(partials, 0), first, summary: nil)
    assert :ok = WorldReport.write(Enum.at(partials, 1), second, summary: nil)
    merged = Path.join(root, "merged.json")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/model-world qualification failed/, fn ->
          Eval.run(["world-merge", "--results", merged] ++ partials)
        end
      end)

    assert output =~
             "preserving failed world database responder_world_eval_1_o7 for custody inspection" <>
               " (case-a candidate repeat 1)"

    assert output =~ "PGDATABASE=responder_world_eval_1_o7 MIX_ENV=test mix ecto.drop"
    assert output =~ "preserving failed world database responder_world_eval_2_o3"

    results = merged |> File.read!() |> Jason.decode!() |> Map.fetch!("results")

    assert Enum.map(results, &{&1["scenario_id"], &1["repeat_index"], &1["database"]}) == [
             {"case-a", 1, "responder_world_eval_1_o7"},
             {"case-a", 2, "responder_world_eval_2_o3"},
             {"case-b", 1, nil},
             {"case-b", 2, nil}
           ]

    refute Enum.any?(results, &(&1["scenario_id"] == "case-b" and Map.has_key?(&1, "database")))
  end

  test "the merge refuses partial results it cannot trust" do
    root = report_root!()
    partial = Path.join(root, "shard-1.json")
    assert :ok = WorldReport.write(partial, [merge_report("case-a", 1, :candidate, :passed)])
    merged = Path.join(root, "merged.json")

    assert_raise Mix.Error, ~r/world merge failed: :invalid_arguments/, fn ->
      Eval.run(["world-merge", "--results", merged])
    end

    assert_raise Mix.Error, ~r/world merge failed: :invalid_arguments/, fn ->
      Eval.run(["world-merge", "--results", merged, "relative.json"])
    end

    assert_raise Mix.Error, ~r/world merge failed: :invalid_arguments/, fn ->
      Eval.run(["world-merge", "--results", merged, "--repeat", "3", partial])
    end

    assert_raise Mix.Error, ~r/world merge failed: .*shard-missing\.json/, fn ->
      Eval.run(["world-merge", "--results", merged, Path.join(root, "shard-missing.json")])
    end

    # The same observation in two partials means two shards ran it, and the
    # report would count it twice.
    assert_raise Mix.Error, ~r/world merge failed: .*duplicate_observation/, fn ->
      capture_io(fn -> Eval.run(["world-merge", "--results", merged, partial, partial]) end)
    end

    refute File.exists?(merged)
  end

  defp world_shards(arguments) do
    capture_io(fn -> Eval.run(["world-shards" | arguments]) end)
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp report_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-world-merge-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp merge_report(scenario_id, repeat_index, lane, status) do
    %{
      deliveries: [],
      episode_id: "episode-#{scenario_id}-#{repeat_index}-#{lane}",
      failures: [],
      lane: lane,
      quality: %{reason: "judged", status: status},
      record_history: [],
      records: [],
      repeat_index: repeat_index,
      runtime: %{policy: "world-eval-v1", turns: [%{cost_usd: "0.42", input_tokens: 2_400}]},
      scenario_id: scenario_id,
      source_calls: [],
      status: status,
      turn_id: "turn-#{scenario_id}-#{repeat_index}-#{lane}"
    }
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
