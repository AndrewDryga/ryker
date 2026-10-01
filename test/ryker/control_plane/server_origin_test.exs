defmodule Ryker.ControlPlane.ServerOriginTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.Server

  # mac-server, 2026-10-01: the tenant instance's setup page, reached through an SSH tunnel on port
  # 14321, rendered and never went live, so none of its buttons could work. The console accepted
  # a browser only at the container's own port, 4321, while Compose publishes it on
  # RYKER_CONTROL_PORT: any install that changed that port had the same dead setup page.
  test "the console accepts the browser at the address it is published on" do
    origins = origins(port: 4321, public_url: "http://127.0.0.1:14321")

    for origin <- ~w(//127.0.0.1:14321 //localhost:14321 //[::1]:14321 //127.0.0.1:4321) do
      assert origin in origins
    end
  end

  test "an address published beyond loopback is accepted only as itself" do
    origins = origins(port: 4321, public_url: "https://ryker.example.test")

    assert "//ryker.example.test:443" in origins
    refute "//localhost:443" in origins
    assert "//127.0.0.1:4321" in origins
  end

  defp origins(configuration) do
    %{start: {_endpoint, :start_link, [options]}} = Server.child_spec(configuration)
    Keyword.fetch!(options, :check_origin)
  end
end
