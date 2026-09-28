defmodule Ryker.GitHub.RepositoryFilesTest do
  # RYKER.md's reads and proposals against GitHub's own replies. Every lane
  # test runs against the in-memory repository
  # (`Ryker.TestSupport.FakeGitHubRepository`), so nothing held how this
  # module reads GitHub's statuses and bodies. The replies follow GitHub's
  # REST API: its documented error bodies, and the archived refusal GitHub
  # gave andrewdryga.github.com on 2026-09-27.
  use Ryker.DataCase, async: true

  alias Ryker.GitHub.RepositoryFiles
  alias Ryker.RepositoryKnowledge.Document
  alias Ryker.Settings
  alias Ryker.TestSupport.RecordedGitHub

  @head "783fc4801d274d5ee05feb3fbc5c70981b1bbd7a"
  @binding %{name: "widget"}
  @repository %{github_repository: "acme/widget", base_branch: "main"}
  @pulls "/repos/acme/widget/pulls?head=acme%3Aryker%2Frepository-knowledge&per_page=1&state=open"
  @url "https://github.com/acme/widget/pull/7"

  setup do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
  end

  # GitHub refuses every write to an archived repository with 403
  # "Repository was archived so is read-only.", which read as a missing App
  # permission and told people to grant one the App already had.
  test "an archived repository is refused as archived, by its flag or by GitHub's refusal" do
    RecordedGitHub.reply([{:get, "/repos/acme/widget", ok(200, %{"archived" => true})}])

    assert publish("# RYKER.md\n") == {:error, {:github_onboarding, :archived}}
    assert RecordedGitHub.unanswered() == []

    # Archived a moment after its flag was read: the branch write says so.
    RecordedGitHub.reply(
      new_proposal_reads(nil) ++
        [
          {:get, "/repos/acme/widget/git/ref/heads/ryker%2Frepository-knowledge", ok(404, %{})},
          {:post, "/repos/acme/widget/git/refs",
           ok(403, %{"message" => "Repository was archived so is read-only."})}
        ]
    )

    assert publish("# RYKER.md\n") == {:error, {:github_onboarding, :archived}}
    assert RecordedGitHub.unanswered() == []
  end

  test "a repository with no commit yet is empty, not missing" do
    RecordedGitHub.reply([
      {:get, "/repos/acme/widget/git/ref/heads/main",
       ok(409, %{"message" => "Git Repository is empty."})}
    ])

    assert RepositoryFiles.head(@binding, @repository) == {:error, :repository_empty}
  end

  # A private repository on a free plan cannot have draft pull requests.
  test "a repository that cannot have draft pull requests gets an ordinary one" do
    refused = %{"message" => "Draft pull requests are not supported in this repository."}

    RecordedGitHub.reply(
      new_proposal(nil) ++
        [
          {:post, "/repos/acme/widget/pulls", ok(422, refused)},
          {:post, "/repos/acme/widget/pulls", ok(201, %{"html_url" => @url, "number" => 7})}
        ]
    )

    assert {:ok, %{outcome: :opened, url: @url, number: 7}} = publish("# RYKER.md\n")

    assert [true, false] =
             for(
               {:post, "/repos/acme/widget/pulls", pull} <- RecordedGitHub.requests(),
               do: pull["draft"]
             )
  end

  # A proposal whose first answer was lost is found, not opened twice.
  test "a pull request GitHub says already exists is the one Ryker opened" do
    exists = %{
      "message" => "Validation Failed",
      "errors" => [
        %{
          "resource" => "PullRequest",
          "code" => "custom",
          "message" => "A pull request already exists for acme:ryker/repository-knowledge."
        }
      ]
    }

    RecordedGitHub.reply(
      new_proposal(nil) ++
        [
          {:post, "/repos/acme/widget/pulls", ok(422, exists)},
          {:get, @pulls, ok(200, [%{"html_url" => @url, "number" => 7}])}
        ]
    )

    assert {:ok, %{outcome: :opened, url: @url, number: 7}} = publish("# RYKER.md\n")
    assert RecordedGitHub.unanswered() == []
  end

  # A rewrite that says what the open proposal already says would only move
  # its date: no commit, and the description stays.
  test "an open proposal that already says the same is left as it is" do
    proposed = document("It works.", "aaaaaaa")
    rewrite = document("It works.", "bbbbbbb")

    RecordedGitHub.reply(open_proposal_reads(proposed))

    assert {:ok, %{outcome: :updated, url: @url, number: 7}} = publish(rewrite)
    refute Enum.any?(RecordedGitHub.requests(), &match?({method, _, _} when method != :get, &1))
    assert RecordedGitHub.unanswered() == []
  end

  test "an open proposal Ryker wrote is replaced by the new one, and says why" do
    proposed = document("It works.", "aaaaaaa")
    rewrite = document("It works, and it ships.", "bbbbbbb")

    RecordedGitHub.reply(
      open_proposal_reads(proposed) ++
        [
          {:put, "/repos/acme/widget/contents/RYKER.md", ok(200, %{})},
          {:patch, "/repos/acme/widget/pulls/7", ok(200, %{})}
        ]
    )

    assert {:ok, %{outcome: :updated, url: @url, number: 7}} = publish(rewrite, "Why now: A.")

    assert [
             {:put, _path,
              %{"branch" => "ryker/repository-knowledge", "sha" => "branch-blob"} = put},
             {:patch, _pull, %{"body" => "Why now: A."}}
           ] = Enum.reject(RecordedGitHub.requests(), &match?({:get, _, _}, &1))

    assert Base.decode64!(put["content"]) == rewrite
  end

  # GitHub answers a file over 1 MB with no content, a directory with a
  # list, and Ryker reads no more than 128,000 bytes of text.
  test "a file Ryker cannot read is unavailable, and one that is not there is not found" do
    read = "/repos/acme/widget/contents/RYKER.md?ref=#{@head}"

    RecordedGitHub.reply([
      {:get, read,
       ok(200, %{"type" => "file", "encoding" => "none", "content" => "", "sha" => "x"})},
      {:get, read, file(String.duplicate("a", 128_001), "x")},
      {:get, read, file(<<0xFF, 0xFE>>, "x")},
      {:get, read, ok(200, [%{"type" => "file", "path" => "RYKER.md/a"}])},
      {:get, read, ok(404, %{"message" => "Not Found"})},
      {:get, read, file("# RYKER.md\n", "x")}
    ])

    for _unreadable <- 1..4 do
      assert RepositoryFiles.read(@binding, @repository, "RYKER.md", @head) ==
               {:error, :source_unavailable}
    end

    assert RepositoryFiles.read(@binding, @repository, "RYKER.md", @head) == {:ok, :not_found}
    assert RepositoryFiles.read(@binding, @repository, "RYKER.md", @head) == {:ok, "# RYKER.md\n"}
  end

  # -- Helpers ---------------------------------------------------------------------

  defp publish(document, body \\ "Why now: The repository has no RYKER.md yet."),
    do: RepositoryFiles.publish(@binding, @repository, %{document: document, body: body})

  # What a proposal reads first: the archived flag, the default branch head,
  # RYKER.md there, and Ryker's open pull request (none).
  defp new_proposal_reads(base) do
    [
      {:get, "/repos/acme/widget", ok(200, %{"archived" => false})},
      {:get, "/repos/acme/widget/git/ref/heads/main", ok(200, %{"object" => %{"sha" => @head}})},
      {:get, "/repos/acme/widget/contents/RYKER.md?ref=#{@head}",
       if(base, do: file(base, "base-blob"), else: ok(404, %{"message" => "Not Found"}))},
      {:get, @pulls, ok(200, [])}
    ]
  end

  # A new proposal up to its pull request: the branch starts again at the
  # default branch head and holds the document.
  defp new_proposal(base) do
    new_proposal_reads(base) ++
      [
        {:get, "/repos/acme/widget/git/ref/heads/ryker%2Frepository-knowledge",
         ok(200, %{"object" => %{"sha" => "old"}})},
        {:patch, "/repos/acme/widget/git/refs/heads/ryker%2Frepository-knowledge", ok(200, %{})},
        {:put, "/repos/acme/widget/contents/RYKER.md", ok(201, %{})}
      ]
  end

  # An open proposal, and RYKER.md on its branch.
  defp open_proposal_reads(branch_document) do
    [
      {:get, "/repos/acme/widget", ok(200, %{"archived" => false})},
      {:get, "/repos/acme/widget/git/ref/heads/main", ok(200, %{"object" => %{"sha" => @head}})},
      {:get, "/repos/acme/widget/contents/RYKER.md?ref=#{@head}", ok(404, %{})},
      {:get, @pulls, ok(200, [%{"html_url" => @url, "number" => 7}])},
      {:get, "/repos/acme/widget/contents/RYKER.md?ref=ryker%2Frepository-knowledge",
       file(branch_document, "branch-blob")}
    ]
  end

  defp document(purpose, commit) do
    text =
      "# RYKER.md\n\nWritten by Ryker from `#{commit}` on 2026-09-27.\n\n## Purpose\n\n#{purpose}\n"

    assert Document.origin(text) == :model
    text
  end

  # GitHub's contents API: the file base64-encoded, wrapped every 60
  # characters.
  defp file(text, sha) do
    content =
      text
      |> Base.encode64()
      |> String.graphemes()
      |> Enum.chunk_every(60)
      |> Enum.map_join("\n", &Enum.join/1)

    ok(200, %{"type" => "file", "encoding" => "base64", "content" => content, "sha" => sha})
  end

  defp ok(status, body, headers \\ []),
    do:
      {:ok, %{status: status, body: body, headers: [{"x-ratelimit-remaining", "4999"} | headers]}}
end
