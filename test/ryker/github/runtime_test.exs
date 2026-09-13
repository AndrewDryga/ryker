defmodule Ryker.GitHub.RuntimeTest do
  use ExUnit.Case, async: true

  alias Ryker.GitHub.{InstallationTokens, Runtime, Server}

  defmodule Requester do
    def request(_client, _method, _path, _document, _headers), do: {:error, :not_used}
  end

  test "builds the repository-scoped credential provider before the webhook listener" do
    options = Runtime.options!(configuration())

    assert options.tokens.bindings == %{
             "github-main" => %{installation_id: 41, repository_id: 99}
           }

    assert options.server.port == 4_081

    assert {:ok, {flags, children}} = Runtime.init(options)
    assert flags.strategy == :one_for_one
    assert Enum.map(children, & &1.id) == [InstallationTokens, Server]

    assert Runtime.options!(Map.to_list(configuration())).server.bindings["github-main"].name ==
             "github-main"
  end

  test "refuses incomplete, crossed, or duplicated runtime configuration" do
    for invalid <- [
          %{},
          Map.delete(configuration(), :server),
          Map.put(configuration(), :extra, true),
          :invalid
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(server: configuration().server, server: configuration().server)
    end
  end

  defp configuration do
    %{
      server: %{
        bindings: %{
          "github-main" => %{
            authorized_actor_ids: [7],
            installation_id: 41,
            repository_full_name: "octo/example",
            repository_id: 99,
            responder_actor_id: 99,
            secret: String.duplicate("s", 32)
          }
        },
        port: 4_081,
        secret: String.duplicate("s", 32)
      },
      tokens: %{
        app_http: :app_http,
        bindings: %{"github-main" => %{installation_id: 41, repository_id: 99}},
        name: nil,
        requester: Requester
      }
    }
  end
end
