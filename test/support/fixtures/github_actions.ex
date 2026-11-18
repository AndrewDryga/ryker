defmodule Ryker.Fixtures.GitHubActions do
  @moduledoc false

  def review_thread(target, commit) do
    finding = hd(target["findings"])

    %{
      "id" => finding["thread_id"],
      "isResolved" => false,
      "pullRequest" => %{
        "number" => 7,
        "headRefOid" => commit,
        "headRefName" => "human/fix",
        "baseRefName" => "main",
        "state" => "OPEN",
        "repository" => %{"databaseId" => 17},
        "headRepository" => %{"databaseId" => 17},
        "baseRepository" => %{"databaseId" => 17}
      },
      "comments" => %{
        "nodes" => [
          %{
            "databaseId" => finding["comment_id"],
            "body" => finding["body"],
            "updatedAt" => finding["updated_at"],
            "author" => %{"databaseId" => 30},
            "commit" => %{"oid" => target["head_commit"]}
          }
        ]
      }
    }
  end

  def publication_target(attributes \\ %{}) do
    Map.merge(
      %{
        "kind" => "existing_pull_request",
        "repository_ref" => "ryker",
        "repository_id" => 17,
        "installation_id" => 41,
        "app_actor_id" => 30,
        "binding_ref" => "github-main",
        "number" => 7,
        "head_ref" => "refs/heads/human/fix",
        "base_ref" => "refs/heads/main",
        "head_commit" => String.duplicate("a", 40),
        "source_input_id" => Ecto.UUID.generate(),
        "reason" => "review_fix",
        "authorization" => %{"kind" => "github_user", "id" => 123, "login" => "example-writer"},
        "findings" => [
          %{
            "thread_id" => "thread-one",
            "body" => "Handle empty input.",
            "comment_id" => 99,
            "updated_at" => "2026-11-17T00:00:00Z",
            "path" => "lib/input.ex",
            "line" => 10,
            "url" => "https://github.com/example/repository/pull/7#discussion_r99"
          }
        ]
      },
      attributes
    )
  end
end

defmodule Ryker.Fixtures.GitHubActions.Requester do
  @moduledoc false
  def request(http, :get, "/user", nil, _headers) do
    send(self(), :user_checked)

    case http.token_provider.() do
      {:ok, "revoked-token"} -> {:ok, %{status: 401, body: %{}}}
      _token -> {:ok, %{status: 200, body: %{"id" => 7, "login" => "ada", "type" => "User"}}}
    end
  end

  def request(http, :get, "/repos/acme/widget", nil, _headers) do
    send(self(), :repository_checked)
    {:ok, token} = http.token_provider.()
    repository_id = if token == "wrong-repository", do: 100, else: 99

    {:ok,
     %{
       status: 200,
       body: %{"id" => repository_id, "permissions" => %{"push" => token == "writer-token"}}
     }}
  end

  def request(_http, :get, "/repos/acme/widget/issues/12", nil, _headers) do
    {:ok,
     %{
       status: 200,
       body: %{
         "id" => 31,
         "number" => 12,
         "state" => "open",
         "title" => "Handle empty input",
         "body" => Process.get(:github_issue_body, "Handle empty input."),
         "updated_at" => "2026-11-17T12:00:00Z"
       }
     }}
  end

  def request(_http, :post, "/graphql", document, _headers) do
    send(self(), {:review_read, document["variables"]})
    head = String.duplicate("a", 40)

    comment = %{
      "databaseId" => 901,
      "body" => "Handle empty input.",
      "updatedAt" => "2026-11-17T12:00:00Z",
      "url" => "https://github.com/acme/widget/pull/42#discussion_r901",
      "author" => %{"login" => "ryker-test[bot]", "databaseId" => 4321},
      "commit" => %{"oid" => head},
      "reactionGroups" => [%{"content" => "THUMBS_UP", "viewerHasReacted" => true}]
    }

    thread = %{
      "id" => "thread-one",
      "isResolved" => false,
      "isOutdated" => false,
      "path" => "lib/example.ex",
      "line" => 12,
      "comments" => %{"nodes" => [comment]}
    }

    threads =
      case Process.get(:review_finding_count, 1) do
        1 -> [thread]
        count -> Enum.map(1..count, &Map.put(thread, "id", "thread-#{&1}"))
      end

    pull = %{
      "url" => "https://github.com/acme/widget/pull/42",
      "headRefOid" => head,
      "headRefName" => "fix-input",
      "baseRefName" => "main",
      "state" => "OPEN",
      "repository" => %{"databaseId" => 99},
      "baseRepository" => %{"databaseId" => 99},
      "headRepository" => %{"nameWithOwner" => "acme/widget", "databaseId" => 99},
      "reviewThreads" => %{
        "nodes" => threads,
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      }
    }

    {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => pull}}}}}
  end
end

defmodule Ryker.Fixtures.GitHubActions.TriageRequester do
  @moduledoc false
  alias Ryker.Fixtures.GitHubActions.Requester

  def request(_http, :get, "/repos/acme/widget", nil, _headers),
    do: {:ok, %{status: 200, body: %{"id" => 99}}}

  def request(http, :get, "/repos/acme/widget/issues/12" = path, nil, headers) do
    {:ok, response} = Requester.request(http, :get, path, nil, headers)

    body =
      if Process.get(:triage_issue_changed),
        do: Map.put(response.body, "title", "A newer report"),
        else: response.body

    {:ok, %{response | body: body}}
  end

  def request(_http, :get, "/repos/acme/widget/issues/13", nil, _headers) do
    {:ok,
     %{
       status: 200,
       body: %{
         "id" => 32,
         "number" => 13,
         "title" => "Empty input in export",
         "body" => "An empty input should return no rows.",
         "state" => "closed",
         "updated_at" => "2026-11-17T12:00:00Z"
       }
     }}
  end

  def request(_http, :get, path, nil, _headers)
      when path in [
             "/repos/acme/widget/issues/12/comments?page=1&per_page=20",
             "/repos/acme/widget/issues/13/comments?page=1&per_page=20"
           ],
      do: {:ok, %{status: 200, body: []}}

  def request(_http, :get, "/repos/acme/widget/labels?per_page=100&page=1", nil, _headers),
    do: {:ok, %{status: 200, body: [%{"name" => "bug"}]}}

  def request(_http, :get, "/repos/acme/widget/labels/bug", nil, _headers),
    do: {:ok, %{status: 200, body: %{"name" => "bug"}}}

  def request(_http, :post, "/repos/acme/widget/issues/12/labels", body, _headers) do
    send(self(), {:triage_labels, body})

    if Process.get(:triage_labels_denied),
      do: {:ok, %{status: 403, body: %{"message" => "Permission denied"}}},
      else: {:ok, %{status: 200, body: [%{"name" => "human-label"}, %{"name" => "bug"}]}}
  end
end
