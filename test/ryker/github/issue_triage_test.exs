defmodule Ryker.GitHub.IssueTriageTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.Client

  test "backfill excludes pull requests and exposes the bounded page boundary" do
    {:ok, client} = Client.new(%{http: :page, requester: __MODULE__.Requester})

    assert Client.IssueTriage.page(client, "acme/widget", 1) ==
             {:ok, %{numbers: [12], complete: true}}

    assert_received {:get,
                     "/repos/acme/widget/issues?state=all&sort=created&direction=desc&per_page=20&page=1",
                     nil}
  end

  test "large discussions remain bounded with explicit truncation" do
    {:ok, client} = Client.new(%{http: :large, requester: __MODULE__.Requester})
    assert {:ok, document} = Client.IssueTriage.read(client, "acme/widget", 12)
    assert byte_size(Ryker.CanonicalJSON.encode!(document)) < 131_072
    assert byte_size(document["issue"]["body"]) == 30_000
    refute document["issue"]["body_truncated"]
    assert document["discussion"]["coverage"]["status"] == "partial"

    assert Enum.all?(
             document["discussion"]["items"],
             &(byte_size(&1["body"]) == 2000 and &1["body_truncated"])
           )
  end

  test "a pull request cannot enter issue triage through the shared issues endpoint" do
    {:ok, client} = Client.new(%{http: :pull, requester: __MODULE__.Requester})
    assert Client.IssueTriage.read(client, "acme/widget", 12) == {:error, :issue_unavailable}
    refute_received {:get, "/repos/acme/widget/issues/12/comments?page=1&per_page=20", nil}
  end

  defmodule Requester do
    @moduledoc false
    alias Ryker.Fixtures.GitHubActions.TriageRequester

    def request(:page, :get, path, nil, _headers) do
      send(self(), {:get, path, nil})
      {:ok, %{status: 200, body: [%{"number" => 12}, %{"number" => 13, "pull_request" => %{}}]}}
    end

    def request(mode, :get, "/repos/acme/widget/issues/12" = path, nil, headers) do
      {:ok, response} = TriageRequester.request(%{}, :get, path, nil, headers)

      body =
        case mode do
          :large -> Map.put(response.body, "body", String.duplicate("x", 30_000))
          :pull -> Map.put(response.body, "pull_request", %{})
        end

      {:ok, %{response | body: body}}
    end

    def request(
          :large,
          :get,
          "/repos/acme/widget/issues/12/comments?page=1&per_page=20" = path,
          nil,
          _headers
        ) do
      send(self(), {:get, path, nil})

      comments =
        for id <- 1..20 do
          %{
            "id" => id,
            "body" => String.duplicate("x", 12_000),
            "html_url" => "https://github.com/acme/widget/issues/12#issuecomment-#{id}",
            "created_at" => "2026-11-17T12:00:00Z",
            "updated_at" => "2026-11-17T12:00:00Z",
            "user" => %{"id" => 7, "login" => "example-writer", "type" => "User"}
          }
        end

      {:ok, %{status: 200, body: comments}}
    end
  end
end
