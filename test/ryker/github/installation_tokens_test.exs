defmodule Ryker.GitHub.InstallationTokensTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ryker.GitHub.InstallationTokens

  defmodule FakeRequester do
    def request(agent, method, path, document, headers) do
      Agent.get_and_update(agent, fn %{calls: calls, responses: [response | responses]} = state ->
        {response,
         %{state | calls: calls ++ [{method, path, document, headers}], responses: responses}}
      end)
    end
  end

  defmodule RaisingRequester do
    def request(_agent, _method, _path, _document, _headers),
      do: raise("token endpoint exploded at /app/installations/41/access_tokens")
  end

  @now ~U[2026-08-29 12:00:00Z]

  # A raise inside the token request or the clock was returned as the whole
  # exception, whose message can carry the request that failed, and that
  # reason is stored with whatever the token was for. The reason now names
  # the class alone; the log keeps the message.
  test "a raise while minting or reading the clock is reported by class, never by body" do
    {provider, _requester} = provider_with([], requester: RaisingRequester)

    log =
      capture_log(fn ->
        assert InstallationTokens.token(provider, "github-main", :delivery) ==
                 {:error, {:github_installation_token_unavailable, {:raised, RuntimeError}}}
      end)

    assert log =~ "token endpoint exploded"

    {provider, _requester} = provider_with([], clock: fn -> raise "clock failed at vault" end)

    log =
      capture_log(fn ->
        assert InstallationTokens.token(provider, "github-main", :delivery) ==
                 {:error, {:github_installation_token_unavailable, {:raised, RuntimeError}}}
      end)

    assert log =~ "clock failed at vault"
  end

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

    assert InstallationTokens.fresh_publication_token(provider, "github-main", %{
             repository_id: 99,
             installation_id: 41
           }) ==
             {:ok, %{token: "repository-token", expires_at: DateTime.add(@now, 3_600, :second)}}

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
                 "pull_requests" => "read",
                 "statuses" => "read"
               },
               "repository_ids" => [99]
             },
             %{
               "permissions" => %{"contents" => "write", "pull_requests" => "write"},
               "repository_ids" => [99]
             }
           ]

    assert InstallationTokens.token(provider, "github-main", :delivery) ==
             {:ok, "delivery-token"}

    assert length(Agent.get(requester, & &1.calls)) == 3
  end

  test "source acquisition receives only repository contents read access" do
    {provider, requester} =
      provider_with([
        token_response("source-token", DateTime.add(@now, 3_600, :second))
      ])

    assert InstallationTokens.token(provider, "github-main", :source_read) ==
             {:ok, "source-token"}

    assert [{:post, "/app/installations/41/access_tokens", document, _headers}] =
             Agent.get(requester, & &1.calls)

    assert document == %{
             "permissions" => %{"contents" => "read"},
             "repository_ids" => [99]
           }
  end

  test "worker source grants mint a fresh read-only token instead of sharing the source cache" do
    expiration = DateTime.add(@now, 3_600, :second)

    {provider, requester} =
      provider_with([
        token_response("ryker-cache-token", expiration),
        token_response("worker-one-token", expiration),
        token_response("worker-two-token", expiration)
      ])

    assert InstallationTokens.token(provider, "github-main", :source_read) ==
             {:ok, "ryker-cache-token"}

    assert InstallationTokens.fresh_source_token(provider, "github-main", %{
             repository_id: 99,
             installation_id: 41
           }) ==
             {:ok, %{token: "worker-one-token", expires_at: expiration}}

    assert InstallationTokens.fresh_source_token(provider, "github-main", %{
             repository_id: 99,
             installation_id: 41
           }) ==
             {:ok, %{token: "worker-two-token", expires_at: expiration}}

    assert InstallationTokens.token(provider, "github-main", :source_read) ==
             {:ok, "ryker-cache-token"}

    assert Agent.get(requester, &Enum.map(&1.calls, fn {_m, _p, body, _h} -> body end)) ==
             List.duplicate(
               %{"permissions" => %{"contents" => "read"}, "repository_ids" => [99]},
               3
             )
  end

  test "a changed repository binding cannot mint a worker token for another repository" do
    {provider, requester} = provider_with([])

    assert {:error, {:github_installation_token_unavailable, :binding}} =
             InstallationTokens.fresh_source_token(provider, "github-main", %{
               repository_id: 100,
               installation_id: 41
             })

    assert {:error, {:github_installation_token_unavailable, :binding}} =
             InstallationTokens.fresh_source_token(provider, "github-main", %{
               repository_id: 99,
               installation_id: 42
             })

    assert Agent.get(requester, & &1.calls) == []
  end

  test "rejects every malformed trusted credential-provider configuration" do
    valid = %{
      app_http: :http,
      bindings: %{"github-main" => %{installation_id: 41, repository_id: 99}},
      requester: FakeRequester
    }

    assert InstallationTokens.options!(Map.to_list(valid)).bindings == valid.bindings

    # A verified App with no repository added yet holds no binding, and still
    # starts so the listener can answer GitHub.
    assert InstallationTokens.options!(%{valid | bindings: %{}}).bindings == %{}

    invalid = [
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
           requester: Keyword.get(options, :requester, FakeRequester)
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
