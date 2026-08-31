defmodule Responder.StateTools.ServerTest do
  use ExUnit.Case, async: true

  alias Responder.StateTools.Server

  @token "state-tools-token-long-enough"

  test "builds an optional loopback MCP listener" do
    assert Server.options!(port: 4_083, token: @token) == %{
             capabilities: [:event_waits, :publication, :schedules],
             ip: {127, 0, 0, 1},
             port: 4_083,
             token: @token
           }

    assert %{id: Server, start: {Bandit, :start_link, [_options]}} =
             Server.child_spec(port: 4_083, token: @token)

    assert Server.options!(%{
             ip: {0, 0, 0, 0, 0, 0, 0, 1},
             port: 4_083,
             token: @token
           }).ip == {0, 0, 0, 0, 0, 0, 0, 1}

    assert Server.options!(
             emisar_rpc_url: "https://emisar.example/api/mcp/rpc",
             port: 4_083,
             token: @token
           ).emisar_rpc_url == "https://emisar.example/api/mcp/rpc"
  end

  test "refuses ambiguous or unsafe state-tool listener configuration" do
    assert_raise ArgumentError, fn -> Server.options!(%{port: 0, token: @token}) end
    assert_raise ArgumentError, fn -> Server.options!(%{port: 70_000, token: @token}) end
    assert_raise ArgumentError, fn -> Server.options!(%{ip: :all, port: 4_083, token: @token}) end

    for ip <- [{0, 0, 0, 0}, {10, 0, 0, 8}, {192, 168, 1, 5}, {0, 0, 0, 0, 0, 0, 0, 0}] do
      assert_raise ArgumentError, fn ->
        Server.options!(%{ip: ip, port: 4_083, token: @token})
      end
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{ip: {999, 0, 0, 1}, port: 4_083, token: @token})
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{extra: true, port: 4_083, token: @token})
    end

    assert_raise ArgumentError, fn -> Server.options!(:invalid) end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_083, port: 4_084, token: @token)
    end

    assert_raise ArgumentError, fn -> Server.options!(port: 4_083, token: "short") end

    assert_raise ArgumentError, fn ->
      Server.options!(
        emisar_rpc_url: "http://emisar.example/api/mcp/rpc",
        port: 4_083,
        token: @token
      )
    end
  end
end
