defmodule Responder.GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.Client

  defmodule FakeRequester do
    def start(responses), do: Agent.start_link(fn -> %{requests: [], responses: responses} end)

    def request(agent, method, path, document, headers) do
      Agent.get_and_update(agent, fn state ->
        [response | remaining] = state.responses
        request = {method, path, document, headers}
        {response, %{state | requests: state.requests ++ [request], responses: remaining}}
      end)
    end

    def requests(agent), do: Agent.get(agent, & &1.requests)
  end

  test "finds an issue comment marker without mistaking pagination for absence" do
    marker = "<!-- responder-delivery:#{String.duplicate("a", 64)} -->"
    first_page = Enum.map(1..100, &%{"body" => "old #{&1}", "id" => &1})

    {:ok, requester} =
      FakeRequester.start([
        response(200, first_page),
        response(200, [%{"body" => "done\n\n#{marker}", "id" => 8_001}])
      ])

    client = client(requester)

    assert Client.find_issue_comment(client, "octo/example", 42, marker) == {:ok, 8_001}

    assert [
             {:get, "/repos/octo/example/issues/42/comments?per_page=100&page=1", nil,
              first_headers},
             {:get, "/repos/octo/example/issues/42/comments?per_page=100&page=2", nil,
              second_headers}
           ] = FakeRequester.requests(requester)

    assert second_headers == first_headers
    assert {"accept", "application/vnd.github+json"} in first_headers
    assert {"x-github-api-version", "2022-11-28"} in first_headers
  end

  test "creates issue comments, native pull reviews, and inline replies at exact targets" do
    {:ok, requester} =
      FakeRequester.start([
        response(201, %{"id" => 9_001}),
        response(201, %{"body" => "Review summary", "id" => 9_100}),
        response(201, %{"id" => 9_002})
      ])

    client = client(requester)

    assert Client.create_issue_comment(client, "octo/example", 42, "Issue reply") ==
             {:ok, 9_001}

    assert Client.create_pull_review(client, "octo/example", 42, "Review summary") ==
             {:ok, 9_100}

    assert Client.create_review_reply(client, "octo/example", 42, 8_000, "Review reply") ==
             {:ok, 9_002}

    assert [
             {:post, "/repos/octo/example/issues/42/comments", %{"body" => "Issue reply"}, _},
             {:post, "/repos/octo/example/pulls/42/reviews",
              %{"body" => "Review summary", "event" => "COMMENT"}, _},
             {:post, "/repos/octo/example/pulls/42/comments/8000/replies",
              %{"body" => "Review reply"}, _}
           ] = FakeRequester.requests(requester)
  end

  test "finds a native pull review marker across the bounded review history" do
    marker = "<!-- responder-delivery:#{String.duplicate("c", 64)} -->"
    first_page = Enum.map(1..100, &%{"body" => "old #{&1}", "id" => &1})

    {:ok, requester} =
      FakeRequester.start([
        response(200, first_page),
        response(200, [%{"body" => "summary\n\n#{marker}", "id" => 9_100}])
      ])

    assert Client.find_pull_review(client(requester), "octo/example", 42, marker) ==
             {:ok, 9_100}

    assert [
             {:get, "/repos/octo/example/pulls/42/reviews?per_page=100&page=1", nil, _},
             {:get, "/repos/octo/example/pulls/42/reviews?per_page=100&page=2", nil, _}
           ] = FakeRequester.requests(requester)
  end

  test "updates only the exact typed issue, pull review, or review comment" do
    {:ok, requester} =
      FakeRequester.start([
        response(200, %{"id" => 9_001}),
        response(200, %{"body" => "Updated summary", "id" => 9_100}),
        response(200, %{"id" => 9_002}),
        response(200, %{"id" => 8_000})
      ])

    client = client(requester)

    assert :ok = Client.update_issue_comment(client, "octo/example", 9_001, "Updated issue")
    assert :ok = Client.update_pull_review(client, "octo/example", 42, 9_100, "Updated summary")
    assert :ok = Client.update_review_comment(client, "octo/example", 9_002, "Updated review")

    assert Client.update_issue_comment(client, "octo/example", 9_003, "Crossed") ==
             {:error, {:github_protocol_error, :comment}}

    assert [
             {:patch, "/repos/octo/example/issues/comments/9001", %{"body" => "Updated issue"},
              _},
             {:put, "/repos/octo/example/pulls/42/reviews/9100", %{"body" => "Updated summary"},
              _},
             {:patch, "/repos/octo/example/pulls/comments/9002", %{"body" => "Updated review"},
              _},
             {:patch, "/repos/octo/example/issues/comments/9003", %{"body" => "Crossed"}, _}
           ] = FakeRequester.requests(requester)
  end

  test "finds only a reply belonging to the requested review thread" do
    marker = "<!-- responder-delivery:#{String.duplicate("b", 64)} -->"

    {:ok, requester} =
      FakeRequester.start([
        response(200, [
          %{"body" => marker, "id" => 9_001, "in_reply_to_id" => 7_999},
          %{"body" => "reply #{marker}", "id" => 9_002, "in_reply_to_id" => 8_000}
        ])
      ])

    assert Client.find_review_reply(client(requester), "octo/example", 42, 8_000, marker) ==
             {:ok, 9_002}
  end

  test "uses GitHub's typed reaction endpoints for issue and review comments" do
    {:ok, requester} =
      FakeRequester.start([
        response(201, %{"id" => 1}),
        response(200, %{"id" => 2})
      ])

    client = client(requester)

    assert :ok = Client.add_issue_comment_reaction(client, "octo/example", 9_001, "+1")
    assert :ok = Client.add_review_comment_reaction(client, "octo/example", 9_002, "rocket")

    assert [
             {:post, "/repos/octo/example/issues/comments/9001/reactions", %{"content" => "+1"},
              _},
             {:post, "/repos/octo/example/pulls/comments/9002/reactions",
              %{"content" => "rocket"}, _}
           ] = FakeRequester.requests(requester)
  end

  test "finds, creates, and verifies exact draft pull requests" do
    sha = String.duplicate("a", 40)

    pull = %{
      "base" => %{"ref" => "main"},
      "draft" => true,
      "head" => %{"ref" => "responder/fix-123", "sha" => sha},
      "html_url" => "https://github.com/octo/example/pull/42",
      "merged" => false,
      "number" => 42,
      "state" => "open",
      "user" => %{"id" => 99, "type" => "Bot"}
    }

    {:ok, requester} =
      FakeRequester.start([
        response(200, []),
        response(201, pull),
        response(200, pull)
      ])

    client = client(requester)

    assert :not_found =
             Client.find_open_pull_request(
               client,
               "octo/example",
               "octo",
               "responder/fix-123"
             )

    assert {:ok, created} =
             Client.create_draft_pull_request(
               client,
               "octo/example",
               "Fix retries",
               "Reviewed exact tree.",
               "responder/fix-123",
               "main"
             )

    assert created["number"] == 42
    assert created["head_sha"] == sha
    assert created["draft"]
    assert {:ok, ^created} = Client.get_pull_request(client, "octo/example", 42)

    assert [
             {:get, find_path, nil, _},
             {:post, "/repos/octo/example/pulls", create_body, _},
             {:get, "/repos/octo/example/pulls/42", nil, _}
           ] = FakeRequester.requests(requester)

    assert String.starts_with?(find_path, "/repos/octo/example/pulls?")
    query = find_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query == %{"head" => "octo:responder/fix-123", "per_page" => "100", "state" => "open"}
    assert create_body["draft"] == true
    assert create_body["head"] == "responder/fix-123"
  end

  test "pull request APIs reject crossed and malformed GitHub identities" do
    malformed = %{
      "base" => %{"ref" => "main"},
      "draft" => true,
      "head" => %{"ref" => "other", "sha" => "not-a-sha"},
      "html_url" => "https://attacker.example/pull/42",
      "merged" => false,
      "number" => 42,
      "state" => "open"
    }

    {:ok, requester} = FakeRequester.start([response(200, [malformed])])

    assert Client.find_open_pull_request(
             client(requester),
             "octo/example",
             "octo",
             "responder/fix"
           ) == {:error, {:github_protocol_error, :pull_request}}
  end

  test "reports exact pull request, check-run, and commit-status lifecycle" do
    head_sha = String.duplicate("a", 40)
    merge_sha = String.duplicate("b", 40)

    pull = %{
      "base" => %{"ref" => "main"},
      "draft" => false,
      "head" => %{"ref" => "responder/fix-123", "sha" => head_sha},
      "html_url" => "https://github.com/octo/example/pull/42",
      "merge_commit_sha" => merge_sha,
      "merged" => true,
      "merged_at" => "2026-08-28T12:00:00Z",
      "number" => 42,
      "state" => "closed",
      "user" => %{"id" => 99, "type" => "Bot"}
    }

    {:ok, requester} =
      FakeRequester.start([
        response(200, pull),
        response(200, %{
          "check_runs" => [
            %{"conclusion" => "success", "status" => "completed"},
            %{"conclusion" => nil, "status" => "in_progress"}
          ],
          "total_count" => 2
        }),
        response(200, %{"statuses" => [%{"state" => "success"}]})
      ])

    assert {:ok, status} =
             Client.get_publication_status(client(requester), "octo/example", 42)

    assert status["merged"]
    assert status["merge_sha"] == merge_sha
    assert status["merged_at"] == "2026-08-28T12:00:00Z"
    assert status["checks_state"] == "pending"
    assert status["checks_total"] == 3
    assert status["checks_passed"] == 2
    assert status["checks_failed"] == 0
    assert status["checks_url"] == "https://github.com/octo/example/pull/42/checks"

    assert [
             {:get, "/repos/octo/example/pulls/42", nil, _},
             {:get, check_path, nil, _},
             {:get, status_path, nil, _}
           ] = FakeRequester.requests(requester)

    assert check_path ==
             "/repos/octo/example/commits/#{head_sha}/check-runs?per_page=100&page=1"

    assert status_path == "/repos/octo/example/commits/#{head_sha}/status?per_page=100"
  end

  test "never turns malformed or failed GitHub responses into successful delivery" do
    {:ok, requester} =
      FakeRequester.start([
        response(500, %{"message" => "unavailable"}),
        response(201, %{"id" => "not-an-id"}),
        response(200, %{"unexpected" => true})
      ])

    client = client(requester)

    assert {:error, {:github_api_error, 500, _body}} =
             Client.create_issue_comment(client, "octo/example", 42, "reply")

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error, {:github_protocol_error, :comment}}

    assert Client.find_issue_comment(client, "octo/example", 42, "marker") ==
             {:error, {:github_protocol_error, :comments}}
  end

  test "preserves GitHub rate-limit timing while leaving ordinary forbidden responses permanent" do
    reset_at = System.system_time(:second) + 30

    {:ok, requester} =
      FakeRequester.start([
        response(
          403,
          %{"message" => "API rate limit exceeded"},
          [{"retry-after", "17"}]
        ),
        response(429, "upstream rate limit", [{"retry-after", "11"}]),
        response(429, %{"message" => "secondary rate limit"}, [
          {"x-ratelimit-remaining", "0"},
          {"x-ratelimit-reset", Integer.to_string(reset_at)}
        ]),
        response(403, %{"message" => "API rate limit exceeded"}),
        response(429, "secondary rate limit"),
        response(403, %{"message" => "Resource not accessible by integration"})
      ])

    client = client(requester)

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error,
              {:delivery_rate_limited, 17,
               {:github_api_error, 403, %{"message" => "API rate limit exceeded"}}}}

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error,
              {:delivery_rate_limited, 11, {:github_api_error, 429, "upstream rate limit"}}}

    assert {:error,
            {:delivery_rate_limited, reset_delay,
             {:github_api_error, 429, %{"message" => "secondary rate limit"}}}} =
             Client.create_issue_comment(client, "octo/example", 42, "reply")

    assert reset_delay in 1..30

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error,
              {:delivery_rate_limited, 60,
               {:github_api_error, 403, %{"message" => "API rate limit exceeded"}}}}

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error,
              {:delivery_rate_limited, 60, {:github_api_error, 429, "secondary rate limit"}}}

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error,
              {:github_api_error, 403, %{"message" => "Resource not accessible by integration"}}}
  end

  test "requires an exact requester callback and bounded trusted configuration" do
    assert Client.new(http: self(), requester: String) ==
             {:error, {:invalid_github_client, :requester}}

    assert Client.new(http: self(), requester: :not_a_module) ==
             {:error, {:invalid_github_client, :requester}}

    assert Client.new(:invalid) == {:error, {:invalid_github_client, :fields}}
  end

  test "comment, review, reaction, and pull reconciliation reject every malformed response" do
    pull = pull_request_document()

    {:ok, requester} =
      FakeRequester.start([
        response(200, [%{}]),
        response(200, [:invalid]),
        response(200, [:invalid]),
        response(201, %{}),
        response(500, %{"message" => "reaction failed"}),
        response(200, [pull, pull]),
        response(500, %{"message" => "find failed"}),
        response(500, %{"message" => "create failed"}),
        response(500, %{"message" => "get failed"})
      ])

    client = client(requester)

    assert Client.find_issue_comment(client, "octo/example", 42, "missing") == :not_found

    assert Client.find_issue_comment(client, "octo/example", 42, "marker") ==
             {:error, {:github_protocol_error, :comment}}

    assert Client.find_review_reply(client, "octo/example", 42, 8_000, "marker") ==
             {:error, {:github_protocol_error, :comment}}

    assert Client.create_issue_comment(client, "octo/example", 42, "reply") ==
             {:error, {:github_protocol_error, :comment}}

    assert {:error, {:github_api_error, 500, _}} =
             Client.add_issue_comment_reaction(client, "octo/example", 9_001, "eyes")

    assert Client.find_open_pull_request(client, "octo/example", "octo", "branch") ==
             {:error, {:github_protocol_error, {:multiple_pull_requests, 2}}}

    assert {:error, {:github_api_error, 500, _}} =
             Client.find_open_pull_request(client, "octo/example", "octo", "branch")

    assert {:error, {:github_api_error, 500, _}} =
             Client.create_draft_pull_request(
               client,
               "octo/example",
               "Title",
               "Body",
               "branch",
               "main"
             )

    assert {:error, {:github_api_error, 500, _}} =
             Client.get_pull_request(client, "octo/example", 42)
  end

  test "check and commit status summaries distinguish none, passing, failing, and malformed pages" do
    none =
      publication_status([
        response(200, %{"check_runs" => [], "total_count" => 0}),
        response(200, %{"statuses" => []})
      ])

    assert none["checks_state"] == "none"

    passing =
      publication_status([
        response(200, %{
          "check_runs" => [%{"conclusion" => "neutral", "status" => "completed"}],
          "total_count" => 1
        }),
        response(200, %{"statuses" => [%{"state" => "success"}]})
      ])

    assert passing["checks_state"] == "passing"

    failing =
      publication_status([
        response(200, %{
          "check_runs" => [%{"conclusion" => "failure", "status" => "completed"}],
          "total_count" => 1
        }),
        response(200, %{"statuses" => [%{"state" => "error"}]})
      ])

    assert failing["checks_state"] == "failing"
    assert failing["checks_failed"] == 2

    full_page =
      Enum.map(1..100, fn _ -> %{"conclusion" => nil, "status" => "queued"} end)

    assert publication_status_error([
             response(200, %{"check_runs" => full_page, "total_count" => 101}),
             response(200, %{"check_runs" => [], "total_count" => 101})
           ]) == {:error, {:github_protocol_error, :check_runs_count}}

    assert publication_status_error([response(200, %{"check_runs" => [%{}], "total_count" => 1})]) ==
             {:error, {:github_protocol_error, :check_runs}}

    assert publication_status_error([response(200, %{"unexpected" => true})]) ==
             {:error, {:github_protocol_error, :check_runs}}

    assert {:error, {:github_api_error, 503, _}} =
             publication_status_error([response(503, %{"message" => "checks offline"})])

    assert publication_status_error([
             response(200, %{"check_runs" => [], "total_count" => 0}),
             response(200, %{"statuses" => [%{}]})
           ]) == {:error, {:github_protocol_error, :commit_statuses}}

    assert publication_status_error([
             response(200, %{"check_runs" => [], "total_count" => 0}),
             response(200, %{"unexpected" => true})
           ]) == {:error, {:github_protocol_error, :commit_statuses}}
  end

  test "GitHub targets, refs, URLs, and merge timestamps are validated before use" do
    {:ok, requester} =
      FakeRequester.start([
        response(
          200,
          Map.merge(pull_request_document(), %{
            "merge_commit_sha" => String.duplicate("b", 40),
            "merged" => true,
            "merged_at" => "invalid"
          })
        ),
        response(200, []),
        response(200, %{pull_request_document() | "html_url" => 42})
      ])

    client = client(requester)

    assert Client.get_pull_request(client, "octo/example", 42) ==
             {:error, {:github_protocol_error, :pull_request}}

    assert Client.get_pull_request(client, "octo/example", 42) ==
             {:error, {:github_protocol_error, :pull_request}}

    assert Client.get_pull_request(client, "octo/example", 42) ==
             {:error, {:github_protocol_error, :pull_request}}

    for call <- [
          fn -> Client.find_issue_comment(client, "bad repository", 42, "marker") end,
          fn -> Client.find_review_reply(client, "octo/example", 42, 0, "marker") end,
          fn -> Client.create_issue_comment(client, "octo/example", -1, "body") end,
          fn -> Client.create_issue_comment(client, "octo/example", 42, "") end,
          fn -> Client.find_open_pull_request(client, "octo/example", "octo", "bad ref ..") end,
          fn ->
            Client.create_draft_pull_request(
              client,
              "invalid",
              "title",
              "body",
              "head",
              "main"
            )
          end
        ] do
      assert {:error, {:invalid_github_api_request, _field}} = call.()
    end
  end

  defp client(requester) do
    assert {:ok, client} = Client.new(http: requester, requester: FakeRequester)
    client
  end

  defp response(status, body, headers \\ []),
    do: {:ok, %{body: body, headers: headers, status: status}}

  defp publication_status(responses) do
    {:ok, requester} = FakeRequester.start([response(200, pull_request_document()) | responses])
    assert {:ok, status} = Client.get_publication_status(client(requester), "octo/example", 42)
    status
  end

  defp publication_status_error(responses) do
    {:ok, requester} = FakeRequester.start([response(200, pull_request_document()) | responses])
    Client.get_publication_status(client(requester), "octo/example", 42)
  end

  defp pull_request_document do
    %{
      "base" => %{"ref" => "main"},
      "draft" => true,
      "head" => %{"ref" => "responder/fix", "sha" => String.duplicate("a", 40)},
      "html_url" => "https://github.com/octo/example/pull/42",
      "merged" => false,
      "number" => 42,
      "state" => "open",
      "user" => %{"id" => 99, "type" => "Bot"}
    }
  end
end
