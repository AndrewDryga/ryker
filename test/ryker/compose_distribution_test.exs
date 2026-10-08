defmodule Ryker.ComposeDistributionTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @integration_environment ~w(
    SLACK_APP_TOKEN
    SLACK_BOT_TOKEN
    GITHUB_APP_ID
    GITHUB_APP_PRIVATE_KEY
    GITHUB_WEBHOOK_SECRET
    EMISAR_API_TOKEN
    EMISAR_RPC_URL
    RYKER_WEBHOOK_SECRET_NAMES
  )

  test "the public Compose contract contains only host and machine-root settings" do
    public = read("compose.yml") <> read("install.sh") <> read("scripts/compose.sh")

    assert read(".gitignore") =~ "/.ryker/"

    Enum.each(@integration_environment, fn name ->
      refute public =~ name, "#{name} leaked into the public Compose setup"
    end)

    for required <- ~w(
          DATABASE_URL RYKER_CHECKPOINT_KEY RYKER_CREDENTIAL_KEY RYKER_STATE_TOOLS_TOKEN
        ) do
      assert public =~ required
    end

    assert public =~ ~s(127.0.0.1)
    assert public =~ "restart: unless-stopped"
    assert public =~ "healthcheck:"
    assert public =~ "postgres:18.4-bookworm"
    assert public =~ "ryker-database:/var/lib/postgresql"
    assert public =~ "ryker-database:"
    assert public =~ "ryker-state:"
    refute public =~ "ryker-workspaces:"
    refute public =~ "RYKER_BUNDLED_COOP_ROOT"
    assert public =~ "ryker-coop:"
    assert public =~ "RYKER_BUNDLED_COOP_WORKER_ID"
    assert public =~ "RYKER_WORKER_PUBLIC_URL"
    # The console published through Cloudflare Access (docs/operations.md).
    assert public =~
             "RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN: ${RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN:-}"

    assert public =~ "RYKER_CLOUDFLARE_ACCESS_AUD: ${RYKER_CLOUDFLARE_ACCESS_AUD:-}"
    assert public =~ "deploy/compose/coop/Dockerfile"
    assert public =~ "ryker-coop-docker:"
    assert public =~ "DOCKER_HOST"
    assert public =~ "ipv4_address: 172.30.42.10"
    assert public =~ "RYKER_COMPOSE_WORKER_IP: 172.30.42.10"
    refute public =~ "- /var/run/docker.sock"
  end

  test "the bundled worker is enrolled and managed by the distribution" do
    installer = read("install.sh")
    lifecycle = read("scripts/compose.sh")
    worker = read("deploy/compose/coop/entrypoint.sh")

    # install.sh is the documented name; the lifecycle helper owns the install
    # itself, so install, upgrade, backup and restore share one project and
    # one readiness check.
    assert installer =~ ~s(scripts/compose.sh" install)
    assert lifecycle =~ "install_ryker"
    assert lifecycle =~ "prepare_bundled_coop"
    assert lifecycle =~ "docker compose"
    assert lifecycle =~ "0.1.0-source.g"
    # The worker signs in on its own, through a login that puts the previous
    # sign-in back when it does not finish. Install copied the host's Codex
    # sign-in, and the two then shared one refresh token (2026-10-04 review).
    refute lifecycle =~ "CODEX_HOME"
    assert lifecycle =~ ~S'$(cat "$repository/deploy/compose/coop/model-login.sh")'
    assert worker =~ "coop sessions connect"
    assert worker =~ ~s(--controller "$controller" --token-file "$token")
    assert worker =~ ~s(--ca-file "$ca" --state "$state/sessions")
    # Reading the identity runs find, jq and openssl about ten times; done every two seconds it
    # kept an idle worker at 11 to 17% CPU (2026-10-04). The connector is checked every two
    # seconds, its identity once a minute.
    assert worker =~ "if [ $((checks % 30)) -eq 0 ]; then"
    refute worker =~ "ryker-coop-load-policies"
    refute worker =~ "worker.json"
    # A laptop can sleep through the normal client-certificate renewal window.
    # The Compose distribution must then discard only that expired identity and
    # request a fresh single-use enrollment token instead of staying offline.
    assert worker =~ ~s(identity=$state/sessions/identity.json)
    assert worker =~ ~s(openssl x509 -noout -checkend 0)
    assert worker =~ ~s(rm -f "$identity" "$marker")
    refute worker =~ ~s(rm -f "$identity" "$marker" "$token")
    assert worker =~ ~s(trap stop_connector EXIT)
    assert worker =~ ~s(wait "$connector")
    assert read("lib/ryker/application.ex") =~ "Ryker.BundledCoop.Reconciler"
    # Andrew, 2026-09-20: the worker client and its bundled Docker daemon are
    # separate containers. Generated bind-mount sources in the worker's
    # private /tmp were invisible to the daemon; Docker substituted
    # directories (including AGENTS.md), and every clean-install Chat turn
    # died before the provider could answer. Keep temporary run artifacts on
    # the state volume both containers share.
    assert worker =~ ~s("$state/tmp")
    assert worker_image = read("deploy/compose/coop/Dockerfile")
    assert worker_image =~ "TMPDIR=/var/lib/coop/tmp"
    assert worker_image =~ "git git-lfs"
    refute worker_image =~ "git lfs install"
    # The worker itself resolves and trusts the Compose-only Ryker certificate,
    # but its Docker-in-Docker boxes have a separate DNS and trust boundary.
    # Without both projections Chat is admitted and then stalls because every
    # controller-tools MCP startup fails inside the model box.
    assert worker =~ "prepare_ryker_box"
    assert worker =~ ~s(controller=https://172.30.42.10:4322)
    assert worker =~ "COOP_BASE_IMAGE=ryker-coop-box"
    assert worker_image =~ "deploy/compose/coop/Box.Dockerfile"
    trusted_box = read("deploy/compose/coop/Box.Dockerfile")
    assert trusted_box =~ "update-ca-certificates"
    assert trusted_box =~ "NODE_EXTRA_CA_CERTS"
    # The worker creates bind-mount sources that the coop-box image reads as
    # its non-root node user. A different host UID makes both the generated
    # config and restricted-run seed unreadable inside the box.
    assert read("Dockerfile") =~ "useradd --uid 1000 --gid"
    assert worker_image =~ "useradd --uid 1000 --gid"
    assert read("compose.yml") =~ "-exec chown -h 1000:1000 {} +"

    assert read("deploy/compose/entrypoint.sh") =~
             ~S(ryker-gateway-pki "$pki" "${RYKER_COMPOSE_WORKER_IP:-127.0.0.1}")

    gateway_pki = read("deploy/compose/gateway-pki.sh")
    assert gateway_pki =~ ~S(IP:$worker_ip)
    assert gateway_pki =~ ~S(-checkip "$worker_ip")
    assert gateway_pki =~ "grep -q 'does match certificate'"
    refute worker =~ "capabilities:"
    refute worker =~ "slots_free:"
    # The recipe builds the newest Coop on GitHub that the live worker is built from. It pinned
    # cb5178eb, worker protocol v1, for days after Ryker spoke only v2 (2026-09-27): rebuilding
    # the worker from the recipe would have produced one that could not talk to Ryker at all.
    # Coop main runs the version-2 jobs Ryker sends since 2026-10-04; d019c807 also holds a
    # command back while a repository's first download runs, and 5b112ce7 runs filtered jobs
    # on a Docker-in-Docker worker.
    assert worker_image =~ "COOP_REVISION=5b112ce7250039c8753b20cbf8c2502619f7924c"
    assert worker_image =~ "COOP_VERSION=v10.1.2-122-g5b112ce7"
    # The Coop pin lives in one place, the worker Dockerfile. Two copies of the
    # default once had to be bumped together, and compose.yml's COOP_VERSION
    # override relabeled the pinned revision as whatever it named (2026-10-04
    # review); another Coop is a prebuilt image named in RYKER_COOP_IMAGE.
    assert worker_image =~ ~r/^ARG COOP_VERSION=v/m
    refute read("compose.yml") =~ "COOP_VERSION"
    assert worker_image =~ "COPY --from=build /out/coop /usr/local/bin/coop"
    refute worker_image =~ "coop help sessions policies"
    assert worker_image =~ "coop help sessions connect"
    refute worker_image =~ "raw.githubusercontent.com"
    refute read("lib/ryker/bundled_coop.ex") =~ "policy_digests"
    refute worker_image =~ "COOP_REPO="
    assert read("lib/ryker/release.ex") =~ "BundledCoop.prepare_distribution!"
    assert read("lib/ryker/release.ex") =~ "with_settings_pubsub"
    assert lifecycle =~ "ryker-coop"
    refute installer =~ "ryker.coop_worker enroll"
    refute installer =~ "policy digest"
  end

  test "the worker backup retains custody but no retired checkout volume" do
    lifecycle = read("scripts/compose.sh")
    assert lifecycle =~ "-czf - -C /var/lib --exclude=coop/sessions/job-sources"
    assert lifecycle =~ "coop ryker-coop >\"$scratch/worker-state.tar.gz\""
    assert lifecycle =~ "-xzf - -C /var/lib coop ryker-coop"
    refute lifecycle =~ "ryker-workspaces"
    refute read("release-assets.txt") =~ "load-policies.sh"
    refute File.exists?(Path.join(@root, "deploy/compose/coop/load-policies.sh"))
    refute read("lib/ryker/application.ex") =~ "ProblemWatcher"
  end

  # The BEAM writes erl_crash.dump where it runs. Only /crash.dump was ignored, so one crash
  # left the checkout dirty and deploy.sh refused every deploy until someone deleted it
  # (2026-10-04 review).
  test "an Erlang crash dump never dirties the checkout" do
    assert {_ignored, 0} = System.cmd("git", ["check-ignore", "-q", "erl_crash.dump"])
  end

  # The gate checked scripts/*.sh only, so the two container entrypoints, which run as
  # PID 1, and install.sh were never checked (2026-10-04 review).
  test "ShellCheck reads every shell file in the repository" do
    # A clean make environment: inside the gate this child inherited the
    # parent's jobserver flags and printed a warning into every run.
    {command, 0} =
      System.cmd("make", ["-n", "shellcheck"],
        env: [{"MAKEFLAGS", nil}, {"MFLAGS", nil}, {"MAKELEVEL", nil}]
      )

    {tracked, 0} = System.cmd("git", ["ls-files", "*.sh"])

    for file <- String.split(tracked, "\n", trim: true) do
      assert command =~ file, "make shellcheck skips #{file}"
    end
  end

  # Test files compiled with warnings and the gate passed: two type warnings, an unused
  # helper and an unused attribute stood for weeks (2026-10-04 review). The gate's test runs
  # refuse a warning as the compile step already does.
  test "the gate's test runs refuse a compiler warning" do
    script = File.read!("scripts/elixir-test.sh")

    [check] =
      Regex.run(~r/if \[\[ \$\{1:-\} == "--check" \]\]; then\n(.*?)\nelse/s, script,
        capture: :all_but_first
      )

    assert check =~ "test_partitions --warnings-as-errors"
  end

  test "the production image is an Elixir release without a Node runtime" do
    dockerfile = read("Dockerfile")

    assert dockerfile =~ "mix release ryker"
    assert dockerfile =~ "RYKER_ELIXIR_VERSION=${RYKER_VERSION}"
    # The image carries the release, not an install kit beside it.
    refute dockerfile =~ "COPY Dockerfile compose.yml install.sh ./"
    assert dockerfile =~ ~r/^FROM debian:bookworm-slim@sha256:[0-9a-f]{64} AS runtime$/m
    assert dockerfile =~ "LANG=C.UTF-8"
    refute dockerfile =~ ~r/^FROM node:/m
    refute dockerfile =~ ~r/apt-get install[^\n]*(nodejs|npm)/
    refute dockerfile =~ "npm install"
  end

  # 2026-10-07: the release became root's so a compromised Ryker cannot rewrite it, and the
  # first such deploy failed: scripts/deploy.sh builds from a worktree made under umask 077,
  # the release carried its runtime.exs and migrations owner-only, and the ryker user could
  # not read them. The image makes the release readable whatever the builder's umask was.
  test "the root-owned release is readable by the user that runs it" do
    dockerfile = read("Dockerfile")
    [build | _runtime_stages] = String.split(dockerfile, ~r/^FROM .* AS ffmpeg$/m)

    assert build =~ ~r/mix release ryker \\\n && chmod -R u=rwX,go=rX _build\/prod\/rel\/ryker$/m
    assert dockerfile =~ "COPY --from=build /build/_build/prod/rel/ryker ./"
    refute dockerfile =~ "--chown=ryker"
    assert dockerfile =~ ~r/^USER ryker$/m
  end

  # Every deploy downloaded the build packages and compiled every dependency
  # again: sixteen minutes on 2026-10-01, where a warm cache takes about one.
  # The version was named before them, and a changed value starts the cache
  # over from there.
  test "the release version is named only after the steps a deploy can reuse" do
    stages = String.split(read("Dockerfile"), ~r/^FROM /m, trim: true)

    for stage <- stages,
        {version_at, _length} <- [:binary.match(stage, "RYKER_VERSION")],
        reusable <- ["apt-get install", "mix deps.compile"],
        {reusable_at, _length} <- [:binary.match(stage, reusable)] do
      assert version_at > reusable_at,
             "RYKER_VERSION is named before #{reusable} in: FROM " <>
               hd(String.split(stage, "\n"))
    end
  end

  # Voice messages are transcribed inside the container (2026-09-27), by the
  # programs Ryker.Transcription.Local runs from fixed paths. The gate never
  # builds the image, so this holds the Dockerfile to those paths and to
  # sources it checks before it builds anything from them.
  test "the production image carries the transcriber where Ryker runs it, from checked sources" do
    dockerfile = read("Dockerfile")
    transcriber = read("lib/ryker/transcription/local.ex")

    for path <- ["/opt/whisper/bin/whisper-cli", "/opt/whisper/ggml-base.bin"] do
      assert transcriber =~ ~s("#{path}")
      assert dockerfile =~ path
    end

    assert dockerfile =~ "COPY --from=whisper /opt/whisper /opt/whisper"
    assert dockerfile =~ "COPY --from=ffmpeg /opt/ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg"
    assert dockerfile =~ ~S[test "$(git -C /src rev-parse HEAD)" = "$WHISPER_CPP_COMMIT"]

    assert dockerfile =~
             ~S[echo "$WHISPER_MODEL_SHA256  /opt/whisper/ggml-base.bin" | sha256sum -c -]

    assert dockerfile =~ ~S[echo "$FFMPEG_SHA256  /ffmpeg.tar.xz" | sha256sum -c -]
  end

  # mix.exs reads release-assets.txt when it loads, and the image ran its
  # first mix command with only mix.exs and mix.lock copied in, so the
  # 2026-09-26 deploy failed at `mix deps.get` and replaced nothing. The gate
  # never builds the image, so this reads the Dockerfile instead.
  test "every file mix.exs reads when it loads is in the image before mix first runs" do
    loaded =
      ~r/@\w+ Path\.expand\("([^"]+)", __DIR__\)/
      |> Regex.scan(read("mix.exs"), capture: :all_but_first)
      |> List.flatten()

    assert "release-assets.txt" in loaded

    [before_mix, _rest] = String.split(read("Dockerfile"), ~r/^RUN mix /m, parts: 2)

    copied =
      ~r/^COPY ([^\n]+)$/m
      |> Regex.scan(before_mix, capture: :all_but_first)
      |> Enum.flat_map(fn [arguments] -> arguments |> String.split() |> Enum.drop(-1) end)

    for file <- ["mix.exs", "mix.lock" | loaded] do
      assert file in copied, "#{file} reaches the image only after mix first runs"
    end
  end

  # emisar's draft-PR reviews, 2026-10-01: its review stack (PostgreSQL) never started, and once
  # Coop starts a review's declared stack, it does so with `docker compose`, which the worker
  # image's Docker did not include ("'compose' is not a docker command"). The plugin is a pinned
  # release whose checksum is checked for each architecture.
  test "the worker can start a review's services with a verified Docker Compose" do
    worker_image = read("deploy/compose/coop/Dockerfile")

    assert worker_image =~ "ARG COMPOSE_VERSION=v5.1.2"
    assert worker_image =~ "docker-compose-linux-$arch"
    assert worker_image =~ "d5ce4020039cdbe81679b770e64f89d2cc601398d3b1aacd84a02a9176cd9d20"
    assert worker_image =~ "c372e512a36e67716b0b3a1264ccdc461dec7a7beff601b81f7c5fb008e3511e"
    assert worker_image =~ "sha256sum -c -"
    assert worker_image =~ "docker compose version"
  end

  # 2026-10-04 review: volume-init re-owned all of the worker's state on every start, about 13 GB
  # of Coop caches it walked and rewrote while Ryker waited. It changes only what the runtime
  # user does not already own (the command was run against a scratch tree in alpine: owned files
  # are left alone, the rest, symlinks included, are re-owned).
  test "volume-init re-owns only what the runtime user does not already own" do
    services = YamlElixir.read_from_string!(read("compose.yml"))["services"]
    ["sh", "-c", command] = services["volume-init"]["command"]

    refute command =~ "chown -R"
    assert command =~ ~S"\( ! -user 1000 -o ! -group 1000 \) -exec chown -h 1000:1000 {} +"

    for volume <- ~w(/var/lib/ryker /var/lib/coop /var/lib/ryker-coop),
        do: assert(command =~ volume)
  end

  # emisar's draft-PR reviews, 2026-10-02, once the worker had Docker Compose: Coop still refused
  # to start the review stack ("restricted networking requires an absolute local unix:// Docker
  # endpoint"), because the worker reached its Docker daemon over TCP. It now reaches the daemon
  # through a socket the two containers share, and the daemon no longer listens on the network,
  # where any container on Ryker's network could drive it.
  test "the worker reaches its Docker daemon through a shared local socket, never over the network" do
    services = YamlElixir.read_from_string!(read("compose.yml"))["services"]
    daemon = services["ryker-coop-docker"]
    worker = services["ryker-coop"]
    socket = "/run/ryker-coop-docker/docker.sock"

    assert worker["environment"]["DOCKER_HOST"] == "unix://" <> socket
    assert ("--host=unix://" <> socket) in daemon["command"]
    refute Enum.any?(daemon["command"], &String.contains?(&1, "tcp://"))

    # The docker:dind entrypoint puts its own --host=tcp://0.0.0.0:2375 in front of a command
    # that starts with a flag, so the first live check after this change still found the port
    # open. Naming dockerd first runs exactly these arguments.
    assert hd(daemon["command"]) == "dockerd"

    shared = "ryker-coop-docker-socket:" <> Path.dirname(socket)
    assert shared in daemon["volumes"]
    assert shared in worker["volumes"]

    # The worker runs as the coop user, so the socket belongs to that user's group.
    [gid] =
      Regex.run(~r/groupadd --gid (\d+) coop/, read("deploy/compose/coop/Dockerfile"),
        capture: :all_but_first
      )

    assert ("--group=" <> gid) in daemon["command"]
  end

  # Repository knowledge moved to filtered networking (2026-10-08), which this worker could not
  # run: Debian's Docker CLI 20.10 never hands `docker build` to Buildx, which Coop builds the
  # network images with, and Coop's session API takes a filtered job only on a daemon
  # `coop net setup` qualified (Coop 4f32cb88, 2026-10-07). The worker copies the CLI and Buildx
  # the daemon's own image ships, by the same digest, and qualifies the daemon before it
  # connects. Coop reads the qualification from the worker's state, which the daemon shares.
  test "the worker runs filtered jobs with its daemon's own Docker CLI, on a daemon qualified first" do
    services = YamlElixir.read_from_string!(read("compose.yml"))["services"]
    worker_image = read("deploy/compose/coop/Dockerfile")
    entrypoint = read("deploy/compose/coop/entrypoint.sh")

    assert worker_image =~ "FROM #{services["ryker-coop-docker"]["image"]} AS docker\n"
    assert worker_image =~ "COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker"

    assert worker_image =~
             "COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-buildx"

    assert worker_image =~ "docker buildx version"
    refute worker_image =~ "docker.io"

    assert {setup, _length} = :binary.match(entrypoint, "if ! coop net setup; then")
    assert {connect, _length} = :binary.match(entrypoint, "coop sessions connect")
    assert setup < connect
  end

  # Ryker's draft-PR reviews of its own repository run `make dev-check` in the
  # trusted box, which gets no Docker and no sidecar. On 2026-10-02 that box had
  # neither Elixir nor a PostgreSQL server, so every such review failed its gate.
  test "the trusted box builds and tests Ryker with the release's Elixir and its own PostgreSQL" do
    box = read("deploy/compose/coop/Box.Dockerfile")

    [elixir_image] =
      Regex.run(~r/^ARG ELIXIR_IMAGE=(\S+)$/m, read("Dockerfile"), capture: :all_but_first)

    [postgres_major] =
      Regex.run(~r/image: postgres:(\d+)\./, read("compose.test.yml"), capture: :all_but_first)

    assert box =~ "ARG ELIXIR_IMAGE=#{elixir_image}\n"
    assert box =~ "COPY --from=elixir /usr/local/lib/erlang /usr/local/lib/erlang"
    assert box =~ "apt-get install -y --no-install-recommends postgresql-#{postgres_major} \\"
    assert box =~ "/usr/lib/postgresql/#{postgres_major}/bin/pg_ctl /usr/local/bin/"
  end

  # mac-server, 2026-10-01, the first fresh install in weeks, stopped three times. `coop build`
  # from the worker container's "/" was refused ("coop's network records must live outside every
  # directory an agent can reach"); from /tmp it failed on the fresh volume's missing temporary
  # directory; and once the worker ran, it could not reach Ryker's gateway, because the settings
  # the installer saves from a one-off process reach the running Ryker only when it starts. This
  # Mac's install predates all three, so nothing here had noticed.
  test "a fresh install builds the box from /tmp and restarts Ryker onto the settings it saved" do
    dir = Path.join(System.tmp_dir!(), "ryker-install-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Path.join(dir, "docker.log")

    # A fresh host: no other checkout's database volume.
    fake!(bin, "docker", """
    printf '%s\\n' "$*" >>"$FAKE_LOG"
    case "$*" in "volume inspect "*) exit 1 ;; esac
    """)

    # A ready console, as the readiness probe asks it: the status on stdout and the
    # headers in the file it names.
    fake!(bin, "curl", """
    while [ "$#" -gt 0 ]; do
      case $1 in
        --dump-header)
          printf 'HTTP/1.1 200 OK\\r\\nx-ryker-version: 0.1.0-install-test\\r\\n' >"$2"
          shift
          ;;
      esac
      shift
    done
    printf 200
    """)

    {output, status} =
      System.cmd("sh", [Path.join(@root, "scripts/compose.sh"), "install"],
        env: [
          {"PATH", bin <> ":/usr/bin:/bin"},
          {"FAKE_LOG", log},
          {"HOME", dir},
          {"RYKER_INSTALL_STATE", Path.join(dir, "state")},
          {"RYKER_VERSION", "0.1.0-install-test"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    calls = log |> File.read!() |> String.split("\n", trim: true)

    prepared = index!(calls, "prepare_bundled_coop")
    restarted = index!(calls, "restart ryker")
    built = index!(calls, "coop build")
    worker = index!(calls, "--wait ryker-coop")

    assert prepared < restarted and restarted < worker
    assert built < worker

    assert Enum.at(calls, built) =~
             ~s(run --rm --no-deps -w /tmp --entrypoint /bin/sh ryker-coop -c umask 077; mkdir -p "$TMPDIR"; coop build)
  end

  defp fake!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp index!(calls, fragment) do
    Enum.find_index(calls, &String.contains?(&1, fragment)) ||
      flunk("the installer never ran #{inspect(fragment)}:\n" <> Enum.join(calls, "\n"))
  end

  defp read(relative), do: File.read!(Path.join(@root, relative))
end
