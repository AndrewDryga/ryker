defmodule Responder.Publication.GitTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.{Git, Publication, Request}

  defmodule Command do
    def run(_directory, arguments, options) do
      send(Process.get(:publication_git_observer), {:git_command, arguments, options})

      case arguments do
        ["write-tree"] -> {:ok, Process.get(:candidate_tree) <> "\n"}
        ["rev-parse", "HEAD"] -> {:ok, String.duplicate("9", 40) <> "\n"}
        ["ls-remote" | _rest] -> {:ok, ""}
        _other -> {:ok, ""}
      end
    end
  end

  test "reconstructs the reviewed tree and pushes one lease-protected branch" do
    Process.put(:publication_git_observer, self())
    request = request!()
    Process.put(:candidate_tree, request.review["candidate_tree"])
    root = temp_directory!("git")
    repository = Path.join(root, "repository")
    state_dir = Path.join(root, "state")
    File.mkdir!(repository)
    File.mkdir!(state_dir)

    try do
      assert {:ok, result} =
               Git.publish_candidate(
                 request,
                 %{
                   base_branch: "main",
                   github_repository: "acme/responder",
                   path: repository
                 },
                 %{
                   branch_prefix: "responder",
                   command: Command,
                   commit_email: "responder@emisar.dev",
                   commit_name: "Emisar Responder",
                   secrets: ["configured-secret-value"],
                   state_dir: state_dir,
                   token_provider: fn -> {:ok, "ghp_not_exposed_in_argv_123456789"} end
                 }
               )

      assert result.commit_sha == String.duplicate("9", 40)
      assert String.starts_with?(result.branch_ref, "refs/heads/responder/")

      commands = collect_commands([])
      assert Enum.any?(commands, fn {args, _options} -> hd(args) == "apply" end)

      assert {push, push_options} =
               Enum.find(commands, fn {args, _options} -> hd(args) == "push" end)

      refute inspect(push) =~ "ghp_not_exposed"
      assert push_options[:env][:GIT_CONFIG_VALUE_0] =~ "AUTHORIZATION: basic "
      refute push_options[:env][:GIT_CONFIG_VALUE_0] =~ "ghp_not_exposed"
    after
      File.rm_rf(root)
    end
  end

  test "credential-shaped reviewed bytes never reach Git" do
    Process.put(:publication_git_observer, self())
    request = request!("token ghp_abcdefghijklmnopqrstuvwxyz123456 in diff")
    Process.put(:candidate_tree, request.review["candidate_tree"])
    root = temp_directory!("secret")
    repository = Path.join(root, "repository")
    File.mkdir!(repository)

    try do
      assert Git.publish_candidate(
               request,
               %{
                 base_branch: "main",
                 github_repository: "acme/responder",
                 path: repository
               },
               %{
                 branch_prefix: "responder",
                 command: Command,
                 commit_email: "responder@emisar.dev",
                 commit_name: "Emisar Responder",
                 secrets: [],
                 state_dir: root,
                 token_provider: fn -> {:ok, "token"} end
               }
             ) == {:error, :publication_patch_contains_secret}

      refute_receive {:git_command, _arguments, _options}
    after
      File.rm_rf(root)
    end
  end

  defp collect_commands(result) do
    receive do
      {:git_command, arguments, options} -> collect_commands([{arguments, options} | result])
    after
      0 -> Enum.reverse(result)
    end
  end

  defp request!(patch \\ "diff --git a/a b/a\n+change\n") do
    review = review(patch)

    publication = %Publication{
      approval_ref: "interaction:publish",
      approved_at: ~U[2026-08-28 12:00:00.000000Z],
      approved_by_actor_ref: "slack:user:U123",
      body: "Implement the reviewed change.",
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

  defp review(patch) do
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
      "pull_request" => nil,
      "rebase" => "clean",
      "session_id" => "remote-session",
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp temp_directory!(suffix) do
    path = Path.join(System.tmp_dir!(), "responder-publication-#{suffix}-#{Ecto.UUID.generate()}")
    File.mkdir!(path)
    path
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
