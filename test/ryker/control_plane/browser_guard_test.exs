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

  defp conn(path, host, peer) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, host)
    |> Map.put(:remote_ip, peer)
  end

  defp security_headers(conn),
    do: Map.new(@security_headers, &{&1, get_resp_header(conn, &1)})
end
