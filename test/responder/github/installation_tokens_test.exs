defmodule Responder.GitHub.InstallationTokensTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.InstallationTokens

  defmodule FakeRequester do
    def request(agent, method, path, document, headers) do
      Agent.get_and_update(agent, fn %{calls: calls, responses: [response | responses]} = state ->
        {response,
         %{state | calls: calls ++ [{method, path, document, headers}], responses: responses}}
      end)
    end
  end

  @now ~U[2026-08-29 12:00:00Z]

  test "mints one repository-scoped installation token and refreshes before expiry" do
    clock = start_supervised!({Agent, fn -> @now end}, id: :installation_token_clock)

    requester =
      start_supervised!(
        {
          Agent,
          fn ->
            %{
              calls: [],
              responses: [
                token_response("token-one", DateTime.add(@now, 3_600, :second)),
                token_response("token-two", DateTime.add(@now, 7_200, :second))
              ]
            }
          end
        },
        id: :installation_token_requester
      )

    provider =
      start_supervised!({
        InstallationTokens,
        %{
          app_http: requester,
          bindings: %{
            "github-main" => %{installation_id: 41, repository_id: 99}
          },
          clock: fn -> Agent.get(clock, & &1) end,
          name: nil,
          requester: FakeRequester
        }
      })

    assert InstallationTokens.token(provider, "github-main", :delivery) == {:ok, "token-one"}
    assert InstallationTokens.token(provider, "github-main", :delivery) == {:ok, "token-one"}
    assert length(Agent.get(requester, & &1.calls)) == 1

    Agent.update(clock, fn now -> DateTime.add(now, 3_301, :second) end)

    assert InstallationTokens.token(provider, "github-main", :delivery) == {:ok, "token-two"}

    assert [
             {:post, "/app/installations/41/access_tokens",
              %{
                "permissions" => %{"issues" => "write", "pull_requests" => "write"},
                "repository_ids" => [99]
              }, first_headers},
             {:post, "/app/installations/41/access_tokens",
              %{
                "permissions" => %{"issues" => "write", "pull_requests" => "write"},
                "repository_ids" => [99]
              }, second_headers}
           ] = Agent.get(requester, & &1.calls)

    assert first_headers == second_headers
    assert {"accept", "application/vnd.github+json"} in first_headers
    assert {"x-github-api-version", "2022-11-28"} in first_headers
  end

  test "serializes a refresh stampede and fails closed for unknown bindings" do
    requester =
      start_supervised!({
        Agent,
        fn ->
          %{
            calls: [],
            responses: [token_response("shared-token", DateTime.add(@now, 3_600, :second))]
          }
        end
      })

    provider =
      start_supervised!({
        InstallationTokens,
        %{
          app_http: requester,
          bindings: %{"github-main" => %{installation_id: 41, repository_id: 99}},
          clock: fn -> @now end,
          name: nil,
          requester: FakeRequester
        }
      })

    results =
      1..20
      |> Task.async_stream(
        fn _index -> InstallationTokens.token(provider, "github-main", :delivery) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [{:ok, "shared-token"}]
    assert length(Agent.get(requester, & &1.calls)) == 1

    assert InstallationTokens.token(provider, "missing", :delivery) ==
             {:error, {:github_installation_token_unavailable, :binding}}
  end

  test "keeps a still-valid cached token when refresh is transiently unavailable" do
    clock = start_supervised!({Agent, fn -> @now end}, id: {:clock, make_ref()})

    {provider, requester} =
      provider_with(
        [
          token_response("fallback-token", DateTime.add(@now, 3_600, :second)),
          {:error, :timeout}
        ],
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert InstallationTokens.token(provider, "github-main", :delivery) ==
             {:ok, "fallback-token"}

    Agent.update(clock, &DateTime.add(&1, 3_350, :second))

    assert InstallationTokens.token(provider, "github-main", :delivery) ==
             {:ok, "fallback-token"}

    assert length(Agent.get(requester, & &1.calls)) == 2
  end

  test "fails closed for malformed provider responses and clocks" do
    responses = [
      {:ok, %{status: 503}},
      {:ok, %{status: :invalid}},
      {:error, :closed},
      :invalid,
      {:ok, %{body: %{}, status: 201}},
      {:ok,
       %{
         body: %{"expires_at" => DateTime.to_iso8601(@now), "token" => "expired"},
         status: 201
       }}
    ]

    for response <- responses do
      {provider, _requester} = provider_with([response])

      assert {:error, {:github_installation_token_unavailable, _reason}} =
               InstallationTokens.token(provider, "github-main", :delivery)
    end

    for clock <- [fn -> :invalid end, fn -> raise "clock failed" end] do
      {provider, _requester} = provider_with([], clock: clock)

      assert {:error, {:github_installation_token_unavailable, _reason}} =
               InstallationTokens.token(provider, "github-main", :delivery)
    end

    assert InstallationTokens.token(self(), "github-main", :invalid) ==
             {:error, {:github_installation_token_unavailable, :purpose}}

    assert InstallationTokens.token(self(), :invalid, :delivery) ==
             {:error, {:github_installation_token_unavailable, :binding}}

    assert {:error, {:github_installation_token_unavailable, _reason}} =
             InstallationTokens.token("github-main", :delivery)
  end

  test "purpose-scoped credentials never share cache entries or permission grants" do
    {provider, requester} =
      provider_with([
        token_response("delivery-token", DateTime.add(@now, 3_600, :second)),
        token_response("publication-token", DateTime.add(@now, 3_600, :second)),
        token_response("repository-token", DateTime.add(@now, 3_600, :second))
      ])

    assert InstallationTokens.token(provider, "github-main", :delivery) ==
             {:ok, "delivery-token"}

    assert InstallationTokens.token(provider, "github-main", :publication) ==
             {:ok, "publication-token"}

    assert InstallationTokens.token(provider, "github-main", :repository_write) ==
             {:ok, "repository-token"}

    documents =
      Agent.get(requester, &Enum.map(&1.calls, fn {_m, _p, document, _h} -> document end))

    assert documents == [
             %{
               "permissions" => %{"issues" => "write", "pull_requests" => "write"},
               "repository_ids" => [99]
             },
             %{
               "permissions" => %{
                 "checks" => "read",
                 "pull_requests" => "write",
                 "statuses" => "read"
               },
               "repository_ids" => [99]
             },
             %{
               "permissions" => %{"contents" => "write"},
               "repository_ids" => [99]
             }
           ]

    assert InstallationTokens.token(provider, "github-main", :delivery) ==
             {:ok, "delivery-token"}

    assert length(Agent.get(requester, & &1.calls)) == 3
  end

  test "rejects every malformed trusted credential-provider configuration" do
    valid = %{
      app_http: :http,
      bindings: %{"github-main" => %{installation_id: 41, repository_id: 99}},
      requester: FakeRequester
    }

    assert InstallationTokens.options!(Map.to_list(valid)).bindings == valid.bindings

    invalid = [
      put_in(valid, [:bindings], %{}),
      put_in(valid, [:bindings], %{"github-main" => %{installation_id: 0, repository_id: 99}}),
      put_in(valid, [:requester], :not_a_requester),
      Map.put(valid, :clock, :not_a_clock),
      Map.put(valid, :name, "not-a-name"),
      Map.put(valid, :refresh_before_seconds, 1),
      Map.put(valid, :unknown, true),
      :invalid
    ]

    for configuration <- invalid do
      assert_raise ArgumentError, fn -> InstallationTokens.options!(configuration) end
    end

    assert_raise ArgumentError, fn ->
      InstallationTokens.options!(app_http: :http, app_http: :other)
    end
  end

  defp provider_with(responses, options \\ []) do
    requester =
      start_supervised!(
        {Agent, fn -> %{calls: [], responses: responses} end},
        id: {:installation_token_requester, make_ref()}
      )

    provider =
      start_supervised!(
        {InstallationTokens,
         %{
           app_http: requester,
           bindings: %{"github-main" => %{installation_id: 41, repository_id: 99}},
           clock: Keyword.get(options, :clock, fn -> @now end),
           name: nil,
           requester: FakeRequester
         }},
        id: {:installation_token_provider, make_ref()}
      )

    {provider, requester}
  end

  defp token_response(token, expires_at) do
    {:ok,
     %{
       body: %{"expires_at" => DateTime.to_iso8601(expires_at), "token" => token},
       headers: [],
       status: 201
     }}
  end
end
