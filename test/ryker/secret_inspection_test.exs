defmodule Ryker.SecretInspectionTest do
  @moduledoc """
  Secrets stay out of what Ryker writes to its log.

  A crash report prints the state of the process that crashed, and `inspect`
  prints every field of a struct. The bootstrap's credential key, a GitHub
  binding's webhook secret, a webhook route's token and the fleet client's
  checkpoint key and credential values were all printed that way; and with
  `LOG_LEVEL=debug` LiveView logged the GitHub App private key and every
  token typed into a settings form (2026-10-04 review).
  """
  use ExUnit.Case, async: true

  alias Ryker.Bootstrap
  alias Ryker.CoopFleet.Client
  alias Ryker.GitHub.Binding
  alias Ryker.Webhooks.Route

  @printed [limit: :infinity, printable_limit: :infinity]

  test "the bootstrap prints neither the database URL nor the credential key" do
    key = String.duplicate("k", 32)

    bootstrap =
      Bootstrap.load!(fn
        "DATABASE_URL" -> {:ok, "ecto://ryker:database-password@db/ryker"}
        "RYKER_CREDENTIAL_KEY" -> {:ok, Base.encode64(key)}
        _name -> :error
      end)

    printed = inspect(bootstrap, @printed)
    refute printed =~ "database-password"
    refute printed =~ key
  end

  test "a GitHub binding does not print its webhook secret" do
    secret = "webhook-secret-" <> String.duplicate("s", 32)

    {:ok, binding} =
      Binding.new(%{
        installation_id: 41,
        name: "github-main",
        repository_full_name: "octo/example",
        repository_id: 99,
        ryker_actor_id: 99,
        secret: secret
      })

    refute inspect(binding, @printed) =~ secret
  end

  test "a webhook route does not print its token or signing secret" do
    for auth <- [{:bearer, "bearer-token-long-enough"}, {:hmac_sha256, String.duplicate("h", 32)}] do
      {kind, secret} = auth

      {:ok, route} =
        Route.new(%{
          auth: {kind, Ryker.Secret.new(secret)},
          destination: %{conversation_ref: "slack:T123:C456", thread_ref: nil, transport: "slack"},
          name: "universal"
        })

      refute inspect(route, @printed) =~ elem(auth, 1)
    end
  end

  test "the fleet client prints neither its checkpoint key nor the credentials it redacts" do
    {:ok, client} =
      Client.new(
        checkpoint_key: String.duplicate("c", 32),
        checkpoint_secrets: ["slack-bot-token-value"],
        workspace_ref: "workspace-main"
      )

    printed = inspect(client, @printed)
    refute printed =~ String.duplicate("c", 32)
    refute printed =~ "slack-bot-token-value"
  end

  # Every secret field a console form posts, found in the templates themselves,
  # so a new one is covered or this fails: password inputs and the GitHub App
  # private key, which a file picker copies into a hidden field.
  test "every secret a console form posts is filtered from logged parameters" do
    names =
      Path.wildcard("lib/ryker/control_plane/**/*.ex")
      |> Enum.flat_map(&(&1 |> File.read!() |> secret_field_names()))
      |> Enum.uniq()

    assert "connection[private_key]" in names
    assert length(names) >= 5

    for name <- names do
      [form, field] = Regex.run(~r/\A(\w+)\[(\w+)\]\z/, name, capture: :all_but_first)
      params = %{form => %{field => "typed-secret"}}

      assert Phoenix.Logger.filter_values(params) == %{form => %{field => "[FILTERED]"}},
             "#{name} reaches the log"
    end
  end

  defp secret_field_names(source) do
    ~r/<(?:input|textarea)\b[^>]*>/s
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.filter(&(&1 =~ ~s(type="password") or &1 =~ "private_key"))
    |> Enum.flat_map(&Regex.run(~r/name="([^"]+)"/, &1, capture: :all_but_first))
  end
end
