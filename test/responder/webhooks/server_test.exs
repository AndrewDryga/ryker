defmodule Responder.Webhooks.ServerTest do
  use ExUnit.Case, async: true

  alias Responder.Webhooks.{Route, Server}

  test "builds one explicit listener and derives route names from trusted configuration" do
    options =
      Server.options!(%{
        port: 4_080,
        routes: %{
          "universal" => %{
            auth: {:bearer, "a-secret-token-long-enough"},
            destination: %{
              conversation_ref: "slack:T123:C456",
              thread_ref: nil,
              transport: "slack"
            }
          }
        }
      })

    assert options.ip == {127, 0, 0, 1}
    assert options.port == 4_080
    assert %Route{name: "universal"} = options.routes["universal"]

    child =
      Server.child_spec(
        port: 4_080,
        routes: %{"universal" => options.routes["universal"]}
      )

    assert child.id == Server
    assert {Bandit, :start_link, [_bandit_options]} = child.start
  end

  test "refuses ambiguous or unsafe listener configuration" do
    assert_raise ArgumentError, fn -> Server.options!(%{port: 0, routes: %{}}) end
    assert_raise ArgumentError, fn -> Server.options!(%{port: 4_080, routes: %{}}) end

    assert_raise ArgumentError, fn ->
      Server.options!(%{extra: true, port: 4_080, routes: %{"x" => %{}}})
    end

    assert_raise ArgumentError, fn -> Server.options!("not configuration") end

    assert_raise ArgumentError, fn ->
      Server.options!(port: 4_080, port: 4_081, routes: %{"x" => %{}})
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{ip: :all, port: 4_080, routes: %{"x" => %{}}})
    end

    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, "a-secret-token-long-enough"},
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "configured-name"
             })

    assert_raise ArgumentError, fn ->
      Server.options!(%{port: 4_080, routes: %{"different-name" => route}})
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{port: 4_080, routes: %{123 => %{}}})
    end
  end

  test "accepts a bounded IPv6 listener" do
    options =
      Server.options!(%{
        ip: {0, 0, 0, 0, 0, 0, 0, 1},
        port: 4_080,
        routes: %{
          "universal" => %{
            auth: {:bearer, "a-secret-token-long-enough"},
            destination: %{
              conversation_ref: "slack:T123:C456",
              thread_ref: nil,
              transport: "slack"
            }
          }
        }
      })

    assert options.ip == {0, 0, 0, 0, 0, 0, 0, 1}
  end
end
