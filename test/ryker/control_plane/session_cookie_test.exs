defmodule Ryker.ControlPlane.SessionCookieTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Settings

  @endpoint Endpoint
  @published "ryker.tailnet.example"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "session-cookie-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32),
         public_host: @published,
         public_https: true
       }}
    )

    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
  end

  # The console's session cookie had no Secure flag, so a browser that reached it at its
  # published HTTPS address would also send it over plain HTTP there (2026-10-04 review).
  test "the session cookie is Secure at the published HTTPS address, and only there" do
    published =
      build_conn()
      |> Map.put(:host, @published)
      |> put_req_header("tailscale-user-login", "andrew@example.com")
      |> get("/environments")

    assert [cookie] = get_resp_header(published, "set-cookie")
    assert cookie =~ "_ryker_control="
    assert String.downcase(cookie) =~ "; secure"

    local = build_conn() |> Map.put(:host, "localhost") |> get("/environments")

    for cookie <- get_resp_header(local, "set-cookie"),
        do: refute(String.downcase(cookie) =~ "; secure")
  end
end
