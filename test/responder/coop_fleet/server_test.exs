defmodule Responder.CoopFleet.ServerTest do
  use ExUnit.Case, async: true

  alias Responder.CoopFleet.Server

  test "the worker listener is TLS 1.3 and only enrollment may omit a client certificate" do
    directory =
      Path.join(System.tmp_dir!(), "coop-fleet-server-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    paths =
      for name <- ~w(ca.pem ca-key.pem server.pem server-key.pem), into: %{} do
        path = Path.join(directory, name)
        File.write!(path, "test")
        {name, path}
      end

    child =
      Server.child_spec(%{
        cacertfile: paths["ca.pem"],
        ca_keyfile: paths["ca-key.pem"],
        certfile: paths["server.pem"],
        checkpoint_key: :crypto.strong_rand_bytes(32),
        checkpoint_secrets: [],
        ip: {127, 0, 0, 1},
        keyfile: paths["server-key.pem"],
        port: 8443
      })

    assert %{id: Server, start: {Bandit, :start_link, [options]}} = child
    assert options[:scheme] == :https
    assert {Responder.CoopFleet.Router, router_options} = options[:plug]
    assert router_options[:enrollment_authority].cacertfile == paths["ca.pem"]
    assert router_options[:enrollment_authority].ca_keyfile == paths["ca-key.pem"]

    transport = options[:thousand_island_options][:transport_options]
    assert transport[:verify] == :verify_peer
    assert transport[:fail_if_no_peer_cert] == false
    assert transport[:cacertfile] == paths["ca.pem"]
    assert transport[:versions] == [:"tlsv1.3"]
  end

  test "gateway configuration rejects ambiguous authority network and state-tool settings" do
    directory =
      Path.join(System.tmp_dir!(), "coop-fleet-server-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    paths =
      for name <- ~w(ca.pem ca-key.pem server.pem server-key.pem), into: %{} do
        path = Path.join(directory, name)
        File.write!(path, "test")
        {name, path}
      end

    valid = [
      cacertfile: paths["ca.pem"],
      ca_keyfile: paths["ca-key.pem"],
      certfile: paths["server.pem"],
      checkpoint_key: :crypto.strong_rand_bytes(32),
      checkpoint_secrets: [],
      keyfile: paths["server-key.pem"],
      port: 8443
    ]

    assert %{ip: {127, 0, 0, 1}} = Server.options!(valid)

    assert %{ip: {0, 0, 0, 0, 0, 0, 0, 1}} =
             Server.options!(Keyword.put(valid, :ip, {0, 0, 0, 0, 0, 0, 0, 1}))

    for {configuration, message} <- [
          {nil, ~r/must be a map/},
          {[port: 8443], ~r/incomplete/},
          {valid ++ [port: 9443], ~r/unique fields/},
          {Keyword.put(valid, :port, 0), ~r/port/},
          {Keyword.put(valid, :ip, {999, 0, 0, 1}), ~r/IP/},
          {Keyword.put(valid, :certificate_ttl_seconds, 1), ~r/lifetime/},
          {Keyword.put(valid, :public_url, "http://worker.example"), ~r/HTTPS origin/},
          {Keyword.put(valid, :state_tools, %{}), ~r/state-tools/},
          {Keyword.put(valid, :certfile, "relative.pem"), ~r/certfile/}
        ] do
      assert_raise ArgumentError, message, fn -> Server.options!(configuration) end
    end

    assert %{state_tools: %{capabilities: []}} =
             Server.options!(Keyword.put(valid, :state_tools, %{capabilities: []}))
  end
end
