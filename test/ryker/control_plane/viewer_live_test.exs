defmodule Ryker.ControlPlane.ViewerLiveTest do
  @moduledoc """
  Andrew, 2026-10-03: "console shows who is using it, from Tailscale". Served
  through Tailscale Serve, each request names the tailnet user; the sidebar
  shows them, what they change is recorded as theirs, and a console reached any
  other way shows nobody and acts as the local console.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, Viewer}
  alias Ryker.{Instructions, Settings}

  @endpoint Endpoint
  @published "ryker.tailnet.example"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "viewer-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32),
         public_host: @published
       }}
    )

    :ok
  end

  test "the sidebar names the tailnet user Tailscale Serve sent, and nobody without it" do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    {:ok, view, _html} =
      tailnet("andrew@example.com", "Andrew Example") |> live("/environments")

    assert has_element?(view, ".app-sidebar .app-viewer strong", "Andrew Example")
    assert has_element?(view, ".app-sidebar .app-viewer small", "andrew@example.com")

    # Serve sends a name outside ASCII as RFC 2047 words.
    {:ok, view, _html} =
      tailnet("zoe@example.com", "=?utf-8?q?Zo=C3=AB_Smith?=") |> live("/environments")

    assert has_element?(view, ".app-viewer strong", "Zoë Smith")

    {:ok, view, _html} = served() |> live("/environments")
    refute has_element?(view, ".app-viewer")
  end

  test "what a tailnet user changes is recorded as theirs" do
    {:ok, view, _html} = tailnet("andrew@example.com", "Andrew Example") |> live("/setup")
    view |> element("button[phx-click=initialize-settings]") |> render_click()
    assert Settings.fetch!().installation.saved_by == "control-plane:tailscale:andrew@example.com"

    {:ok, view, _html} = tailnet("zoe@example.com", "Zoë Smith") |> live("/instructions")
    view |> element("#instructions-form") |> render_submit(%{"text" => "Answer in English."})
    assert Instructions.get(:global).saved_by == "control-plane:tailscale:zoe@example.com"
  end

  # Serve replaces the Tailscale headers a client sends, but a request at a
  # loopback name never passed through Serve. On mac-server, curl with
  # `Tailscale-User-Login: mallory@example.com` at http://127.0.0.1:4321 was
  # shown as signed in as mallory (2026-10-03).
  test "a Tailscale header sent to a loopback name names nobody and acts as the local console" do
    {:ok, view, _html} =
      build_conn()
      |> Map.put(:host, "localhost")
      |> put_req_header("tailscale-user-login", "mallory@example.com")
      |> put_req_header("tailscale-user-name", "Mallory")
      |> live("/setup")

    refute has_element?(view, ".app-viewer")
    view |> element("button[phx-click=initialize-settings]") |> render_click()
    assert Settings.fetch!().installation.saved_by == "control-plane:local"
  end

  # The learning forms post to plain HTTP routes, which read the request itself.
  test "a form posted through Serve is recorded as the tailnet user, and one sent locally is not" do
    request = tailnet("andrew@example.com", "Andrew Example")

    assert Viewer.actor_ref(request, @published) == "control-plane:tailscale:andrew@example.com"
    assert Viewer.actor_ref(%{request | host: "localhost"}, @published) == "control-plane:local"
    assert Viewer.actor_ref(request, nil) == "control-plane:local"
  end

  defp served, do: build_conn() |> Map.put(:host, @published)

  defp tailnet(login, name) do
    served()
    |> put_req_header("tailscale-user-login", login)
    |> put_req_header("tailscale-user-name", name)
  end
end
