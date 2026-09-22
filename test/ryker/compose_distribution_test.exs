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
    public = read("compose.yml") <> read("install.sh")

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
    assert public =~ "ryker-workspaces:"
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

    assert installer =~ "prepare_bundled_coop"
    assert installer =~ "docker compose"
    assert installer =~ "0.1.0-source.g"
    assert installer =~ ~s(codex_auth_root=${CODEX_HOME:-$HOME/.codex})
    assert installer =~ "Imported the existing Codex sign-in"
    assert worker =~ "coop sessions connect"
    assert worker =~ "coop sessions policies"
    assert worker =~ "worker.json"
    # A laptop can sleep through the normal client-certificate renewal window.
    # The Compose distribution must then discard only that expired identity and
    # request a fresh single-use enrollment token instead of staying offline.
    assert worker =~ ~s(openssl x509 -in "$identity" -noout -checkend 0)
    assert worker =~ ~s(rm -f "$identity" "$marker" "$token")
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
    # The worker itself resolves and trusts the Compose-only Ryker certificate,
    # but its Docker-in-Docker boxes have a separate DNS and trust boundary.
    # Without both projections Chat is admitted and then stalls because every
    # responder-state MCP startup fails inside the model box.
    assert worker =~ "prepare_ryker_box"
    assert worker =~ ~s(--arg state_endpoint "https://172.30.42.10:4322")
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
    assert worker =~ ~s(capabilities: [{name: "responder-state", version: "1"}])
    assert worker_image =~ "COOP_REVISION=cb5178ebb9f0e6c53999df51ffffe73bd5f84e6c"
    assert worker_image =~ "COPY --from=build /out/coop /usr/local/bin/coop"
    assert worker_image =~ "coop help sessions policies"
    assert worker_image =~ "coop help sessions connect"
    refute worker_image =~ "raw.githubusercontent.com"
    assert read("lib/ryker/bundled_coop.ex") =~ ~s(conversational: "ryker-chat")
    assert read("lib/ryker/bundled_coop.ex") =~ ~s(incident: "ryker-incident")
    assert read("lib/ryker/release.ex") =~ "BundledCoop.prepare_distribution!"
    assert read("lib/ryker/release.ex") =~ "with_settings_pubsub"
    assert lifecycle =~ "ryker-coop"
    refute installer =~ "ryker.coop_worker enroll"
    refute installer =~ "policy digest"
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

  test "the shipped release points operators to Compose rather than host service managers" do
    mix = read("mix.exs")

    assert mix =~ "compose.yml"
    assert mix =~ "install.sh"
    assert mix =~ "scripts/compose.sh"
    assert mix =~ "deploy/compose/coop/Box.Dockerfile"
    assert mix =~ "deploy/compose/coop/Dockerfile"
    assert mix =~ "deploy/compose/coop/entrypoint.sh"
    refute mix =~ "deploy/systemd/ryker.service"
    refute mix =~ "deploy/systemd/ryker.env.example"
    refute mix =~ "deploy/launchd"
  end

  defp read(relative), do: File.read!(Path.join(@root, relative))
end
