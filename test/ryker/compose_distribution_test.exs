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
    assert lifecycle =~ ~s(codex_auth_root=${CODEX_HOME:-$HOME/.codex})
    assert lifecycle =~ "Imported the existing Codex sign-in"
    assert worker =~ "coop sessions connect"
    assert worker =~ ~s(--controller "$controller" --token-file "$token")
    assert worker =~ ~s(--ca-file "$ca" --state "$state/sessions")
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
    assert read("compose.yml") =~ "chown -R 1000:1000 /var/lib/ryker"
    compose_entrypoint = read("deploy/compose/entrypoint.sh")
    assert compose_entrypoint =~ ~S(IP:$compose_worker_ip)
    assert compose_entrypoint =~ ~S(-checkip "$compose_worker_ip")
    assert compose_entrypoint =~ "grep -q 'does match certificate'"
    refute worker =~ "capabilities:"
    refute worker =~ "slots_free:"
    # The recipe builds the newest Coop on GitHub that the live worker is built from. It pinned
    # cb5178eb, worker protocol v1, for days after Ryker spoke only v2 (2026-09-27): rebuilding
    # the worker from the recipe would have produced one that could not talk to Ryker at all.
    assert worker_image =~ "COOP_REVISION=5596c527c8d630ea77f9ce06534a97cf04a1d484"
    assert worker_image =~ "COOP_VERSION=v9.0.0-552-g5596c527"
    # The Coop pin lives in one place, the worker Dockerfile; compose.yml only
    # passes an operator's COOP_VERSION override through. Two copies of the
    # default once had to be bumped together.
    assert worker_image =~ ~r/^ARG COOP_VERSION=v/m
    refute read("compose.yml") =~ "COOP_VERSION:-"
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
    assert lifecycle =~ "-czf - -C /var/lib coop ryker-coop"
    assert lifecycle =~ "-xzf - -C /var/lib coop ryker-coop"
    refute lifecycle =~ "ryker-workspaces"
    refute read("release-assets.txt") =~ "load-policies.sh"
    refute File.exists?(Path.join(@root, "deploy/compose/coop/load-policies.sh"))
    refute read("lib/ryker/application.ex") =~ "ProblemWatcher"
  end

  test "the production image is an Elixir release without a Node runtime" do
    dockerfile = read("Dockerfile")

    assert dockerfile =~ "mix release ryker"
    assert dockerfile =~ "RYKER_ELIXIR_VERSION=${RYKER_VERSION}"
    assert dockerfile =~ "COPY Dockerfile compose.yml install.sh ./"
    assert dockerfile =~ "COPY deploy/nginx deploy/nginx"
    assert dockerfile =~ "FROM debian:bookworm-slim AS runtime"
    assert dockerfile =~ "LANG=C.UTF-8"
    refute dockerfile =~ ~r/^FROM node:/m
    refute dockerfile =~ ~r/apt-get install[^\n]*(nodejs|npm)/
    refute dockerfile =~ "npm install"
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

  test "the shipped release points operators to Compose rather than host service managers" do
    manifest = read("release-assets.txt")

    assert read("mix.exs") =~ "release-assets.txt"
    assert manifest =~ "compose.yml"
    assert manifest =~ "install.sh"
    assert manifest =~ "scripts/compose.sh"
    assert manifest =~ "deploy/compose/coop/Box.Dockerfile"
    assert manifest =~ "deploy/compose/coop/Dockerfile"
    assert manifest =~ "deploy/compose/coop/entrypoint.sh"
    refute manifest =~ "deploy/systemd"
    refute manifest =~ "deploy/launchd"
  end

  defp read(relative), do: File.read!(Path.join(@root, relative))
end
