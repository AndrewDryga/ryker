defmodule Ryker.GitHub.RepositoryFilesTest do
  # RYKER.md's reads and proposals against GitHub's own replies. Every lane
  # test runs against the in-memory repository
  # (`Ryker.TestSupport.FakeGitHubRepository`), so nothing held how this
  # module reads GitHub's statuses and bodies. The replies follow GitHub's
  # REST API: its documented error bodies, and the archived refusal GitHub
  # gave andrewdryga.github.com on 2026-09-27.
  use Ryker.DataCase, async: true

  alias Ryker.GitHub.RepositoryFiles
  alias Ryker.Settings
  alias Ryker.TestSupport.RecordedGitHub

  @head "783fc4801d274d5ee05feb3fbc5c70981b1bbd7a"
  @binding %{name: "widget"}
  @repository %{github_repository: "acme/widget", base_branch: "main"}

  setup do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
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
