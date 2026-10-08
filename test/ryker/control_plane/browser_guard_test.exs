defmodule Ryker.ControlPlane.BrowserGuardTest do
  @moduledoc """
  The one browser boundary: loopback peers and local hosts only, and the
  response headers that keep a control-plane page from being framed, cached,
  or read across origins. The endpoint runs it before routing and the HTTP
  router runs it again, so a response is guarded the same way whichever
  path produced it.
  """
  use ExUnit.Case, async: true
  import Plug.Conn, only: [get_resp_header: 2]
  alias Ryker.ControlPlane.{BrowserGuard, Router}
  alias Ryker.Fixtures.ControlPlaneOptions

  @security_headers ~w(cache-control content-security-policy cross-origin-resource-policy referrer-policy x-content-type-options x-ryker-version)

  test "refuses foreign hosts before foreign peers, and both before anything else" do
    assert %{status: 421, halted: true} = guard("evil.example", {127, 0, 0, 1})
    assert %{status: 421, halted: true} = guard("evil.example", {10, 0, 0, 1})
    assert %{status: 403, halted: true} = guard("localhost", {10, 0, 0, 2})
    assert %{status: 403, halted: true} = guard("127.0.0.1", {203, 0, 113, 1})
    assert %{status: 403, halted: true} = guard("::1", {0, 0, 0, 0, 0, 0, 0, 2})

    for host <- ["localhost", "127.0.0.1", "::1"],
        peer <- [{127, 0, 0, 1}, {127, 8, 9, 10}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      assert %{status: nil, halted: false} = guard(host, peer), "#{host} from #{inspect(peer)}"
    end

    assert BrowserGuard.local_host?("localhost")
    refute BrowserGuard.local_host?("localhost.evil.example")
    assert BrowserGuard.loopback?({127, 0, 0, 1})
    refute BrowserGuard.loopback?({127, 0, 0, 1, 0})
    refute BrowserGuard.loopback?(nil)
  end

  # A refused POST answered before its body was read kept the connection open, and the server
  # then drained whatever body the refused client sent (2026-10-04 review). A refusal closes it.
  test "a refusal closes the connection rather than read a refused body" do
    for {host, peer} <- [{"evil.example", {127, 0, 0, 1}}, {"localhost", {10, 0, 0, 2}}] do
      assert get_resp_header(guard(host, peer), "connection") == ["close"]
    end

    assert get_resp_header(guard("localhost", {127, 0, 0, 1}), "connection") == []
  end

  test "container network access keeps the local-host boundary without pretending the peer is loopback" do
    access = {:network, {172, 22, 0, 1}}

    assert %{status: nil, halted: false} =
             BrowserGuard.call(conn("/", "127.0.0.1", {172, 22, 0, 1}), access: access)

    assert %{status: 421, halted: true} =
             BrowserGuard.call(conn("/", "ryker.example", {172, 22, 0, 1}), access: access)

    refute BrowserGuard.peer_allowed?({172, 22, 0, 1}, :loopback)
    assert BrowserGuard.peer_allowed?({172, 22, 0, 1}, access)
    refute BrowserGuard.peer_allowed?({172, 22, 0, 2}, access)
  end

  # In Compose the console listens on the container network, and the worker's Docker daemon
  # sits on that network too, so every Coop box that runs model work could open any console
  # page, read its confirmation tokens and act as the operator: a probe from a box got 200
  # for "/" with `Host: localhost` (2026-10-04 review). Published traffic arrives from the
  # network gateway, so that address and the container's own loopback are the only peers.
  test "a container on the Compose network other than the published gateway is refused" do
    environment = %{
      "DATABASE_URL" => "ecto://ryker:secret@localhost/ryker",
      "RYKER_CREDENTIAL_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
      "RYKER_CONTAINER" => "true",
      "RYKER_CONTROL_BIND" => "127.0.0.1",
      "RYKER_CONTROL_IP" => "0.0.0.0",
      "RYKER_CONTROL_PEER" => "172.30.42.1"
    }

    access = Ryker.Bootstrap.load!(&Map.fetch(environment, &1)).control_plane.access

    for box <- [{172, 30, 42, 7}, {172, 30, 42, 2}, {10, 0, 0, 1}] do
      assert %{status: 403, halted: true} =
               BrowserGuard.call(conn("/", "localhost", box), access: access),
             "#{inspect(box)} reached the console"
    end

    for published <- [{172, 30, 42, 1}, {127, 0, 0, 1}] do
      assert %{status: nil, halted: false} =
               BrowserGuard.call(conn("/", "localhost", published), access: access)
    end
  end

  # Andrew, 2026-10-01, of the tenant instance on mac-server: "Maybe setup tailscale service?" A
  # console published at a tailnet name would have answered every request "Misdirected request",
  # since only the loopback names were the console. The address it is published at is the console
  # too, and every other name is still refused.
  test "the console answers at the address it is published at and at no other name" do
    published = [access: {:network, {172, 22, 0, 1}}, public_host: "mac-server.example.ts.net"]
    peer = {172, 22, 0, 1}

    assert %{status: nil, halted: false} =
             BrowserGuard.call(conn("/", "mac-server.example.ts.net", peer), published)

    assert %{status: 421, halted: true} =
             BrowserGuard.call(conn("/", "evil.example", peer), published)

    assert %{status: 421, halted: true} =
             BrowserGuard.call(conn("/", "mac-server.example.ts.net", peer),
               access: {:network, peer}
             )

    options =
      ControlPlaneOptions.options(self())
      |> Map.merge(%{access: {:network, peer}, public_host: "mac-server.example.ts.net"})
      |> Router.init()

    assert Router.call(conn("/healthz", "mac-server.example.ts.net", peer), options).status == 200
    assert Router.call(conn("/healthz", "evil.example", peer), options).status == 421
  end

  # 2026-10-04 review: a console published on IPv6 loopback, which Ryker allows, answered every
  # request "Misdirected request". Bandit keeps the brackets of `Host: [::1]:4321`, as RFC 3986
  # writes an IPv6 host, and only the bare `::1` was a local name.
  test "a browser at [::1] reaches the console" do
    server =
      start_supervised!(
        {Bandit,
         plug: {Router, Router.init(ControlPlaneOptions.options(self()))},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert healthz(port, "[::1]:#{port}") =~ ~r/\AHTTP\/1\.1 200 /
    assert healthz(port, "[::2]:#{port}") =~ ~r/\AHTTP\/1\.1 421 /
  end

  test "every response carries the same browser boundary headers, refused or not" do
    # Until 2026-09-13 the HTTP router set cross-origin-resource-policy and the
    # live pages did not, because each path carried its own copy of the list.
    expected = %{
      "cache-control" => ["no-store"],
      "content-security-policy" => [
        "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
      ],
      "cross-origin-resource-policy" => ["same-origin"],
      "referrer-policy" => ["no-referrer"],
      "x-content-type-options" => ["nosniff"],
      "x-ryker-version" => ["0.1.0-dev"]
    }

    for conn <- [
          guard("localhost", {127, 0, 0, 1}),
          guard("evil.example", {127, 0, 0, 1}),
          guard("localhost", {10, 0, 0, 2})
        ] do
      assert security_headers(conn) == expected
    end

    [policy] = get_resp_header(guard("localhost", {127, 0, 0, 1}), "content-security-policy")
    directives = policy |> String.split(";") |> Enum.map(&String.trim/1)
    assert "default-src 'none'" in directives
    assert "frame-ancestors 'none'" in directives
    assert "form-action 'self'" in directives
    refute policy =~ "https:"
  end

  test "the HTTP router is guarded by the same boundary, not a copy of it" do
    options = Router.init(ControlPlaneOptions.options(self()))

    for {host, peer, status} <- [
          {"evil.example", {127, 0, 0, 1}, 421},
          {"localhost", {10, 0, 0, 2}, 403},
          {"::1", {0, 0, 0, 0, 0, 0, 0, 1}, 200}
        ] do
      routed = Router.call(conn("/healthz", host, peer), options)
      assert routed.status == status, "#{host} from #{inspect(peer)}"
      assert security_headers(routed) == security_headers(guard(host, peer))
    end

    refused = Router.call(conn("/healthz", "localhost", {10, 0, 0, 2}), options)
    assert refused.resp_body == "Loopback access only"
    refute_received {:channel_params, _}
  end

  defp guard(host, peer), do: BrowserGuard.call(conn("/", host, peer), [])

  # A request as a browser sends it, so Bandit itself reads the Host header.
  defp healthz(port, host) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, "GET /healthz HTTP/1.1\r\nhost: #{host}\r\nconnection: close\r\n\r\n")

    # The wait only bounds a hang: under the gate's load a loopback answer
    # took longer than five seconds (2026-10-08).
    {:ok, response} = :gen_tcp.recv(socket, 0, 30_000)
    :gen_tcp.close(socket)
    response
  end

  defp conn(path, host, peer) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, host)
    |> Map.put(:remote_ip, peer)
  end

  defp security_headers(conn),
    do: Map.new(@security_headers, &{&1, get_resp_header(conn, &1)})
end
