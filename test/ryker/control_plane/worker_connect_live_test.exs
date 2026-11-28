defmodule Ryker.ControlPlane.WorkerConnectLiveTest do
  # Sets the worker gateway's environment for the console it opens.
  use Ryker.DataCase, async: false
  import Ryker.ConsoleSignIn, only: [signed_in_conn: 0]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, WorkerConnect}
  alias Ryker.CoopFleet.EnrollmentToken
  alias Ryker.Crypto
  alias Ryker.Settings

  @actor "control-plane:local"
  @endpoint Endpoint
  @ca "-----BEGIN CERTIFICATE-----\nMIIBworkerconnecttestca\n-----END CERTIFICATE-----\n"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("w", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "worker-connect-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("w", 32)
       }}
    )

    :ok
  end

  # Andrew, 2026-11-20, of Settings › Advanced on an install that showed only "Worker install:
  # Not set: Ryker takes no work": "when worker is not connected would be good to show
  # instructions how to connect one". Connecting one meant reading the operations guide and
  # running a mix task on the controller for its one-time token.
  test "with no worker connected, Advanced shows how to connect one and makes its token" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    gateway!("https://ryker.example.com:4322")
    {:ok, view, _html} = open("/settings/advanced")

    assert has_element?(view, "#worker-connect", "Connect a worker")

    assert has_element?(
             view,
             "#worker-connect-1 pre",
             "curl -fsSL https://coop.dryga.com/install.sh | sh"
           )

    assert has_element?(view, "#worker-connect-2", "Open Settings → Models")
    refute render(view) =~ "coop login"
    refute has_element?(view, "#worker-connect-commands")

    view
    |> form("#worker-connect-form", worker: %{name: "mac-mini", install: "production"})
    |> render_submit()

    commands = view |> element("#worker-connect-commands") |> render() |> text()
    assert commands =~ "--controller https://ryker.example.com:4322"
    assert commands =~ "MIIBworkerconnecttestca"
    assert [_line, token] = Regex.run(~r/printf '%s\\n' '([^']+)'/, commands)

    # The token shown is the one Ryker keeps for that worker and install, as its digest only.
    assert %EnrollmentToken{worker_id: "mac-mini", workspace_ref: "production"} =
             Repo.get_by!(EnrollmentToken, token_sha256: Crypto.sha256_hex(token))

    assert has_element?(view, "#worker-connect-5", "production")
  end

  test "a worker name workers cannot have is refused beside the form" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    gateway!("https://ryker.example.com:4322")
    {:ok, view, _html} = open("/settings/advanced")

    view
    |> form("#worker-connect-form", worker: %{name: "mac mini", install: "production"})
    |> render_submit()

    assert has_element?(view, "#worker-connect-form [role=alert]")
    refute has_element?(view, "#worker-connect-commands")
    assert Repo.aggregate(EnrollmentToken, :count) == 0
  end

  test "Advanced leaves the steps out once a worker has connected" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    gateway!("https://ryker.example.com:4322")

    assert {:ok, _worker} =
             Ryker.Fixtures.CoopWorkers.authorize(
               "worker-connected",
               "production",
               Ryker.TestHelpers.digest("worker-connected")
             )

    {:ok, view, _html} = open("/settings/advanced")
    refute has_element?(view, "#worker-connect")
  end

  test "an installation that takes no workers of its own says what to set instead of steps" do
    html =
      render_component(&WorkerConnect.card/1, connection: nil, accounts: ["codex@default"])

    assert html =~ "RYKER_WORKER_PUBLIC_URL"
    refute html =~ "coop sessions connect"
  end

  test "the connect commands save the authority and the token where coop reads them" do
    commands =
      WorkerConnect.commands(
        %{controller_url: "https://ryker.example.com:4322", ca_pem: @ca},
        %{token: "token-value"}
      )

    assert commands ==
             """
             mkdir -p ~/ryker-worker && chmod 700 ~/ryker-worker
             cat > ~/ryker-worker/ca.pem <<'EOF'
             -----BEGIN CERTIFICATE-----
             MIIBworkerconnecttestca
             -----END CERTIFICATE-----
             EOF
             printf '%s\\n' 'token-value' > ~/ryker-worker/token
             coop sessions connect --controller https://ryker.example.com:4322 --ca-file ~/ryker-worker/ca.pem --state ~/ryker-worker/state --token-file ~/ryker-worker/token\
             """
  end

  defp open(path), do: live(signed_in_conn() |> Map.put(:host, "localhost"), path)

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  # The worker gateway's settings as an installation that takes its own workers has them.
  defp gateway!(public_url) do
    root = Path.join(System.tmp_dir!(), "ryker-gateway-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "ca.pem"), @ca)

    settings = %{
      "RYKER_WORKER_PUBLIC_URL" => public_url,
      "RYKER_WORKER_CA_FILE" => Path.join(root, "ca.pem"),
      "RYKER_WORKER_CA_KEY_FILE" => Path.join(root, "ca-key.pem"),
      "RYKER_WORKER_CERT_FILE" => Path.join(root, "server.pem"),
      "RYKER_WORKER_KEY_FILE" => Path.join(root, "server-key.pem")
    }

    previous = for {name, _value} <- settings, do: {name, System.get_env(name)}
    Enum.each(settings, fn {name, value} -> System.put_env(name, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(root)
    end)
  end
end
