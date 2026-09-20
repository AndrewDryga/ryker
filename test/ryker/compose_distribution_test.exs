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
    assert public =~ "ryker-database:"
    assert public =~ "ryker-state:"
    assert public =~ "ryker-workspaces:"
    assert public =~ "ryker-coop:"
    assert public =~ "RYKER_BUNDLED_COOP_WORKER_ID"
    assert public =~ "RYKER_WORKER_PUBLIC_URL"
    assert public =~ "deploy/compose/coop/Dockerfile"
    assert public =~ "ryker-coop-docker:"
    assert public =~ "DOCKER_HOST"
    refute public =~ "- /var/run/docker.sock"
  end

  test "the bundled worker is enrolled and managed by the distribution" do
    installer = read("install.sh")
    lifecycle = read("scripts/compose.sh")
    worker = read("deploy/compose/coop/entrypoint.sh")

    assert installer =~ "prepare_bundled_coop"
    assert installer =~ "docker compose"
    assert installer =~ "0.1.0-source.g"
    assert worker =~ "coop sessions connect"
    assert worker =~ "coop sessions policies"
    assert worker =~ "worker.json"
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
    assert mix =~ "deploy/compose/coop/Dockerfile"
    assert mix =~ "deploy/compose/coop/entrypoint.sh"
    refute mix =~ "deploy/systemd/ryker.service"
    refute mix =~ "deploy/systemd/ryker.env.example"
    refute mix =~ "deploy/launchd"
  end

  defp read(relative), do: File.read!(Path.join(@root, relative))
end
