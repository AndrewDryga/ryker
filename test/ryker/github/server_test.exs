defmodule Ryker.GitHub.ServerTest do
  use ExUnit.Case, async: true

  alias Ryker.GitHub.{Binding, Server}

  test "builds an optional GitHub listener from trusted repository bindings" do
    options =
      Server.options!(%{
        bindings: %{
          "github-main" => %{
            authorized_actor_ids: [7, 8],
            installation_id: 41,
            repository_full_name: "octo/example",
            repository_id: 99,
            ryker_actor_id: 99,
            secret: String.duplicate("s", 32)
          }
        },
        confirmations: %{
          repositories: %{
            "ryker" => %{
              contributor_policy: %{
                digest: String.duplicate("a", 64),
                name: "ryker-contributor"
              }
            }
          }
        },
        secret: String.duplicate("s", 32),
        port: 4_081
      })

    assert options.ip == {127, 0, 0, 1}
    assert options.port == 4_081
    assert %Binding{name: "github-main"} = options.bindings["github-main"]
    assert options.confirmations.repositories["ryker"].name == "ryker-contributor"

    child =
      Server.child_spec(%{
        bindings: options.bindings,
        confirmations: options.confirmations,
        port: 4_081,
        secret: String.duplicate("s", 32)
      })

    assert child.id == Server
    assert {Bandit, :start_link, [_options]} = child.start
  end

  test "refuses empty, mismatched, or unsafe listener configuration" do
    assert_raise ArgumentError, fn ->
      Server.options!(%{bindings: %{}, port: 4_081, secret: String.duplicate("s", 32)})
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{"x" => %{}},
        port: 0,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        extra: true,
        bindings: %{},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn -> Server.options!(:invalid) end

    assert_raise ArgumentError, fn ->
      Server.options!(
        port: 4_081,
        port: 4_082,
        bindings: %{},
        secret: String.duplicate("s", 32)
      )
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{7 => %{}},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{"x" => :invalid},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{"x" => %{}},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{},
        port: 70_000,
        secret: String.duplicate("s", 32)
      })
    end

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{},
        ip: {999, 0, 0, 1},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end

    assert {:ok, binding} =
             Binding.new(%{
               authorized_actor_ids: [7, 8],
               installation_id: 41,
               name: "configured",
               repository_full_name: "octo/example",
               repository_id: 99,
               ryker_actor_id: 99,
               secret: String.duplicate("s", 32)
             })

    assert_raise ArgumentError, fn ->
      Server.options!(%{
        bindings: %{"different" => binding},
        port: 4_081,
        secret: String.duplicate("s", 32)
      })
    end
  end

  test "accepts an explicit IPv6 listener with an already validated binding" do
    assert {:ok, binding} =
             Binding.new(%{
               authorized_actor_ids: [7, 8],
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               ryker_actor_id: 99,
               secret: String.duplicate("s", 32)
             })

    assert %{ip: {0, 0, 0, 0, 0, 0, 0, 1}} =
             Server.options!(
               bindings: %{"github-main" => binding},
               ip: {0, 0, 0, 0, 0, 0, 0, 1},
               port: 4_081,
               secret: String.duplicate("s", 32)
             )
  end
end
