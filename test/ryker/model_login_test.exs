defmodule Ryker.ModelLoginTest do
  @moduledoc """
  Signing the bundled worker in to a model account
  (`deploy/compose/coop/model-login.sh`), with a stand-in for `coop login`
  that deletes the account's sign-in as it starts, as the real one does, and
  then finishes or not.

  A login that did not finish left the worker signed out and took routing
  down on 2026-09-27.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../deploy/compose/coop/model-login.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "ryker-model-login-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    profile = Path.join([root, "agents", "codex", "profiles", "default"])
    File.mkdir_p!(profile)
    File.write!(Path.join(profile, "auth.json"), ~s({"token":"previous"}))

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    coop = Path.join(bin, "coop")

    File.write!(coop, """
    #!/bin/sh
    auth="$COOP_CONFIG_DIR/codex/profiles/default/auth.json"
    rm -f "$auth"
    [ "$LOGIN_OUTCOME" = finished ] || exit 130
    printf '{"token":"new"}' >"$auth"
    """)

    File.chmod!(coop, 0o755)
    %{root: root, auth: Path.join(profile, "auth.json"), bin: bin}
  end

  test "a login that does not finish puts the previous sign-in back", context do
    assert {out, 130} = login(context, "aborted")
    assert out =~ "the previous one was put back"
    assert File.read!(context.auth) == ~s({"token":"previous"})
  end

  test "a login that finishes keeps the new sign-in", context do
    assert {_out, 0} = login(context, "finished")
    assert File.read!(context.auth) == ~s({"token":"new"})
  end

  defp login(context, outcome) do
    System.cmd("sh", [@script, "codex"],
      env: [
        {"COOP_CONFIG_DIR", Path.join(context.root, "agents")},
        {"LOGIN_OUTCOME", outcome},
        {"PATH", context.bin <> ":" <> System.get_env("PATH")}
      ],
      stderr_to_stdout: true
    )
  end
end
