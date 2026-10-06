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
  alias Ryker.ControlPlane.{Actions, ConsolePeople, Endpoint, Projection, Viewer}
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

  # Pages name a person on what they sent or changed, so the name Tailscale gives them is kept
  # when their page connects (2026-10-04).
  test "a tailnet user's page keeps the name Tailscale gives them" do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    {:ok, _view, _html} = tailnet("andrew@example.com", "Andrew Example") |> live("/environments")

    assert ConsolePeople.names(["andrew@example.com"]) == %{
             "andrew@example.com" => "Andrew Example"
           }

    {:ok, _view, _html} = tailnet("andrew@example.com", "Andrew Dryga") |> live("/environments")

    assert ConsolePeople.names(["andrew@example.com"]) == %{
             "andrew@example.com" => "Andrew Dryga"
           }
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

    console = %{public_host: @published}

    assert Viewer.actor_ref(request, console) == "control-plane:tailscale:andrew@example.com"
    assert Viewer.actor_ref(%{request | host: "localhost"}, console) == "control-plane:local"
    assert Viewer.actor_ref(request, %{public_host: nil}) == "control-plane:local"
  end

  # Every read of a page read the whole settings view twice, about 40 queries each: once for the
  # sidebar's setup count and again for the page, which on most pages shows no settings at all
  # (2026-10-04).
  test "a page without settings in its header reads the settings view once a read" do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    {:ok, view, _html} = served() |> live("/memory/people")

    sources =
      queries_of(view, fn ->
        send(view.pid, :reload_page)
        render(view)
      end)

    # Each read of the view reads the retention limits once; the installation
    # row is read again to check no save landed during the read.
    assert Enum.count(sources, &(&1 == "retention_settings")) == 1
  end

  # The tables a page's own process queries while `fun` runs.
  defp queries_of(view, fun) do
    parent = self()
    pid = view.pid
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ryker, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == pid, do: send(parent, {:page_query, metadata[:source]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect_queries([])
  end

  defp collect_queries(sources) do
    receive do
      {:page_query, source} -> collect_queries([source | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  defp served, do: build_conn() |> Map.put(:host, @published)

  defp tailnet(login, name) do
    served()
    |> put_req_header("tailscale-user-login", login)
    |> put_req_header("tailscale-user-name", name)
  end
end
