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
    assert worker =~ "ryker-coop-load-policies"
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
    # The Coop pin lives in one place, the worker Dockerfile; compose.yml only
    # passes an operator's COOP_VERSION override through. Two copies of the
    # default once had to be bumped together.
    assert worker_image =~ ~r/^ARG COOP_VERSION=v/m
    refute read("compose.yml") =~ "COOP_VERSION:-"
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

  # Andrew, 2026-09-26, asking for fallbacks on any account: Coop refuses a
  # whole policy file while one model names an account the worker has not
  # signed in, and the entrypoint then waited for model access forever. One
  # fallback on claude@zzqa took the worker offline and stopped every kind of
  # work, not only the one that named it. The worker now connects with the
  # copy it last loaded, and still watches Ryker's newest file, so a refused
  # file neither reconnects in a loop nor stops the next change being tried.
  test "the worker connects with the policies it last loaded and watches the newest file" do
    worker = read("deploy/compose/coop/entrypoint.sh")
    worker_image = read("deploy/compose/coop/Dockerfile")
    loader = read("deploy/compose/coop/load-policies.sh")

    assert worker =~ ~s(loaded=$state/session-policies.loaded.yaml)
    assert worker =~ ~s(problem=$shared/policy-problem)

    assert worker =~
             ~s[policy_json=$(ryker-coop-load-policies "$policies" "$loaded" "$problem")]

    assert worker =~ "session_policy_path: $loaded"
    refute worker =~ "session_policy_path: $policies"
    refute worker =~ "coop sessions policies"

    assert worker =~
             ~s[policy_sha=$(sha256sum "$policies" "$repositories" | sha256sum | awk '{print $1}')]

    assert worker =~ "Ryker's worker is waiting for model access."
    assert loader =~ ~s(coop sessions policies --policies "$new" --json)

    assert worker_image =~
             "COPY --chown=coop:coop deploy/compose/coop/load-policies.sh " <>
               "/usr/local/bin/ryker-coop-load-policies"

    assert worker_image =~
             "chmod 0755 /usr/local/bin/ryker-coop-entrypoint /usr/local/bin/ryker-coop-load-policies"

    assert read("release-assets.txt") =~ "deploy/compose/coop/load-policies.sh"
  end

  describe "the worker's policy loader" do
    test "a file Coop loads becomes the copy the worker connects with and clears the reason" do
      dir = scratch!()
      new = write!(dir, "new.yaml", "target: codex@default\n")
      loaded = Path.join(dir, "loaded.yaml")
      problem = write!(dir, "policy-problem", "an earlier refusal")

      assert {output, 0} = load_policies(dir, new, loaded, problem)
      assert Jason.decode!(output) == %{"policy_file" => new}
      assert File.read!(loaded) == File.read!(new)
      assert mode(loaded) == 0o600
      refute File.exists?(problem)
    end

    test "a file Coop refuses leaves the worker on the copy it last loaded, with Coop's reason" do
      dir = scratch!()
      loaded = write!(dir, "loaded.yaml", "target: codex@default\n")
      File.chmod!(loaded, 0o600)
      new = write!(dir, "new.yaml", "target: [codex@default, claude@zzqa]\n")
      problem = Path.join(dir, "policy-problem")

      assert {output, 0} = load_policies(dir, new, loaded, problem)
      assert Jason.decode!(output) == %{"policy_file" => loaded}
      assert File.read!(loaded) == "target: codex@default\n"
      assert File.read!(problem) == refusal()
      assert mode(problem) == 0o644
    end

    test "with nothing it can load, the worker still waits, and Coop's reason is capped" do
      dir = scratch!()
      new = write!(dir, "new.yaml", "target: claude@zzqa\n")
      loaded = Path.join(dir, "loaded.yaml")
      problem = Path.join(dir, "policy-problem")
      long = refusal() <> String.duplicate("x", 5_000)

      assert {"", 1} = load_policies(dir, new, loaded, problem, long)
      assert File.read!(problem) == binary_part(long, 0, 4_096)
      refute File.exists?(loaded)

      # A copy Coop refuses as well is no better than none.
      write!(dir, "loaded.yaml", "target: claude@zzqa\n")
      assert {"", 1} = load_policies(dir, new, loaded, problem)
    end
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

  # Coop's words for a file it refuses, harvested from a real refusal.
  defp refusal, do: read("testdata/coop/policies-unsigned-account.stderr")

  # Stands in for `coop sessions policies --policies FILE --json` the way Coop
  # answers it: a file that names the unsigned zzqa account is refused.
  @fake_coop """
  #!/bin/sh
  [ "$1 $2 $3 $5" = "sessions policies --policies --json" ] || exit 64
  if grep -q zzqa "$4"; then
    cat "$(dirname "$0")/refusal" >&2
    exit 1
  fi
  printf '{"policy_file":"%s"}\\n' "$4"
  """

  # Runs the loader with the stand-in first on PATH, its own diagnostics kept
  # apart from the JSON it prints.
  defp load_policies(dir, new, loaded, problem, refusal \\ refusal()) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "refusal"), refusal)
    File.write!(Path.join(bin, "coop"), @fake_coop)
    File.chmod!(Path.join(bin, "coop"), 0o755)

    System.cmd(
      "sh",
      [
        "-c",
        ~S(exec sh "$0" "$1" "$2" "$3" 2>>"$4"),
        Path.join(@root, "deploy/compose/coop/load-policies.sh"),
        new,
        loaded,
        problem,
        Path.join(dir, "loader.log")
      ],
      env: [{"PATH", bin <> ":" <> System.get_env("PATH")}]
    )
  end

  defp scratch! do
    dir =
      Path.join(System.tmp_dir!(), "ryker-load-policies-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
