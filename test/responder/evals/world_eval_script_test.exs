defmodule Responder.Evals.WorldEvalScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/elixir-world-eval.sh", __DIR__)
  @world_options ~w(--tag smoke --repeat 1 --paired-baseline --min-overall-pass-rate 1 --min-case-pass-rate 1)

  test "shards run at once, each on its own database, ports and public URL, and merge" do
    # 31 scenarios × 3 repeats × 2 lanes at ~93 seconds each was 4.8 hours,
    # because every observation ran in one VM behind one Repo and one worker
    # gateway port. The wrapper now runs the shards as separate VMs, so each
    # needs a campaign database and a listener pair nobody else is using — and
    # they must actually overlap: the fake shards below wait for each other to
    # start, so a wrapper that ran them one after another times out here.
    fixture = fixture!(shards: 3)

    assert {output, 0} =
             System.cmd(
               "bash",
               [@script, fixture.results | @world_options],
               env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", "4"}],
               stderr_to_stdout: true
             )

    calls = fixture.log |> File.read!() |> String.split("\n", trim: true)

    # The plan preview decides how many shards run: four were allowed, the
    # plan filled three, so three VMs start and none is empty.
    assert [preview] = Enum.filter(calls, &(&1 =~ "responder.eval world-shards"))
    assert preview =~ "world-shards --shards 4 --tag smoke --repeat 1 --paired-baseline"
    refute preview =~ "--min-overall-pass-rate"

    shards = shard_calls(calls)
    assert length(shards) == 3

    databases = Enum.map(shards, &field(&1, "db"))
    assert Enum.uniq(databases) == databases
    assert Enum.all?(databases, &(&1 =~ ~r/^responder_world_eval_\d+_\d+_\d+_s[123]$/))
    assert Enum.map(shards, &field(&1, "worker")) == ["44636", "44638", "44640"]
    assert Enum.map(shards, &field(&1, "state")) == ["44637", "44639", "44641"]

    assert Enum.map(shards, &field(&1, "url")) == [
             "https://eval.example:44636",
             "https://eval.example:44638",
             "https://eval.example:44640"
           ]

    assert Enum.all?(shards, &(field(&1, "world_eval") == "1"))

    for {shard, index} <- Enum.with_index(shards, 1) do
      assert shard =~ "--results #{fixture.shards}/shard-#{index}.json"
      assert shard =~ "--shard #{index}/3"
      assert shard =~ Enum.join(@world_options, " ")
      assert File.read!("#{fixture.shards}/shard-#{index}.log") =~ "shard #{index} running"
    end

    for database <- databases, command <- ["ecto.create", "ecto.migrate", "ecto.drop"] do
      assert Enum.any?(calls, &(field(&1, "db") == database and &1 =~ command)),
             "#{command} did not run for #{database}"
    end

    assert [merge] = Enum.filter(calls, &(&1 =~ "responder.eval world-merge"))

    assert merge =~
             "world-merge --results #{fixture.results} --paired-baseline" <>
               " --min-overall-pass-rate 1 --min-case-pass-rate 1" <>
               " #{fixture.shards}/shard-1.json #{fixture.shards}/shard-2.json" <>
               " #{fixture.shards}/shard-3.json"

    refute merge =~ "--tag"
    refute merge =~ "--repeat"

    # The campaign databases are dropped on the way out, after the merge that
    # may still name a preserved observation database copied from them.
    merge_at = Enum.find_index(calls, &(&1 =~ "world-merge"))
    assert merge_at < Enum.find_index(calls, &(&1 =~ "ecto.drop"))

    assert output =~ "shard 1/3"
    assert output =~ "shard 3/3"
  end

  test "a public URL without a port gets each shard's worker port" do
    fixture = fixture!(shards: 2, public_url: "https://eval.example/")

    assert {_output, 0} =
             System.cmd(
               "bash",
               [@script, fixture.results | @world_options],
               env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", "2"}],
               stderr_to_stdout: true
             )

    shards = fixture.log |> File.read!() |> String.split("\n", trim: true) |> shard_calls()

    assert Enum.map(shards, &field(&1, "url")) == [
             "https://eval.example:44636",
             "https://eval.example:44638"
           ]
  end

  test "a failed shard fails the run without a merge and still drops every campaign database" do
    # A shard that died left nothing to merge that would mean anything: a
    # partial matrix prints a pass rate that is not a measurement. The
    # remaining partials and logs stay on disk for inspection, the campaign
    # templates never hold custody and are always dropped.
    fixture = fixture!(shards: 3, shard_status: {2, 7})

    assert {output, status} =
             System.cmd(
               "bash",
               [@script, fixture.results | @world_options],
               env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", "3"}],
               stderr_to_stdout: true
             )

    assert status != 0
    calls = File.read!(fixture.log)
    refute calls =~ "world-merge"
    assert length(Regex.scan(~r/ecto\.drop/, calls)) == 3
    assert output =~ "shard 2/3 failed with status 7"
    assert output =~ "#{fixture.shards}/shard-2.log"
  end

  test "a failed merge fails the run after every campaign database is dropped" do
    fixture = fixture!(shards: 2, merge_status: 3)

    assert {_output, 3} =
             System.cmd(
               "bash",
               [@script, fixture.results | @world_options],
               env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", "2"}],
               stderr_to_stdout: true
             )

    assert length(Regex.scan(~r/ecto\.drop/, File.read!(fixture.log))) == 2
  end

  test "the wrapper refuses a shard count, port layout or option it cannot run" do
    fixture = fixture!(shards: 2)

    for shards <- ["0", "abc", "65"] do
      assert {output, 2} =
               System.cmd("bash", [@script, fixture.results | @world_options],
                 env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", shards}],
                 stderr_to_stdout: true
               )

      assert output =~ "RESPONDER_WORLD_EVAL_SHARDS must be between 1 and 64"
    end

    # Worker 4322 and state tools 4324 with two shards: shard 2's worker port
    # is shard 1's state-tools port. Refused before any database is created.
    assert {output, 2} =
             System.cmd("bash", [@script, fixture.results | @world_options],
               env:
                 fixture.env ++
                   [
                     {"RESPONDER_WORLD_EVAL_SHARDS", "2"},
                     {"RESPONDER_WORKER_PORT", "4322"},
                     {"RESPONDER_STATE_TOOLS_PORT", "4324"}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "shard ports overlap"

    assert {output, 2} =
             System.cmd("bash", [@script, fixture.results, "--unknown", "value"],
               env: fixture.env ++ [{"RESPONDER_WORLD_EVAL_SHARDS", "2"}],
               stderr_to_stdout: true
             )

    assert output =~ "unknown world option: --unknown"
    refute File.exists?(fixture.log)
  end

  defp field(call, name) do
    [_call, value] = Regex.run(~r/(?:^| )#{name}=(\S*)/, call)
    value
  end

  # Shards start at once and append to the fake's log in whatever order they
  # were scheduled, so the calls are read back in shard order.
  defp shard_calls(calls) do
    calls
    |> Enum.filter(&(&1 =~ "responder.eval world "))
    |> Enum.sort_by(fn call ->
      [_call, index] = Regex.run(~r{--shard (\d+)/}, call)
      String.to_integer(index)
    end)
  end

  defp fixture!(options) do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-world-eval-script-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    log = Path.join(root, "mix.log")
    history = Path.join(root, "history")
    File.mkdir_p!(bin)
    File.mkdir_p!(history)
    on_exit(fn -> File.rm_rf!(root) end)

    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/bin/sh
    printf 'world_eval=%s db=%s worker=%s state=%s url=%s :: %s\\n' \\
      "${RESPONDER_WORLD_EVAL:-}" "${PGDATABASE:-}" "${RESPONDER_WORKER_PORT:-}" \\
      "${RESPONDER_STATE_TOOLS_PORT:-}" "${RESPONDER_WORKER_PUBLIC_URL:-}" "$*" >> "$FAKE_MIX_LOG"
    case "$*" in
      *"responder.eval world-shards"*)
        i=1
        while [ "$i" -le "$FAKE_SHARD_COUNT" ]; do
          printf '{"observations":2,"shard":%s}\\n' "$i"
          i=$((i + 1))
        done
        exit 0
        ;;
      *"responder.eval world-merge"*) exit "$FAKE_MERGE_STATUS" ;;
      *"responder.eval world "*)
        shard=
        while [ $# -gt 0 ]; do
          case "$1" in --shard) shard=${2%%/*} ;; esac
          shift
        done
        echo "shard $shard running"
        : > "$FAKE_ROOT/started-$shard"
        waited=0
        while [ "$(ls "$FAKE_ROOT"/started-* | wc -l)" -lt "$FAKE_SHARD_COUNT" ]; do
          waited=$((waited + 1))
          if [ "$waited" -gt 100 ]; then
            echo "shard $shard never saw the others start" >&2
            exit 9
          fi
          sleep 0.1
        done
        status_variable="FAKE_EVAL_STATUS_$shard"
        eval "status=\\${$status_variable:-0}"
        exit "$status"
        ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(mix, 0o700)

    {failed_shard, failed_status} = Keyword.get(options, :shard_status, {0, 0})

    %{
      env: [
        {"FAKE_EVAL_STATUS_#{failed_shard}", Integer.to_string(failed_status)},
        {"FAKE_MERGE_STATUS", Integer.to_string(Keyword.get(options, :merge_status, 0))},
        {"FAKE_MIX_LOG", log},
        {"FAKE_ROOT", root},
        {"FAKE_SHARD_COUNT", Integer.to_string(Keyword.fetch!(options, :shards))},
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
        {"RESPONDER_STATE_TOOLS_PORT", "44637"},
        {"RESPONDER_WORKER_PORT", "44636"},
        {"RESPONDER_WORKER_PUBLIC_URL",
         Keyword.get(options, :public_url, "https://eval.example:44636")}
      ],
      log: log,
      results: Path.join(history, "world-test.json"),
      shards: Path.join(history, "world-test.shards")
    }
  end
end
