defmodule Ryker.Evals.TestDatabaseIsolationTest do
  use ExUnit.Case, async: true

  @repository Path.expand("../../..", __DIR__)

  for exit_status <- [0, 37] do
    @exit_status exit_status
    test "the canonical gate isolates its database and preserves exit #{@exit_status}" do
      # A draft migration had already been applied to ryker_test. The full
      # gate skipped the edited migration and failed hundreds of unrelated tests.
      {commands, 0} = System.cmd("make", ["-s", "-n", "elixir-check"], cd: @repository)

      command =
        commands
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "elixir-test.sh --check"))

      assert command
      root = Path.join(System.tmp_dir!(), "test-database-isolation-#{Ecto.UUID.generate()}")
      File.mkdir_p!(Path.join(root, "scripts"))
      File.mkdir_p!(Path.join(root, "bin"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.cp!(
        Path.join(@repository, "scripts/elixir-test.sh"),
        Path.join(root, "scripts/elixir-test.sh")
      )

      File.chmod!(Path.join(root, "scripts/elixir-test.sh"), 0o755)

      executable!(root, "bin/docker", """
      #!/bin/bash
      case "$*" in
        *'up --detach --wait episode-db') ;;
        *'port episode-db 5432') echo 127.0.0.1:5432 ;;
        *) exit 91 ;;
      esac
      """)

      executable!(root, "scripts/elixir-mix.sh", """
      #!/bin/bash
      printf '%s|%s\\n' "$PGDATABASE" "$*" >> "$ISOLATION_LOG"
      case "$*" in
        do*) exit "$ISOLATION_EXIT" ;;
        *) exit 0 ;;
      esac
      """)

      log = Path.join(root, "calls.log")

      {_output, status} =
        System.cmd("bash", ["-c", command],
          cd: root,
          env: [
            {"PATH", Path.join(root, "bin") <> ":" <> System.fetch_env!("PATH")},
            {"PGDATABASE", "inherited_database_must_not_be_touched"},
            {"RYKER_TEST_ISOLATED", "0"},
            {"ISOLATION_LOG", log},
            {"ISOLATION_EXIT", Integer.to_string(@exit_status)}
          ]
        )

      calls = File.read!(log) |> String.split("\n", trim: true)
      databases = Enum.map(calls, &(String.split(&1, "|", parts: 2) |> hd())) |> Enum.uniq()
      assert [database] = databases
      assert database =~ ~r/^ryker_test_\d+_\d+$/
      assert Enum.any?(calls, &String.ends_with?(&1, "|ecto.create --quiet"))
      assert Enum.any?(calls, &String.ends_with?(&1, "|ecto.drop --quiet"))
      assert Enum.any?(calls, &String.contains?(&1, "ecto.migrate --quiet + test"))
      assert status == @exit_status
    end
  end

  defp executable!(root, path, text) do
    path = Path.join(root, path)
    File.write!(path, text)
    File.chmod!(path, 0o755)
  end
end
