defmodule Responder.Publication.GitHubPublisherTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.{GitHubPublisher, Publication, Request}

  defmodule Git do
    def publish_candidate(request, repository, agent) do
      Agent.get_and_update(agent, fn state ->
        call = {request, repository}
        {{:ok, state.git_result}, %{state | git_calls: state.git_calls ++ [call]}}
      end)
    end
  end

  defmodule API do
    def find_open_pull_request(agent, repository, owner, branch) do
      Agent.get_and_update(agent, fn state ->
        call = {:find, repository, owner, branch}
        {state.find_result, %{state | api_calls: state.api_calls ++ [call]}}
      end)
    end

    def create_draft_pull_request(agent, repository, title, body, head, base) do
      Agent.get_and_update(agent, fn state ->
        call = {:create, repository, title, body, head, base}
        {state.create_result, %{state | api_calls: state.api_calls ++ [call]}}
      end)
    end

    def get_pull_request(agent, repository, number) do
      Agent.get_and_update(agent, fn state ->
        call = {:get, repository, number}
        [result | remaining] = state.get_results
        {result, %{state | api_calls: state.api_calls ++ [call], get_results: remaining}}
      end)
    end

    def get_publication_status(agent, repository, number) do
      Agent.get_and_update(agent, fn state ->
        call = {:status, repository, number}
        {state.status_result, %{state | api_calls: state.api_calls ++ [call]}}
      end)
    end
  end

  test "publishes one exact new draft and returns a tree-bound receipt" do
    request = request!()
    commit = String.duplicate("9", 40)
    branch = "responder/fix-publication-123"
    pull = pull(branch, commit)

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          api_calls: [],
          create_result: {:ok, pull},
          find_result: :not_found,
          get_results: [],
          git_calls: [],
          git_result: %{branch_ref: "refs/heads/#{branch}", commit_sha: commit}
        }
      end)

    assert {:ok, receipt} = GitHubPublisher.publish(request, publisher_binding(state))
    assert receipt["candidate_tree"] == request.review["candidate_tree"]
    assert receipt["commit_sha"] == commit
    assert receipt["pull_request_number"] == 42
    assert receipt["pull_request_url"] == "https://github.com/acme/responder/pull/42"

    stored = Agent.get(state, & &1)
    assert length(stored.git_calls) == 1
    assert [{:find, "acme/responder", "acme", ^branch}, create] = stored.api_calls
    assert {:create, "acme/responder", _title, body, ^branch, "main"} = create
    assert body =~ request.review["candidate_tree"]
  end

  test "an existing pull request is compare-and-swap checked before and after push" do
    old = String.duplicate("8", 40)
    commit = String.duplicate("9", 40)
    branch = "existing-pr"
    request = request!(%{"head_commit" => old, "number" => 42, "ref" => branch})

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          api_calls: [],
          create_result: :unused,
          find_result: :unused,
          get_results: [{:ok, pull(branch, old, false)}, {:ok, pull(branch, commit, false)}],
          git_calls: [],
          git_result: %{branch_ref: "refs/heads/#{branch}", commit_sha: commit}
        }
      end)

    assert {:ok, receipt} = GitHubPublisher.publish(request, publisher_binding(state))
    assert receipt["commit_sha"] == commit

    stored = Agent.get(state, & &1)
    assert stored.api_calls == [{:get, "acme/responder", 42}, {:get, "acme/responder", 42}]
  end

  test "a crossed GitHub head never becomes a publication receipt" do
    request = request!()
    commit = String.duplicate("9", 40)
    branch = "responder/fix-publication-123"
    crossed = pull(branch, String.duplicate("f", 40))

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          api_calls: [],
          create_result: {:ok, crossed},
          find_result: :not_found,
          get_results: [],
          git_calls: [],
          git_result: %{branch_ref: "refs/heads/#{branch}", commit_sha: commit}
        }
      end)

    assert GitHubPublisher.publish(request, publisher_binding(state)) ==
             {:error, :publication_pull_request_mismatch}
  end

  test "routes publication and status reads through the exact repository binding" do
    request = %{request!() | repository: "repository-b"}
    commit = String.duplicate("9", 40)
    branch = "responder/fix-publication-123"

    {:ok, repository_a} = Agent.start_link(fn -> publisher_state(branch, commit) end)
    {:ok, repository_b} = Agent.start_link(fn -> publisher_state(branch, commit) end)

    binding = %{
      git: Git,
      repositories: %{
        "repository-a" => repository_binding(repository_a, "acme/repository-a"),
        "repository-b" => repository_binding(repository_b, "acme/repository-b"),
        "repository-b-platform" => repository_binding(repository_b, "acme/repository-b")
      }
    }

    assert {:ok, receipt} = GitHubPublisher.publish(request, binding)
    assert receipt["repository"] == "repository-b"
    assert Agent.get(repository_a, & &1.api_calls) == []
    assert Agent.get(repository_a, & &1.git_calls) == []
    assert Agent.get(repository_b, & &1.git_calls) |> length() == 1

    assert {:ok, %{"state" => "open"}} =
             GitHubPublisher.get_publication_status(binding, "acme/repository-b", 42)

    assert List.last(Agent.get(repository_b, & &1.api_calls)) ==
             {:status, "acme/repository-b", 42}
  end

  defp publisher_binding(agent) do
    %{
      git: Git,
      repositories: %{
        "responder" => repository_binding(agent, "acme/responder")
      }
    }
  end

  defp repository_binding(agent, github_repository) do
    %{
      api: API,
      base_branch: "main",
      client: agent,
      git_binding: agent,
      github_repository: github_repository,
      path: "/trusted/responder"
    }
  end

  defp publisher_state(branch, commit) do
    %{
      api_calls: [],
      create_result: {:ok, pull(branch, commit)},
      find_result: :not_found,
      get_results: [],
      git_calls: [],
      git_result: %{branch_ref: "refs/heads/#{branch}", commit_sha: commit},
      status_result: {:ok, %{"state" => "open"}}
    }
  end

  defp request!(pull_request \\ nil) do
    patch = "diff --git a/a b/a\n+change\n"
    review = review(patch, pull_request)

    publication = %Publication{
      approval_ref: "interaction:publish",
      approved_at: ~U[2026-08-28 12:00:00.000000Z],
      approved_by_actor_ref: "slack:user:U123",
      body: "Implement the reviewed change for @operators.",
      ref: "publication:1234567890abcdef",
      repository: "responder",
      review_document: review,
      review_patch: patch,
      status: :publish_pending,
      title: "Fix publication retries"
    }

    assert {:ok, request} = Request.new(publication)
    request
  end

  defp review(patch, pull_request) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "op-review",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "patch_artifact_id" => "op-review",
      "patch_bytes" => byte_size(patch),
      "patch_digest" => digest(patch),
      "patch_truncated" => false,
      "policy_digest" => String.duplicate("a", 64),
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => pull_request,
      "rebase" => "clean",
      "session_id" => "remote-session",
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp pull(branch, sha, draft \\ true) do
    %{
      "base_ref" => "main",
      "draft" => draft,
      "head_ref" => branch,
      "head_sha" => sha,
      "merged" => false,
      "number" => 42,
      "state" => "open",
      "url" => "https://github.com/acme/responder/pull/42"
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
