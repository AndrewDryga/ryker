defmodule Ryker.Evals.TestDatabaseIsolationTest do
  use ExUnit.Case, async: true

  @repository Path.expand("../../..", __DIR__)

  for exit_status <- [0, 37] do
    @exit_status exit_status
    test "the canonical gate isolates its database and preserves exit #{@exit_status}" do
      # A draft migration had already been applied to ryker_test. The full
      # gate skipped the edited migration and failed hundreds of unrelated tests.
      # Read the recipe with a clean make environment: inside `make check` this
      # child would otherwise inherit the parent's jobserver flags and warn.
      {commands, 0} =
        System.cmd("make", ["-s", "-n", "elixir-check"],
          cd: @repository,
          env: [{"MAKEFLAGS", nil}, {"MFLAGS", nil}, {"MAKELEVEL", nil}]
        )

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

  test "a Coop box without Docker tests against the sidecar its PGHOST names" do
    # On 2026-10-01 a box agent could not run one test all evening: this script
    # started the database with Docker, and a Coop box has none. Coop starts
    # compose.test.yml as the box's sidecar and names it in PGHOST instead.
    root = box_without_docker!()

    {_output, 0} =
      System.cmd(Path.join(root, "scripts/elixir-test.sh"), ["test/ryker/owning_test.exs"],
        cd: root,
        env: box_environment(root, %{"PGHOST" => "episode-db", "PGPORT" => "5432"})
      )

    assert root |> Path.join("calls.log") |> File.read!() |> String.split("\n", trim: true) == [
             "episode-db:5432|ecto.create --quiet",
             "episode-db:5432|do ecto.migrate --quiet + test test/ryker/owning_test.exs"
           ]
  end

  test "a fleet job with neither Docker nor services tests against a private server it removes" do
    # Ryker's draft-PR reviews of its own repository run `make dev-check` in the
    # fleet's trusted box, which gets no Docker and no sidecar. Without a server
    # of its own every such review failed before running a test.
    root = box_without_docker!()
    calls = Path.join(root, "calls.log")
    File.mkdir_p!(Path.join(root, "tmp"))

    executable!(root, "bin/initdb", """
    #!/bin/bash
    printf 'initdb|%s\\n' "$*" >> "#{calls}"
    """)

    executable!(root, "bin/pg_ctl", """
    #!/bin/bash
    printf 'pg_ctl|%s\\n' "$*" >> "#{calls}"
    """)

    {_output, 0} =
      System.cmd(Path.join(root, "scripts/elixir-test.sh"), ["test/ryker/owning_test.exs"],
        cd: root,
        env: box_environment(root, %{"PGHOST" => nil, "TMPDIR" => Path.join(root, "tmp")})
      )

    calls = calls |> File.read!() |> String.split("\n", trim: true)
    assert [initdb] = Enum.filter(calls, &String.starts_with?(&1, "initdb|"))
    assert initdb =~ "--username=postgres --auth=trust"
    assert [start] = Enum.filter(calls, &String.starts_with?(&1, "pg_ctl|start"))
    assert [_, port] = Regex.run(~r/-c port=(\d+)/, start)
    assert "127.0.0.1:#{port}|ecto.create --quiet" in calls
    assert "127.0.0.1:#{port}|do ecto.migrate --quiet + test test/ryker/owning_test.exs" in calls
    assert List.last(calls) =~ ~r/^pg_ctl\|stop .*--mode=immediate/
    assert File.ls!(Path.join(root, "tmp")) == []
  end

  test "with nothing to serve PostgreSQL the script stops before compiling anything" do
    root = box_without_docker!()

    {output, 1} =
      System.cmd(Path.join(root, "scripts/elixir-test.sh"), [],
        cd: root,
        env: box_environment(root, %{"PGHOST" => nil, "PGPORT" => nil}),
        stderr_to_stdout: true
      )

    assert output =~ "no docker, no PGHOST and no pg_ctl"
    refute File.exists?(Path.join(root, "calls.log"))
  end

  # A checkout whose PATH holds only what the script needs, so no Docker or
  # PostgreSQL is found wherever the host keeps its own.
  defp box_without_docker! do
    root = Path.join(System.tmp_dir!(), "test-database-box-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, "bin"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.join(@repository, "scripts/elixir-test.sh"),
      Path.join(root, "scripts/elixir-test.sh")
    )

    File.chmod!(Path.join(root, "scripts/elixir-test.sh"), 0o755)

    for tool <- ["dirname", "env", "mktemp", "rm", "cat"] do
      File.ln_s!(System.find_executable(tool), Path.join(root, "bin/#{tool}"))
    end

    executable!(root, "scripts/elixir-mix.sh", """
    #!/bin/bash
    printf '%s:%s|%s\\n' "$PGHOST" "$PGPORT" "$*" >> "#{Path.join(root, "calls.log")}"
    """)

    root
  end

  defp box_environment(root, overrides) do
    Map.merge(%{"PATH" => Path.join(root, "bin"), "RYKER_TEST_ISOLATED" => nil}, overrides)
    |> Enum.to_list()
  end

  defp executable!(root, path, text) do
    path = Path.join(root, path)
    File.write!(path, text)
    File.chmod!(path, 0o755)
  end
end
