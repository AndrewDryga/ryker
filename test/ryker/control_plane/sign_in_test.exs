defmodule Ryker.ControlPlane.SignInTest do
  @moduledoc """
  Andrew, 2026-10-13: "we should not use CF or anything else for auth - we can do it ourselves,
  CF/Tailscale should be only used for tunneling by default". A tunnel's requests reach the
  console just as a browser on this machine does, so nobody uses it without signing in, here
  too, and a sign-in link signs its person in once. A console reached any other way would hand
  everyone with the tunnel's address every conversation Ryker keeps.
  """
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2, put_private: 3, put_req_header: 3]
  import Ryker.ConsoleSignIn, only: [session_token: 1, signed_in_conn: 0]
  alias Ryker.ConsoleAccess
  alias Ryker.ControlPlane.{Actions, Endpoint, LiveSocket, Projection, WorkbenchLive}
  alias Ryker.Settings

  @endpoint Endpoint
  @published "ryker.example.com"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "sign-in-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{
           health: fn -> {:ok, %{}} end,
           ready: fn -> {:ok, %{}} end,
           metrics: fn -> {:ok, "ryker_up 1\n"} end
         },
         csrf_secret: String.duplicate("s", 32),
         public_host: @published,
         public_https: true
       }}
    )

    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
  end

  test "nobody uses the console without signing in, on this machine too" do
    for host <- ["localhost", "127.0.0.1", @published] do
      page = build_conn() |> Map.put(:host, host) |> get("/activity?q=deploy")
      assert page.status == 303
      assert get_resp_header(page, "location") == ["/sign-in"]

      action = build_conn() |> Map.put(:host, host) |> post("/conversations/x/messages", %{})
      assert action.status == 403
    end

    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(local(), "/settings/access")
  end

  # The deploy script, the watchdog and Compose's healthcheck read these without anyone signed
  # in. Metrics stay with this machine: through a tunnel they need a person.
  test "health, readiness and the stylesheets need no sign-in; metrics only at a loopback name" do
    assert get(local(), "/healthz").status == 200
    assert get(local(), "/readyz").status == 200
    assert get(local(), "/metrics").resp_body == "ryker_up 1\n"
    assert get(published(), "/healthz").status == 200
    assert get(published(), "/metrics").status == 303
    assert get(local(), "/assets/control-plane.css").status == 200
  end

  # Slack opens a link to preview it before anyone clicks, so opening a link must not use it.
  test "a link's page signs nobody in until its button is pressed, then opens the page asked for" do
    asked = get(local(), "/activity?q=deploy")
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    path = URI.parse(url).path

    preview = asked |> recycle() |> Map.put(:host, "localhost") |> get(path)
    assert preview.status == 200
    assert preview.resp_body =~ "This link signs you in as <strong>Dana</strong>"
    assert {:ok, _link} = ConsoleAccess.fetch_link(token(path))

    # Another site's form can't sign this browser in as whoever's link it holds.
    assert_error_sent(403, fn -> press(preview, path, %{}) end)
    assert {:ok, _link} = ConsoleAccess.fetch_link(token(path))

    signed = press(preview, path, %{"_csrf_token" => csrf_token(preview)})
    assert signed.status == 303
    assert get_resp_header(signed, "location") == ["/activity?q=deploy"]
    assert ConsoleAccess.fetch_link(token(path)) == {:error, :used}

    opened = signed |> recycle() |> Map.put(:host, "localhost") |> get("/activity")
    assert opened.status == 200
  end

  test "a link that was used, expired or never was says where a new one comes from" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    path = URI.parse(url).path
    {:ok, _session_token, _session, _link} = ConsoleAccess.sign_in(token(path))

    used = get(local(), path)
    assert used.status == 410
    assert used.resp_body =~ "This link was used already"
    assert used.resp_body =~ "<code>/ryker sign-in</code>"

    {:ok, invite} = ConsoleAccess.invite("Sam", "control-plane:owner:owner")
    now = Repo.now!()

    Repo.update_all(ConsoleAccess.Link,
      set: [inserted_at: DateTime.add(now, -3_600, :second), expires_at: DateTime.add(now, -1)]
    )

    expired = get(local(), URI.parse(invite).path)
    assert expired.status == 410
    assert expired.resp_body =~ "This link has expired"
    assert expired.resp_body =~ "Ask whoever invited you for a new one."

    assert get(local(), "/sign-in/" <> String.duplicate("a", 43)).status == 404
  end

  test "the sign-in page says how to sign in, and a signed-in browser goes on to the console" do
    page = get(local(), "/sign-in")
    assert page.status == 200
    assert page.resp_body =~ "<code>/ryker sign-in</code>"
    assert page.resp_body =~ "<code>scripts/compose.sh sign-in</code>"

    signed = signed_in_conn() |> Map.put(:host, "localhost") |> get("/sign-in")
    assert get_resp_header(signed, "location") == ["/"]
  end

  test "signing out ends this browser's session, and its pages ask to sign in again" do
    conn = signed_in_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/activity")

    view |> element("#sign-out") |> render_click()

    assert_redirect(view, "/sign-in")
    assert ConsoleAccess.sessions() == []
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/activity")
  end

  # Sign out ended the session and closed the page's socket before its redirect reached Chrome,
  # which reconnected over and over: the socket refused every try, so the page never left
  # (2026-10-13, the first deploy). The socket takes the page back, and the page, mounting with a
  # session that signs nobody in, goes to the sign-in page. A session ended from Settings › Access
  # reaches its other pages the same way.
  test "a page whose session ended reconnects and goes to the sign-in page" do
    token = session_token("Dana")
    page = %{"console_session" => token}
    {:ok, _id} = ConsoleAccess.sign_out(token)

    assert {:ok, _socket} =
             LiveSocket.connect(%{}, %Phoenix.Socket{}, %{
               peer_data: %{address: {127, 0, 0, 1}},
               uri: URI.parse("http://localhost:4321/live"),
               session: page
             })

    assert {:ok, %{redirected: {:redirect, %{to: "/sign-in"}}}} =
             WorkbenchLive.mount(%{}, page, %Phoenix.LiveView.Socket{endpoint: Endpoint})
  end

  # People outside Slack get in by an invite, and anyone signed in can end a browser's session.
  test "Access invites someone with a link shown once, and signs another browser out" do
    other = session_token("Dana")
    {:ok, view, _html} = live(signed_in_conn() |> Map.put(:host, "localhost"), "/settings/access")

    assert has_element?(view, "#signed-in .entity-row", "Dana")
    assert has_element?(view, "#signed-in .entity-row", "This browser")

    view |> form("#invite-form", invite: %{name: "Sam from Acme"}) |> render_submit()

    assert has_element?(view, ".secret-reveal", "Invite link for Sam from Acme")
    assert [%{person_name: "Sam from Acme"} = invite] = ConsoleAccess.open_invites()
    assert has_element?(view, "#invite-#{invite.id}")

    view |> element("#invite-#{invite.id} button", "Withdraw") |> render_click()
    assert ConsoleAccess.open_invites() == []

    [dana] = Enum.filter(ConsoleAccess.sessions(), &(&1.person_name == "Dana"))
    view |> element("#session-#{dana.id} button", "Sign out") |> render_click()

    assert ConsoleAccess.fetch_session(other) == {:error, :not_found}
    refute has_element?(view, "#session-#{dana.id}")
  end

  # The Sign in button as a browser presses it: the form's body still to be read, and the forgery
  # check on, which Phoenix's test connections switch off. Posted as a map with the check off, the
  # first deploy's sign-in passed here while every browser got a bare 403: the console never
  # parsed the form, so the check never saw its token.
  defp press(conn, path, form) do
    conn
    |> recycle()
    |> Map.put(:host, "localhost")
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(form))
  end

  defp local, do: Map.put(build_conn(), :host, "localhost")
  defp published, do: Map.put(build_conn(), :host, @published)

  defp token(path) do
    "/sign-in/" <> token = path
    token
  end

  defp csrf_token(conn) do
    [value] =
      conn.resp_body
      |> LazyHTML.from_document()
      |> LazyHTML.query("input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    value
  end
end
