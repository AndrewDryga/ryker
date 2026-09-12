defmodule Responder.ReleaseTest do
  use Responder.DataCase, async: false

  alias Responder.Release

  test "the Elixir release preserves import history without shipping retired Go migration commands" do
    # Removing the Go gates left their obsolete importer and rollback command in
    # every release. Historical provenance is still used by retention and records.
    for module <- [
          Mix.Tasks.Responder.Cutover,
          Responder.Cutover.Importer,
          Responder.Cutover.Ledger,
          Responder.Cutover.LegacySchema,
          Responder.Cutover.LegacySnapshot,
          Responder.Cutover.Manifest,
          Responder.Cutover.Rollback
        ] do
      refute Code.ensure_loaded?(module)
    end

    assert Code.ensure_loaded?(Responder.Cutover.Item)
    assert Code.ensure_loaded?(Responder.Cutover.Run)
  end

  test "retained historical schemas do not expose retired import write paths" do
    # The removed importer was their sole caller; leaving these writes behind
    # made an obsolete migration look like a supported runtime operation.
    for {module, operation, arity} <- [
          {Responder.State.MemoryEntryChangeset, :cutover, 1},
          {Responder.State.BehaviorChangeset, :cutover, 1},
          {Responder.State.ScheduleChangeset, :cutover, 1},
          {Responder.State.RecordChangeset, :cutover, 1},
          {Responder.Episodes.EpisodeChangeset, :bind_cutover, 2}
        ] do
      assert Code.ensure_loaded?(module)
      refute function_exported?(module, operation, arity)
    end
  end

  test "production defaults to operational logging instead of debug SQL output" do
    configuration =
      Path.expand("../../config/prod.exs", __DIR__)
      |> Config.Reader.read!()

    assert get_in(configuration, [:logger, :level]) == :info
  end

  test "the production release is self-contained and Unix executable" do
    release = Mix.Project.config() |> Keyword.fetch!(:releases) |> Keyword.fetch!(:responder)

    assert release[:include_executables_for] == [:unix]
    assert release[:applications][:runtime_tools] == :permanent
    assert hd(release[:steps]) == :assemble
    assert List.last(release[:steps]) == :tar
    assert Enum.any?(release[:steps], &is_function(&1, 1))

    mixfile = File.read!(Path.expand("../../mix.exs", __DIR__))
    checker = File.read!(Path.expand("../../scripts/check-elixir-release.sh", __DIR__))

    for path <- ~w(
      README.md
      deploy/nginx/responder.conf
      deploy/systemd/responder.service
      deploy/systemd/responder.env.example
      docs/elixir-ingress-admission.md
      docs/operations.md
      docs/releasing.md
    ) do
      assert mixfile =~ path
      assert checker =~ path
    end

    assert checker =~ ~s($scratch/share/responder/$asset)
  end

  test "the release gate builds and inspects the Elixir archive" do
    makefile = File.read!(Path.expand("../../Makefile", __DIR__))

    assert makefile =~ ~r/^elixir-release:/m
    assert makefile =~ ~r/^elixir-release-check: elixir-release$/m
    assert makefile =~ "scripts/check-elixir-release.sh"
    assert makefile =~ ~r/^elixir-install: elixir-release-check$/m
    assert makefile =~ "scripts/install-elixir-release.sh"
    assert makefile =~ ~r/^elixir-activate:$/m
    assert makefile =~ "scripts/activate-elixir-release.sh"
    assert makefile =~ ~r/^elixir-candidate-check: elixir-release-check$/m
    assert makefile =~ "scripts/check-elixir-candidate.sh"
    assert makefile =~ "scripts/elixir-release-version.sh"
    assert makefile =~ "RESPONDER_ELIXIR_VERSION="

    # The release recipe must never clean. `mix clean` there once erased the dev
    # and test BEAM files beneath a running VM, and cleaning was also what hid
    # the real hazard: the version lives in the .app file, Mix rewrites that
    # only when mix.exs or the ebin directory changed, and a task that already
    # ran inside one `mix do` chain is skipped — so the archive silently carried
    # the previous commit's version. A forced compile.app in its own invocation
    # stamps the exact commit, and cleaning nothing cannot erase another
    # environment. A full rebuild per deploy cost sixteen seconds; this costs six.
    release_recipe = recipe!(makefile, "elixir-release")
    refute release_recipe =~ "clean"
    assert release_recipe =~ "scripts/elixir-mix.sh compile.app --force"
    assert release_recipe =~ "scripts/elixir-mix.sh release responder --overwrite"

    version_script = File.read!(Path.expand("../../scripts/elixir-release-version.sh", __DIR__))
    assert version_script =~ "describe --exact-match --tags"
    assert version_script =~ ~s(cat-file -t "$tag")

    release_workflow = File.read!(Path.expand("../../.github/workflows/release.yml", __DIR__))
    assert release_workflow =~ "erlef/setup-beam@"
    assert release_workflow =~ "make elixir-release-check"
    assert release_workflow =~ "_elixir_linux_amd64.tar.gz"
    assert release_workflow =~ "sha256sum"
    assert release_workflow =~ "cosign sign-blob"
    assert release_workflow =~ "install-elixir-release.sh"

    mixfile = File.read!(Path.expand("../../mix.exs", __DIR__))
    assert mixfile =~ "System.get_env(\"RESPONDER_ELIXIR_VERSION\")"
    assert mixfile =~ "RESPONDER_ELIXIR_VERSION is required for production builds"
  end

  test "the documented production install authenticates every executable release helper" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))
    operations = File.read!(Path.expand("../../docs/operations.md", __DIR__))

    for document <- [readme, operations],
        helper <- ~w(install-elixir-release.sh check-elixir-release.sh activate-elixir-release.sh) do
      assert document =~ helper
    end

    for document <- [readme, operations] do
      assert document =~
               "for helper in install-elixir-release.sh check-elixir-release.sh activate-elixir-release.sh"

      assert document =~ ~s(awk -v file="$helper" '$2 == file { print }' checksums.txt)
      assert document =~ "chmod 0755 \"$helper\""
    end
  end

  test "the canonical deploy path installs and restarts only the Elixir PostgreSQL service" do
    deploy = File.read!(Path.expand("../../scripts/deploy.sh", __DIR__))
    operations = File.read!(Path.expand("../../docs/operations.md", __DIR__))

    assert deploy =~ "make elixir-candidate-check"
    assert deploy =~ "scripts/install-elixir-release.sh"
    assert deploy =~ "/readyz"
    assert deploy =~ ~S|installed_version=$("$prefix/current/bin/responder" version)|
    assert deploy =~ ~S|scripts/check-running-elixir-release.sh "$health_url" "$version"|
    refute deploy =~ ~S|installed_version=$($prefix/current/bin/responder version)|
    refute deploy =~ "responder-$sha"

    # One script owns deployment on both hosts. Every macOS deploy used to be a
    # hand-written throwaway activation helper because this script required
    # systemd, and a helper reused or mistyped once left production down. The
    # host branch selects a service manager; it never selects a second path.
    assert deploy =~ "systemctl restart"
    assert deploy =~ "launchctl bootstrap"
    assert deploy =~ "deploy/launchd/responder.plist.template"

    launchd = File.read!(Path.expand("../../deploy/launchd/responder.plist.template", __DIR__))
    unit = File.read!(Path.expand("../../deploy/systemd/responder.service", __DIR__))

    for definition <- [launchd, unit] do
      assert definition =~ "Responder.Release.migrate()"
      assert definition =~ "bin/responder"
    end

    # A Responder deploy never installs, upgrades or restarts a Coop worker;
    # production workers are enrolled through the outbound fleet protocol.
    refute deploy =~ "coop"
    refute launchd =~ "coop"

    assert operations =~ "Elixir/PostgreSQL"
    assert operations =~ "scripts/deploy.sh"
    refute operations =~ "responder bootstrap-coop"
    refute operations =~ "responder serve"
    refute operations =~ "State is one owner-private SQLite database"
  end

  test "the running release proof reads identity from the serving process" do
    checker = Path.expand("../../scripts/check-running-elixir-release.sh", __DIR__)
    version = "0.1.0-g" <> String.duplicate("c", 40)

    assert {output, 0} = run_running_release_check(checker, version, version)
    assert output == "running responder release: #{version}\n"

    assert {output, status} = run_running_release_check(checker, version, "0.1.0-stale")
    assert status != 0
    assert output =~ "running release reports '0.1.0-stale'"

    assert {output, status} = run_running_release_check(checker, version, nil)
    assert status != 0
    assert output =~ "did not report exactly one release identity"
  end

  test "the installer rejects different archive bytes under one release identity" do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-release-collision-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    version = "0.1.0-g" <> String.duplicate("a", 40)
    first = fake_release_archive!(root, "first", version)
    second = fake_release_archive!(root, "second", version)
    prefix = Path.join(root, "install")
    installer = Path.expand("../../scripts/install-elixir-release.sh", __DIR__)
    first_sha256 = file_sha256(first)
    second_sha256 = file_sha256(second)

    assert {_output, 0} =
             System.cmd(installer, [first, version, first_sha256, prefix, "--local-build"])

    assert {output, status} =
             System.cmd(installer, [second, version, second_sha256, prefix, "--local-build"],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "release identity collision"
    assert File.read!(Path.join([prefix, "releases", version, "payload.txt"])) == "first"
  end

  test "the archive checker authenticates bytes before extracting or executing them" do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-release-authentication-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    version = "0.1.0-g" <> String.duplicate("b", 40)
    archive = fake_release_archive!(root, "untrusted", version)
    checker = Path.expand("../../scripts/check-elixir-release.sh", __DIR__)

    assert {output, status} =
             System.cmd(
               checker,
               [archive, version, String.duplicate("0", 64), "--archive-only"],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "archive SHA-256 does not match trusted digest"
  end

  test "the service migrates before starting the assembled release" do
    service = File.read!(Path.expand("../../deploy/systemd/responder.service", __DIR__))
    environment = File.read!(Path.expand("../../deploy/systemd/responder.env.example", __DIR__))
    nginx = File.read!(Path.expand("../../deploy/nginx/responder.conf", __DIR__))

    # There is no application configuration file to point the unit at: product
    # settings live in PostgreSQL and the environment carries only deployment
    # connections and credentials.
    refute service =~ "RESPONDER_ELIXIR_CONFIG"
    assert service =~ "ExecStartPre=/usr/local/lib/responder/current/bin/responder eval"
    assert service =~ "Responder.Release.migrate()"
    assert service =~ "ExecStart=/usr/local/lib/responder/current/bin/responder start"
    # RELEASE_DISTRIBUTION=none makes `bin/responder stop` fail before it can
    # reach the live node. systemd already owns the foreground BEAM PID and must
    # deliver SIGTERM directly so ordinary replacement does not wait for its
    # stop timeout on every release.
    refute service =~ "ExecStop="
    assert service =~ "KillSignal=SIGTERM"
    refute service =~ "Requires=coop-responder.service"
    refute service =~ "After=coop-responder.service"
    refute service =~ "/usr/local/bin/responder serve"

    for name <- ~w(
      DATABASE_URL
      RESPONDER_CHECKPOINT_KEY
      RESPONDER_STATE_TOOLS_TOKEN
      SLACK_BOT_TOKEN
      SLACK_APP_TOKEN
      EMISAR_API_TOKEN
      GITHUB_APP_ID
      GITHUB_APP_PRIVATE_KEY
      GITHUB_WEBHOOK_SECRET
      RESPONDER_WEBHOOK_SECRET_NAMES
    ) do
      assert environment =~ "#{name}="
    end

    assert nginx =~ "location = /v1/github"
    assert nginx =~ "proxy_pass http://127.0.0.1:4319"
    assert nginx =~ "location /v1/hooks/"
    assert nginx =~ "proxy_pass http://127.0.0.1:4320"
    refute nginx =~ "127.0.0.1:8080"
  end

  test "the candidate boots the packaged release with no configuration file at all" do
    candidate = File.read!(Path.expand("../../scripts/check-elixir-candidate.sh", __DIR__))

    assert candidate =~ "pg_dump --format=custom"
    assert candidate =~ "pg_restore --list"
    assert candidate =~ "pg_restore --exit-on-error"
    assert candidate =~ "run_candidate restored"

    # A clean install must start its local setup from the database and the
    # bootstrap environment alone.
    refute candidate =~ "RESPONDER_ELIXIR_CONFIG"
    refute candidate =~ "configuration_template"
    assert candidate =~ "DATABASE_URL=$candidate_database_url"
    assert candidate =~ "RESPONDER_CONTROL_PORT=$candidate_port"

    refute File.exists?(Path.expand("../../config/responder-elixir.example.yaml", __DIR__))
    refute File.exists?(Path.expand("../../testdata/release/responder-component.yaml", __DIR__))
  end

  test "release migration entrypoints are idempotent and rollback is exact" do
    migrations = Release.migrations(log: false)

    assert migrations != []

    assert Enum.all?(migrations, fn {state, version, name} ->
             state == :up and is_integer(version) and version > 0 and is_binary(name)
           end)

    assert Release.migrate(log: false) == []
    assert Release.migrations(log: false, prefix: "public") == migrations

    latest = migrations |> Enum.map(&elem(&1, 1)) |> Enum.max()

    assert_raise ArgumentError,
                 ~r/latest applied migration .* does not match expected/,
                 fn -> Release.rollback(latest - 1, log: false) end
  end

  test "release migration entrypoints reject unsafe operator arguments" do
    assert_raise ArgumentError, ~r/positive integer/, fn -> Release.rollback(0) end
    assert_raise ArgumentError, ~r/must be a keyword/, fn -> Release.migrations(%{}) end

    assert_raise ArgumentError, ~r/unique known keys/, fn ->
      Release.migrations(log: false, log: :info)
    end

    assert_raise ArgumentError, ~r/unique known keys/, fn ->
      Release.migrations(unknown: true)
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      Release.migrations(pool_size: 1)
    end

    for options <- [[prefix: "Public"], [log: :silent], [repo: "Responder.Repo"]] do
      assert_raise ArgumentError, ~r/options are invalid/, fn ->
        Release.migrations(options)
      end
    end

    assert_raise ArgumentError, ~r/migrations path must be absolute/, fn ->
      Release.migrations(migrations_path: "relative/migrations")
    end
  end

  defp fake_release_archive!(root, name, version) do
    source = Path.join(root, name)
    File.mkdir_p!(Path.join(source, "bin"))

    executable = Path.join(source, "bin/responder")
    File.write!(executable, "#!/bin/sh\nprintf 'responder #{version}\\n'\n")
    File.chmod!(executable, 0o755)

    migration =
      Path.join([
        source,
        "lib",
        "responder-#{version}",
        "priv",
        "repo",
        "migrations",
        "20260830000100_finalize_elixir_product_schema.exs"
      ])

    File.mkdir_p!(Path.dirname(migration))
    File.write!(migration, "# fixture migration\n")
    runtime = Path.join([source, "releases", version, "runtime.exs"])
    File.mkdir_p!(Path.dirname(runtime))
    File.write!(runtime, "# fixture runtime\n")

    for asset <- ~w(
          README.md
          deploy/nginx/responder.conf
          deploy/systemd/responder.service
          deploy/systemd/responder.env.example
          docs/elixir-ingress-admission.md
          docs/operations.md
          docs/releasing.md
        ) do
      path = Path.join([source, "share", "responder", asset])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fixture #{asset}\n")
    end

    File.write!(Path.join(source, "payload.txt"), name)

    archive = Path.join(root, "#{name}.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", archive, "-C", source, "."])
    archive
  end

  # The recipe for one target: everything between its rule line and the next
  # blank line, so an assertion about the release build cannot be satisfied by
  # an unrelated target elsewhere in the Makefile.
  defp recipe!(makefile, target) do
    [_before, after_rule] = String.split(makefile, "\n#{target}:", parts: 2)
    [recipe | _rest] = String.split(after_rule, "\n\n", parts: 2)
    recipe
  end

  defp run_running_release_check(checker, expected_version, served_version) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        version_header =
          if served_version,
            do: "x-responder-version: #{served_version}\r\n",
            else: ""

        response =
          "HTTP/1.1 200 OK\r\n" <>
            version_header <>
            "content-length: 6\r\nconnection: close\r\n\r\nready\n"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end)

    result =
      System.cmd(
        checker,
        ["http://127.0.0.1:#{port}", expected_version],
        stderr_to_stdout: true
      )

    Task.await(server, 5_000)
    :gen_tcp.close(listener)
    result
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
