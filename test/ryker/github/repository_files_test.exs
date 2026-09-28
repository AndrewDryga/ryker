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

  # GitHub answers its primary and secondary rate limits with 403 as well as
  # 429. Every 403 read as a missing App permission, so a busy hour ended
  # the step for a day and told people to grant a permission the App had.
  test "a rate limit is a wait, not a missing App permission" do
    ref = "/repos/acme/widget/git/ref/heads/main"

    RecordedGitHub.reply([
      {:get, ref,
       ok(403, %{"message" => "API rate limit exceeded for installation ID 41."}, [
         {"x-ratelimit-remaining", "0"},
         {"x-ratelimit-reset", "1790000000"}
       ])},
      {:get, ref,
       ok(
         403,
         %{
           "message" =>
             "You have exceeded a secondary rate limit. Please wait a few minutes before you " <>
               "try again."
         },
         [{"retry-after", "60"}]
       )},
      {:get, ref, ok(429, %{"message" => "Too many requests"}, [{"retry-after", "30"}])},
      {:get, ref, ok(403, %{"message" => "Resource not accessible by integration"})}
    ])

    for _limited <- 1..3 do
      assert RepositoryFiles.head(@binding, @repository) ==
               {:error, {:github_onboarding, :rate_limited}}
    end

    assert RepositoryFiles.head(@binding, @repository) ==
             {:error, {:github_onboarding, :permission}}
  end

  test "a repository with no commit yet is empty, not missing" do
    RecordedGitHub.reply([
      {:get, "/repos/acme/widget/git/ref/heads/main",
       ok(409, %{"message" => "Git Repository is empty."})}
    ])

    assert RepositoryFiles.head(@binding, @repository) == {:error, :repository_empty}
  end

  # A private repository on a free plan cannot have draft pull requests.
  # GitHub may name that in its message or among its validation errors; a
  # refusal missed there reads as a pull request that could not be opened,
  # which is tried again every minute, each time resetting the branch and
  # committing to it again.
  test "a repository that cannot have draft pull requests gets an ordinary one" do
    sentence = "Draft pull requests are not supported in this repository."

    for refused <- [
          %{"message" => sentence},
          %{
            "message" => "Validation Failed",
            "errors" => [
              %{"resource" => "PullRequest", "code" => "custom", "message" => sentence}
            ]
          }
        ] do
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

  # Any other refusal is GitHub's answer to this pull request itself, and
  # asking again gets it again. It read as a pull request that could not be
  # opened, which was tried every minute, each time writing the branch again.
  test "a pull request GitHub refuses outright is a refusal, not a retry" do
    refused = %{
      "message" => "Validation Failed",
      "errors" => [
        %{
          "resource" => "PullRequest",
          "code" => "custom",
          "message" => "No commits between main and ryker/repository-knowledge"
        }
      ]
    }

    RecordedGitHub.reply(
      new_proposal(nil) ++
        [
          {:post, "/repos/acme/widget/pulls", ok(422, refused)},
          {:get, @pulls, ok(200, [])}
        ]
    )

    assert publish("# RYKER.md\n") == {:error, {:github_onboarding, :pull_request_refused}}
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

  # What Ryker last proposed is what Work reads while the pull request is
  # open. A rewrite that said the same left the branch as it was, so its
  # provenance line can be older than that copy's; the words are Ryker's.
  test "an open proposal Ryker wrote is replaced by the new one, and says why" do
    branch = document("It works.", "aaaaaaa")
    proposed = document("It works.", "ccccccc")
    rewrite = document("It works, and it ships.", "bbbbbbb")

    RecordedGitHub.reply(
      open_proposal_reads(branch) ++
        [
          {:put, "/repos/acme/widget/contents/RYKER.md", ok(200, %{})},
          {:patch, "/repos/acme/widget/pulls/7", ok(200, %{})}
        ]
    )

    assert {:ok, %{outcome: :updated, url: @url, number: 7}} =
             publish(rewrite, "Why now: A.", proposed)

    assert [
             {:put, _path,
              %{"branch" => "ryker/repository-knowledge", "sha" => "branch-blob"} = put},
             {:patch, _pull, %{"body" => "Why now: A."}}
           ] = Enum.reject(RecordedGitHub.requests(), &match?({:get, _, _}, &1))

    assert Base.decode64!(put["content"]) == rewrite
  end

  # Review of the knowledge lane, 2026-09-28: the pull request asks people
  # to review and edit RYKER.md before merging, and the next update wrote
  # over whatever they had changed on its branch, or put back a file they
  # had removed there.
  test "an open proposal a person edited is left as it is" do
    proposed = document("It works.", "aaaaaaa")
    rewrite = document("It works, and it ships.", "bbbbbbb")

    for branch <- [
          file(proposed <> "\nAsk #infra before a deploy.\n", "branch-blob"),
          ok(404, %{"message" => "Not Found"}),
          ok(200, %{"type" => "file", "encoding" => "none", "content" => "", "sha" => "x"})
        ] do
      RecordedGitHub.reply(open_proposal_reads(branch))

      assert publish(rewrite, "Why now: A.", proposed) ==
               {:error, :repository_knowledge_proposal_edited}

      refute Enum.any?(RecordedGitHub.requests(), &match?({method, _, _} when method != :get, &1))
      assert RecordedGitHub.unanswered() == []
    end

    # Nor is one whose last proposal Ryker cannot name.
    RecordedGitHub.reply(open_proposal_reads(proposed))
    assert publish(rewrite, "Why now: A.", nil) == {:error, :repository_knowledge_proposal_edited}

    # Nor one a person edited after Ryker wrote it there.
    sent = document("It works, and it is fast.", "ccccccc")
    RecordedGitHub.reply(open_proposal_reads(sent <> "\nAsk #infra before a deploy.\n"))

    assert publish(rewrite, "Why now: A.", proposed, [sha256(sent)]) ==
             {:error, :repository_knowledge_proposal_edited}

    refute Enum.any?(RecordedGitHub.requests(), &match?({method, _, _} when method != :get, &1))
    assert RecordedGitHub.unanswered() == []
  end

  # Review of the knowledge lane, 2026-09-28: a proposal that failed after
  # it wrote the branch, before it was recorded, left Ryker's own words
  # there, and the next proposal read them as a person's edit and left the
  # pull request alone for good. Ryker records what it sends before sending.
  test "an open proposal holding what Ryker sent but never recorded is replaced" do
    proposed = document("It works.", "aaaaaaa")
    sent = document("It works, and it is fast.", "ccccccc")
    rewrite = document("It works, and it ships.", "bbbbbbb")

    RecordedGitHub.reply(
      open_proposal_reads(sent) ++
        [
          {:put, "/repos/acme/widget/contents/RYKER.md", ok(200, %{})},
          {:patch, "/repos/acme/widget/pulls/7", ok(200, %{})}
        ]
    )

    assert {:ok, %{outcome: :updated, url: @url, number: 7}} =
             publish(rewrite, "Why now: A.", proposed, [sha256(sent)])

    assert [
             {:put, _path, %{"sha" => "branch-blob"} = put},
             {:patch, _pull, %{"body" => "Why now: A."}}
           ] = Enum.reject(RecordedGitHub.requests(), &match?({:get, _, _}, &1))

    assert Base.decode64!(put["content"]) == rewrite
    assert RecordedGitHub.unanswered() == []
  end

  # GitHub answers a file over 1 MB with no content and a directory with a
  # list, and Ryker reads no more than GitHub sends inline.
  test "a file Ryker cannot read is unavailable, and one that is not there is not found" do
    read = "/repos/acme/widget/contents/RYKER.md?ref=#{@head}"

    RecordedGitHub.reply([
      {:get, read,
       ok(200, %{"type" => "file", "encoding" => "none", "content" => "", "sha" => "x"})},
      {:get, read, file(String.duplicate("a", 1_048_577), "x")},
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

  # coop's README is 135,820 bytes, and Ryker read no more than 128,000 of a
  # file: the knowledge run of 2026-09-27 dropped three commands the README
  # really has, `coop build && coop doctor` and `coop claude` among them, as
  # ones it could not find written anywhere.
  test "a long README is read whole" do
    read = "/repos/acme/widget/contents/README.md?ref=#{@head}"
    text = String.duplicate("a", 135_820)

    RecordedGitHub.reply([{:get, read, file(text, "x")}])

    assert RepositoryFiles.read(@binding, @repository, "README.md", @head) == {:ok, text}
  end

  # A 5xx while reading a file came back as a file Ryker cannot read, which
  # the lane leaves alone as a person's: a moment's outage would settle the
  # day's check, and drop the commands a model cited from that file.
  test "GitHub failing while a file is read is GitHub failing, not a file Ryker cannot read" do
    read = "/repos/acme/widget/contents/RYKER.md?ref=#{@head}"

    RecordedGitHub.reply([
      {:get, read, {:ok, %{status: 502, body: "<html>502 Bad Gateway</html>", headers: []}}},
      {:get, read, ok(503, %{"message" => "Service Unavailable"})},
      {:get, read, ok(429, %{"message" => "Too many requests"}, [{"retry-after", "30"}])}
    ])

    for _failing <- 1..2 do
      assert RepositoryFiles.read(@binding, @repository, "RYKER.md", @head) ==
               {:error, {:github_onboarding, :response}}
    end

    assert RepositoryFiles.read(@binding, @repository, "RYKER.md", @head) ==
             {:error, {:github_onboarding, :rate_limited}}
  end

  # -- Helpers ---------------------------------------------------------------------

  defp publish(
         document,
         body \\ "Why now: The repository has no RYKER.md yet.",
         proposed \\ nil,
         sent \\ []
       ),
       do:
         RepositoryFiles.publish(@binding, @repository, %{
           document: document,
           body: body,
           proposed: proposed,
           sent: sent
         })

  # How Ryker records a document it sends (`Ryker.RepositoryKnowledge.Custody.sending/1`).
  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

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

  # An open proposal, and RYKER.md on its branch: a document, or the reply
  # GitHub gives for it.
  defp open_proposal_reads(branch) do
    branch = if is_binary(branch), do: file(branch, "branch-blob"), else: branch

    [
      {:get, "/repos/acme/widget", ok(200, %{"archived" => false})},
      {:get, "/repos/acme/widget/git/ref/heads/main", ok(200, %{"object" => %{"sha" => @head}})},
      {:get, "/repos/acme/widget/contents/RYKER.md?ref=#{@head}", ok(404, %{})},
      {:get, @pulls, ok(200, [%{"html_url" => @url, "number" => 7}])},
      {:get, "/repos/acme/widget/contents/RYKER.md?ref=ryker%2Frepository-knowledge", branch}
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
