defmodule Ryker.ControlPlane.ViewerLiveTest do
  @moduledoc """
  Andrew, 2026-10-03: "console shows who is using it, from Tailscale". Served
  through Tailscale Serve, each request names the tailnet user; the sidebar
  shows them, and a console reached any other way shows nobody.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Settings

  @endpoint Endpoint

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
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
  end

  test "the sidebar names the tailnet user Tailscale Serve sent, and nobody without it" do
    {:ok, view, _html} =
      tailnet("andrew@example.com", "Andrew Example") |> live("/environments")

    assert has_element?(view, ".app-sidebar .app-viewer strong", "Andrew Example")
    assert has_element?(view, ".app-sidebar .app-viewer small", "andrew@example.com")

    # Serve sends a name outside ASCII as RFC 2047 words.
    {:ok, view, _html} =
      tailnet("zoe@example.com", "=?utf-8?q?Zo=C3=AB_Smith?=") |> live("/environments")

    assert has_element?(view, ".app-viewer strong", "Zoë Smith")

    {:ok, view, _html} = localhost() |> live("/environments")
    refute has_element?(view, ".app-viewer")
  end

  defp localhost, do: build_conn() |> Map.put(:host, "localhost")

  defp tailnet(login, name) do
    localhost()
    |> put_req_header("tailscale-user-login", login)
    |> put_req_header("tailscale-user-name", name)
  end
end
