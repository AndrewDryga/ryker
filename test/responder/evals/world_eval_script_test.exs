defmodule Responder.Evals.WorldEvalScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/elixir-world-eval.sh", __DIR__)

  test "the isolated runner forwards qualification flags and drops the campaign database" do
    fixture = fixture!()

    assert {output, 0} =
             System.cmd(
               "bash",
               [
                 @script,
                 "/absolute/results.json",
                 "--tag",
                 "smoke",
                 "--repeat",
                 "1"
               ],
               env: fixture.env,
               stderr_to_stdout: true
             )

    assert output == ""
    calls = File.read!(fixture.log)
    assert calls =~ "world_eval=1"
    assert calls =~ "responder.eval world"
    assert calls =~ "--results /absolute/results.json --tag smoke --repeat 1"
    assert calls =~ "ecto.drop"
  end

  test "a failed world run still drops the campaign database it copies observations from" do
    # The campaign database is only the migrated template each observation is
    # copied from, and custody lives in the per-observation databases the eval
    # task preserves and names. Keeping the template on failure left one more
    # abandoned responder_world_eval_* database behind after every red run.
    fixture = fixture!("7")

    assert {output, 7} =
             System.cmd(
               "bash",
               [@script, "/absolute/results.json"],
               env: fixture.env,
               stderr_to_stdout: true
             )

    assert output == ""
    assert File.read!(fixture.log) =~ "ecto.drop"
  end

  defp fixture!(eval_status \\ "0") do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-world-eval-script-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    log = Path.join(root, "mix.log")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/bin/sh
    printf 'world_eval=%s %s\\n' "${RESPONDER_WORLD_EVAL:-}" "$*" >> "$FAKE_MIX_LOG"
    case "$*" in
      *"responder.eval world"*) exit "$FAKE_EVAL_STATUS" ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(mix, 0o700)

    %{
      env: [
        {"FAKE_EVAL_STATUS", eval_status},
        {"FAKE_MIX_LOG", log},
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
      ],
      log: log
    }
  end
end
