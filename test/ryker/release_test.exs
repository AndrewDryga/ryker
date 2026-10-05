defmodule Ryker.ReleaseTest do
  use Ryker.DataCase, async: false

  import Ryker.TestHelpers, only: [digest: 1]

  import Ecto.Query

  alias Ryker.CoopFleet.ControlPlane
  alias Ryker.Release

  @root Path.expand("../..", __DIR__)

  test "production defaults to operational logging instead of debug SQL output" do
    configuration =
      Path.expand("../../config/prod.exs", __DIR__)
      |> Config.Reader.read!()

    assert get_in(configuration, [:logger, :level]) == :info
  end

  test "the production release is self-contained and Unix executable" do
    release = Mix.Project.config() |> Keyword.fetch!(:releases) |> Keyword.fetch!(:ryker)

    assert release[:include_executables_for] == [:unix]
    assert release[:applications][:runtime_tools] == :permanent
    assert hd(release[:steps]) == :assemble
    assert List.last(release[:steps]) == :tar
    assert Enum.any?(release[:steps], &is_function(&1, 1))

    # One manifest names the operator assets: the build step copies it, the
    # archive check reads it, and the image build has to carry it. Three
    # hand-kept copies of that list once drifted apart silently.
    assets =
      "release-assets.txt"
      |> read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    assert assets != []

    for path <- assets do
      assert File.exists?(Path.join(@root, path)),
             "#{path} is listed in release-assets.txt but does not exist"
    end

    for path <- ~w(
      README.md
      compose.yml
      install.sh
      Dockerfile
      deploy/compose/entrypoint.sh
      deploy/nginx/ryker.conf
      docs/elixir-ingress-admission.md
      docs/operations.md
      docs/releasing.md
      scripts/compose.sh
    ) do
      assert path in assets
    end

    assert read!("mix.exs") =~ "release-assets.txt"
    assert read!("Dockerfile") =~ "release-assets.txt"

    checker = read!("scripts/check-elixir-release.sh")
    assert checker =~ "release-assets.txt"
    assert checker =~ ~s($scratch/share/ryker/$asset)
    assert checker =~ "RYKER_CREDENTIAL_KEY="
  end

  test "the release gate builds and inspects the Elixir archive" do
    makefile = read!("Makefile")

    assert makefile =~ ~r/^elixir-release:/m
    assert makefile =~ ~r/^elixir-release-check: elixir-release$/m
    assert makefile =~ "scripts/check-elixir-release.sh"
    assert makefile =~ ~r/^release-dist: elixir-release-check$/m
    assert makefile =~ "scripts/elixir-release-version.sh"
    assert makefile =~ "RYKER_ELIXIR_VERSION="

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
    assert release_recipe =~ "scripts/elixir-mix.sh release ryker --overwrite"

    version_script = read!("scripts/elixir-release-version.sh")
    assert version_script =~ "describe --exact-match --tags"
    assert version_script =~ ~s(cat-file -t "$tag")

    # CI and the release workflow package the archive through the one
    # release-dist target instead of two hand-copied install lists.
    for workflow <- [".github/workflows/ci.yml", ".github/workflows/release.yml"] do
      content = read!(workflow)
      assert content =~ "erlef/setup-beam@"
      assert content =~ "make release-dist"
      assert content =~ "scripts/check-release.sh dist"
      refute content =~ "install-elixir-release.sh"
    end

    release_workflow = read!(".github/workflows/release.yml")
    assert release_workflow =~ "_elixir_linux_amd64.tar.gz"
    assert release_workflow =~ "cosign sign-blob"

    mixfile = read!("mix.exs")
    assert mixfile =~ "System.get_env(\"RYKER_ELIXIR_VERSION\")"
    assert mixfile =~ "RYKER_ELIXIR_VERSION is required for production builds"
  end

  test "the documented production install has one Compose path" do
    readme = read!("README.md")
    operations = read!("docs/operations.md")

    for document <- [readme, operations] do
      assert document =~ "./install.sh"
      assert document =~ "scripts/compose.sh"
      refute document =~ "install-elixir-release.sh"
      refute document =~ "activate-elixir-release.sh"
      refute document =~ "elixir-install"
      refute document =~ "systemctl"
      refute document =~ "launchctl"
    end

    # The bare-host path was retired on 2026-09-25; a file from it reappearing
    # would be a second deployment path with nothing running it.
    for retired <- ~w(
      scripts/install-elixir-release.sh
      scripts/activate-elixir-release.sh
      scripts/check-running-elixir-release.sh
      scripts/check-elixir-candidate.sh
      deploy/launchd
      deploy/systemd
      config/ryker-elixir.example.yaml
      testdata/release/ryker-component.yaml
    ) do
      refute File.exists?(Path.join(@root, retired)),
             "#{retired} belongs to the retired bare-host path"
    end
  end

  test "scripts/deploy.sh is the Compose deploy of HEAD and touches nothing else" do
    deploy = read!("scripts/deploy.sh")
    operations = read!("docs/operations.md")

    # scripts/deploy_test.sh proves the behaviour against a fake Docker and a
    # fake control plane; this holds the shape the documentation promises.
    assert deploy =~ "git worktree add --detach"
    assert deploy =~ "pg_dump -U ryker -d ryker --format=custom"
    assert deploy =~ "\n  \"${compose[@]}\" up --detach --no-build --wait "
    assert deploy =~ "--no-deps ryker"
    assert deploy =~ "x-ryker-version"
    assert deploy =~ "--allow-not-main"
    assert deploy =~ ~s(--env-file "$env_file")
    assert read!("Makefile") =~ ~r/^deploy-check:\n\tscripts\/deploy_test\.sh$/m

    # A Ryker deploy never installs, upgrades or restarts a Coop worker:
    # production workers are enrolled through the outbound fleet protocol, and
    # the bundled one is the Compose project's own service, untouched here.
    refute deploy =~ "ryker-coop"
    refute deploy =~ "coop build"
    refute deploy =~ "launchctl"
    refute deploy =~ "systemctl"

    # The operator documentation is shipped; the developer deploy is not.
    assert operations =~ "Docker Compose"
    assert operations =~ "scripts/compose.sh"
    refute operations =~ "scripts/deploy.sh"
    refute operations =~ "ryker bootstrap-coop"
    refute operations =~ "ryker serve"
    refute operations =~ "State is one owner-private SQLite database"
  end

  test "the archive checker authenticates bytes before extracting or executing them" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ryker-release-authentication-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    version = "0.1.0-g" <> String.duplicate("b", 40)
    archive = fake_release_archive!(root, "untrusted", version)
    checker = Path.expand("../../scripts/check-elixir-release.sh", __DIR__)

    assert {output, status} =
             System.cmd(
               checker,
               [archive, version, String.duplicate("0", 64)],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "archive SHA-256 does not match trusted digest"
  end

  test "the archive checker refuses a release that carries eval-only code" do
    # Until 2026-09-26 every release carried the model evaluations, their Mix
    # tasks and the local Unix-socket Coop client they drive: 28 modules no
    # product path uses. evals/ now compiles only in development and test, and
    # an archive in which any of them reappears must not pass as a release.
    root =
      Path.join(
        System.tmp_dir!(),
        "ryker-release-eval-only-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    version = "0.1.0-g" <> String.duplicate("c", 40)
    checker = Path.expand("../../scripts/check-elixir-release.sh", __DIR__)

    check = fn archive ->
      digest = digest(File.read!(archive))
      System.cmd(checker, [archive, version, digest], stderr_to_stdout: true)
    end

    assert {output, 0} = check.(complete_release_archive!(root, "product", version, []))
    assert output =~ "is self-contained and migration-capable"

    for module <- ~w(
          Elixir.Ryker.Evals.WorldRunner
          Elixir.Ryker.Evals.LearningRunner.ScratchAPI
          Elixir.Ryker.Coop.Client
          Elixir.Mix.Tasks.Ryker.Eval
          Elixir.Mix.Tasks.Ryker.LearningEval
        ) do
      assert {output, status} = check.(complete_release_archive!(root, module, version, [module]))
      assert status != 0
      assert output =~ "release contains eval-only modules:\n  #{module}\n"
    end
  end

  test "the container migrates before it starts the release" do
    entrypoint = read!("deploy/compose/entrypoint.sh")
    nginx = read!("deploy/nginx/ryker.conf")

    # There is no application configuration file to point the container at:
    # product settings live in PostgreSQL and the environment carries only
    # deployment connections and credentials.
    refute entrypoint =~ "RYKER_ELIXIR_CONFIG"
    {migrate, _} = :binary.match(entrypoint, "Ryker.Release.migrate()")
    {start, _} = :binary.match(entrypoint, "exec /opt/ryker/bin/ryker start")
    assert migrate < start

    assert nginx =~ "location = /v1/github"
    assert nginx =~ "proxy_pass http://127.0.0.1:4319"
    assert nginx =~ "location /v1/hooks/"
    assert nginx =~ "proxy_pass http://127.0.0.1:4320"
    refute nginx =~ "127.0.0.1:8080"
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

  # Ecto skips an applied version it has no file for, so the release a failed
  # deploy left pinned booted on a schema it did not know and wrote to it
  # (2026-10-04 review). A database a newer release migrated is refused.
  test "migrating refuses a database a newer release has migrated" do
    older =
      Path.join(System.tmp_dir!(), "ryker-older-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(older)
    on_exit(fn -> File.rm_rf!(older) end)

    [baseline | _newer] =
      :ryker
      |> Application.app_dir("priv/repo/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.sort()

    File.cp!(baseline, Path.join(older, Path.basename(baseline)))

    assert_raise RuntimeError, ~r/newer than this release/, fn ->
      Release.migrate(log: false, migrations_path: older)
    end
  end

  test "only an applied version newer than every migration the release carries counts" do
    migrations = [
      {:up, 20_260_901_000_000, "** FILE NOT FOUND **"},
      {:up, 20_260_926_100_000, "baseline"},
      {:down, 20_261_005_000_000, "pending"},
      {:up, 20_261_006_000_000, "** FILE NOT FOUND **"}
    ]

    assert Release.newer_than_release(migrations) == [20_261_006_000_000]
    assert Release.newer_than_release(Enum.take(migrations, 3)) == []
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

    for options <- [[prefix: "Public"], [log: :silent], [repo: "Ryker.Repo"]] do
      assert_raise ArgumentError, ~r/options are invalid/, fn ->
        Release.migrations(options)
      end
    end

    assert_raise ArgumentError, ~r/migrations path must be absolute/, fn ->
      Release.migrations(migrations_path: "relative/migrations")
    end
  end

  test "a Compose install enrols its own workers and checks its settings through the release" do
    # Settings › Advanced told people with their own workers to run
    # `MIX_ENV=prod mix ryker.coop_worker enroll` and `mix ryker.doctor`, which
    # a Compose install (a release, with no Mix) cannot run. The release has
    # both, and scripts/compose.sh runs them inside the container.
    assert {:ok, %{token: token, worker_id: "worker-own-1"}} =
             Release.issue_worker_token("worker-own-1", "workspace-own", "operator:local",
               log: false
             )

    assert is_binary(token) and byte_size(token) > 20

    assert Repo.exists?(
             from(t in Ryker.CoopFleet.EnrollmentToken, where: t.worker_id == "worker-own-1")
           )

    assert {:error, _reason} =
             Release.issue_worker_token("bad id with spaces", "workspace-own", "operator:local",
               log: false
             )

    # With nothing saved yet the preflight says so instead of crashing; with
    # settings it returns its report.
    assert {status, _report} = Release.doctor(log: false)
    assert status in [:ok, :error]

    compose = read!("scripts/compose.sh")
    assert compose =~ "worker-token)"
    assert compose =~ "Ryker.Release.issue_worker_token("
    assert compose =~ "doctor)"
    assert compose =~ "Ryker.Release.doctor()"
  end

  # Drain, resume and revoke were reachable only through `mix ryker.coop_worker`,
  # which a Compose install cannot run, so a worker it enrolled could never be
  # revoked there, however compromised (2026-10-04 review).
  test "a Compose install drains, resumes and revokes its workers through the release" do
    hash = digest("certificate:release-lifecycle")
    {:ok, _worker} = ControlPlane.authorize_worker("worker-own-2", "workspace-own", hash)

    for {action, status, state} <- [
          {:drain, "draining", "draining"},
          {:resume, "resumed", "offline"},
          {:revoke, "revoked", "revoked"}
        ] do
      assert {:ok, %{"status" => ^status, "state" => ^state, "worker_id" => "worker-own-2"}} =
               Release.worker_lifecycle(action, "worker-own-2", "operator:local", log: false)
    end

    assert {:error, _reason} =
             Release.worker_lifecycle(:drain, "worker-own-2", "operator:local", log: false)

    compose = read!("scripts/compose.sh")
    assert compose =~ "worker-drain | worker-resume | worker-revoke)"
    assert compose =~ "Ryker.Release.worker_lifecycle(:${1#worker-}"
  end

  # A release-shaped archive with nothing trustworthy in it: the checker must
  # refuse it on the digest alone, before it reads a single entry.
  defp fake_release_archive!(root, name, version) do
    source = Path.join(root, name)
    File.mkdir_p!(Path.join(source, "bin"))

    executable = Path.join(source, "bin/ryker")
    File.write!(executable, "#!/bin/sh\nprintf 'ryker #{version}\\n'\n")
    File.chmod!(executable, 0o755)
    File.write!(Path.join(source, "payload.txt"), name)

    archive = Path.join(root, "#{name}.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", archive, "-C", source, "."])
    archive
  end

  # A release-shaped archive that satisfies every structural check: the
  # executable answers `version` and `eval` for the expected version, and every
  # migration and operator asset is present. `modules` adds ebin entries.
  defp complete_release_archive!(root, name, version, modules) do
    source = Path.join(root, name)
    application = Path.join([source, "lib", "ryker-#{version}"])

    migrations =
      for path <- Path.wildcard(Path.join(@root, "priv/repo/migrations/*.exs")),
          do: Path.join(["lib", "ryker-#{version}", "priv/repo/migrations", Path.basename(path)])

    assets =
      for asset <- String.split(read!("release-assets.txt"), "\n", trim: true),
          not String.starts_with?(asset, "#"),
          do: Path.join(["share", "ryker", asset])

    for file <- [Path.join(["releases", version, "runtime.exs"]) | migrations ++ assets] do
      path = Path.join(source, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end

    for module <- modules do
      File.mkdir_p!(Path.join(application, "ebin"))
      File.write!(Path.join([application, "ebin", module <> ".beam"]), "FOR1")
    end

    File.mkdir_p!(Path.join(source, "bin"))
    executable = Path.join(source, "bin/ryker")
    File.write!(executable, "#!/bin/sh\nprintf 'ryker #{version}\\n'\n")
    File.chmod!(executable, 0o755)

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

  defp read!(relative), do: File.read!(Path.join(@root, relative))
end
