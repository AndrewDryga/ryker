defmodule Ryker.ControlPlane.CloudflareViewerLiveTest do
  @moduledoc """
  Andrew, 2026-10-04: two client teams sign in to the second install's console
  with Google through Cloudflare Access, since joining his tailnet would make
  them switch Tailscale accounts back and forth. Published that way, the console
  names the person Access let in, records what they change as theirs, and turns
  away a request at that address that did not come through Access.
  """
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 1, put_req_header: 3]
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, ConsolePeople, Endpoint, LiveSocket, Projection, Viewer}
  alias Ryker.Settings

  @endpoint Endpoint
  @published "ryker-tenant.example.com"
  @audience String.duplicate("c", 64)

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    jwks = %{"keys" => [jwk(key)]}
    # Keys are kept per team for the life of the node, so each test signs for a team of its own.
    team = "tenant-#{System.unique_integer([:positive])}.cloudflareaccess.com"

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "cloudflare-viewer-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32),
         public_host: @published,
         cloudflare_access: %{
           team_domain: team,
           audience: @audience,
           certs: fn ^team -> {:ok, jwks} end
         }
       }}
    )

    %{key: {key, team}}
  end

  test "the sidebar names the person Access let in, by the email it signed", %{key: key} do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    {:ok, view, _html} = key |> signed_in("dev@tenant.example") |> live("/environments")

    assert has_element?(view, ".app-viewer strong", "dev@tenant.example")
    refute has_element?(view, ".app-viewer small")

    assert has_element?(
             view,
             ~s(.app-viewer[title="Signed in through Cloudflare Access as dev@tenant.example"])
           )

    assert ConsolePeople.names(["dev@tenant.example"]) == %{
             "dev@tenant.example" => "dev@tenant.example"
           }
  end

  test "what a person Access let in changes is recorded as theirs", %{key: key} do
    {:ok, view, _html} = key |> signed_in("dev@tenant.example") |> live("/setup")
    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert Settings.fetch!().installation.saved_by ==
             "control-plane:cloudflare:dev@tenant.example"

    assert ConsolePeople.person("cloudflare:dev@tenant.example").name == "dev@tenant.example"

    request = signed_in(key, "dev@tenant.example")
    console = Endpoint.config(:control_plane)
    assert Viewer.actor_ref(request, console) == "control-plane:cloudflare:dev@tenant.example"
  end

  # Access adds its token to every request it lets through, so a request at the published address
  # without a valid one came some other way. Tailscale's headers there name nobody: the console
  # trusts the service it is published through, and only that one.
  test "a request at the published address without a token Access signed is turned away",
       %{key: key} do
    for conn <- [
          build_conn() |> Map.put(:host, @published),
          build_conn()
          |> Map.put(:host, @published)
          |> put_req_header("tailscale-user-login", "mallory@example.com"),
          build_conn()
          |> Map.put(:host, @published)
          |> put_req_header("cf-access-jwt-assertion", "forged.token.value"),
          signed_in(
            {:public_key.generate_key({:rsa, 2048, 65_537}), elem(key, 1)},
            "mallory@example.com"
          )
        ] do
      refused = get(conn, "/environments")
      assert refused.status == 403
      assert refused.resp_body == "Sign in through Cloudflare Access"
    end

    # The local console is reached by loopback and needs no sign-in, as before.
    local = build_conn() |> Map.put(:host, "localhost") |> get("/setup")
    assert local.status == 200

    assert signed_in(key, "dev@tenant.example") |> get("/setup") |> Map.get(:status) == 200
  end

  # Phoenix answers the live socket before the endpoint's plugs, so the check that turns away a
  # page request at the published address without an Access token never saw the socket: a held
  # session cookie reconnected there with no current sign-in (2026-10-04 review).
  test "the live socket at the published address needs a current Access sign-in", %{key: key} do
    socket = %Phoenix.Socket{}

    at = fn host, session ->
      %{
        peer_data: %{address: {127, 0, 0, 1}},
        uri: URI.parse("https://#{host}/live"),
        session: session
      }
    end

    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    page = key |> signed_in("dev@tenant.example") |> get("/environments")
    session = get_session(page)
    expired = put_in(session, ["viewer", "until"], System.os_time(:second) - 1)
    tailscale = %{"viewer" => %{"login" => "m@example.com", "name" => "M", "via" => "tailscale"}}

    assert {:ok, _socket} = LiveSocket.connect(%{}, socket, at.(@published, session))

    for refused <- [%{}, expired, tailscale],
        do: assert(LiveSocket.connect(%{}, socket, at.(@published, refused)) == :error)

    # The local console needs no sign-in, its socket included.
    assert {:ok, _socket} = LiveSocket.connect(%{}, socket, at.("localhost", %{}))
  end

  # The socket checks the sign-in when it connects, so a page left open went on
  # taking actions after the sign-in ended (IL-15, 2026-10-07).
  test "an open page reloads through Access when its sign-in ends", %{key: key} do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    # Access counts a token a minute past its expiry, so this sign-in ends a
    # second after the page opens.
    ending = token(elem(key, 0), elem(key, 1), "dev@tenant.example", System.os_time(:second) - 59)

    {:ok, view, _html} =
      build_conn()
      |> Map.put(:host, @published)
      |> put_req_header("cf-access-jwt-assertion", ending)
      |> live("/environments")

    assert_redirect(view, "/environments", 3_000)

    # The reload returns to the page and query the person had open.
    {:ok, view, _html} = key |> signed_in("dev@tenant.example") |> live("/activity?q=deploy")
    send(view.pid, :sign_in_ended)
    assert_redirect(view, "/activity?q=deploy")
  end

  defp signed_in({key, team}, email) do
    build_conn()
    |> Map.put(:host, @published)
    |> put_req_header("cf-access-jwt-assertion", token(key, team, email))
  end

  defp token(key, team, email, expires \\ System.os_time(:second) + 600) do
    now = System.os_time(:second)

    claims = %{
      "aud" => [@audience],
      "email" => email,
      "exp" => expires,
      "iat" => now,
      "iss" => "https://" <> team,
      "nbf" => now,
      "type" => "app"
    }

    signing_input = encode(%{"alg" => "RS256", "kid" => "current"}) <> "." <> encode(claims)

    signing_input <>
      "." <> Base.url_encode64(:public_key.sign(signing_input, :sha256, key), padding: false)
  end

  defp jwk(key) do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _dp, _dq, _qi, _other} = key

    %{
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false),
      "kid" => "current",
      "kty" => "RSA",
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false)
    }
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
