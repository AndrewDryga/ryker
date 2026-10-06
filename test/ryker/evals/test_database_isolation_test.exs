defmodule Ryker.Evals.TestDatabaseIsolationTest do
  use ExUnit.Case, async: true

  @repository Path.expand("../../..", __DIR__)

  for exit_status <- [0, 37] do
    @exit_status exit_status
    test "the canonical gate runs every test file once, each partition in a fresh database, and preserves exit #{@exit_status}" do
      # A draft migration had already been applied to ryker_test. The full
      # gate skipped the edited migration and failed hundreds of unrelated tests.
      # Since 2026-10-02 the async files run in one VM and the serial files are
      # dealt across others beside it, so each needs a database of its own, every
      # one is dropped, no file is lost or run twice, and one red VM is a red gate.
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
      File.mkdir_p!(Path.join(root, "test/ryker"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.cp!(
        Path.join(@repository, "scripts/elixir-test.sh"),
        Path.join(root, "scripts/elixir-test.sh")
      )

      File.chmod!(Path.join(root, "scripts/elixir-test.sh"), 0o755)

      for {name, use} <- [
            a: "use ExUnit.Case, async: true",
            b: "use Ryker.DataCase",
            c: "use Ryker.DataCase, async: true",
            d: "use ExUnit.Case, async: false",
            e: "use Ryker.DataCase"
          ] do
        File.write!(
          Path.join(root, "test/ryker/#{name}_test.exs"),
          "defmodule T do\n  #{use}\nend\n"
        )
      end

      executable!(root, "bin/docker", """
      #!/bin/bash
      case "$*" in
        *'up --detach --wait episode-db') ;;
        *'port episode-db 5432') echo 127.0.0.1:5432 ;;
        *) exit 91 ;;
      esac
      """)

      # Only the VM holding d_test.exs fails, as a real red gate usually does.
      executable!(root, "scripts/elixir-mix.sh", """
      #!/bin/bash
      printf '%s|%s\\n' "$PGDATABASE" "$*" >> "$ISOLATION_LOG"
      case "$*" in
        *'+ test '*d_test.exs*) exit "$ISOLATION_EXIT" ;;
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
            {"RYKER_TEST_PARTITIONS", "2"},
            {"ISOLATION_LOG", log},
            {"ISOLATION_EXIT", Integer.to_string(@exit_status)}
          ]
        )

      calls =
        File.read!(log) |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "|"))

      suites =
        for [database, "do ecto.create --quiet + ecto.migrate --quiet + test " <> files] <- calls,
            into: %{} do
          {String.replace(database, ~r/^ryker_test_\d+_\d+_/, ""),
           files |> String.split() |> Enum.filter(&String.ends_with?(&1, "_test.exs"))}
        end

      assert suites == %{
               "p0" => ["test/ryker/a_test.exs", "test/ryker/c_test.exs"],
               "p1" => ["test/ryker/b_test.exs", "test/ryker/e_test.exs"],
               "p2" => ["test/ryker/d_test.exs"]
             }

      databases = for [database, "do ecto.create" <> _] <- calls, do: database
      assert Enum.all?(databases, &(&1 =~ ~r/^ryker_test_\d+_\d+_p[012]$/))
      assert length(Enum.uniq(databases)) == 3
      dropped = for [database, "ecto.drop --quiet"] <- calls, do: database
      assert Enum.sort(dropped) == Enum.sort(databases)
      refute Enum.any?(calls, &(hd(&1) == "inherited_database_must_not_be_touched"))
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
             "episode-db:5432|do ecto.create --quiet + ecto.migrate --quiet + test test/ryker/owning_test.exs"
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

    assert "127.0.0.1:#{port}|do ecto.create --quiet + ecto.migrate --quiet + test test/ryker/owning_test.exs" in calls

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
