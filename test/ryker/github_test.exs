defmodule Ryker.GitHubTest do
  use ExUnit.Case, async: true
  alias Ryker.Config
  alias Ryker.CoopFleet.ManagedSources
  alias Ryker.GitHub
  alias Ryker.Publication.Receipt

  test "the web address follows the API address the App was connected with" do
    assert GitHub.web_url("https://api.github.com") == "https://github.com"
    assert GitHub.web_url("https://api.github.com/") == "https://github.com"
    assert GitHub.web_url("https://git.example.com/api/v3") == "https://git.example.com"
    assert GitHub.web_url("https://git.example.com/api/v3/") == "https://git.example.com"
    assert GitHub.web_url("https://git.example.com:8443/api/v3") == "https://git.example.com:8443"
    assert GitHub.web_url("https://api.acme.ghe.com") == "https://acme.ghe.com"
    assert GitHub.web_url("http://git.example.com/api/v3") == "https://github.com"
    assert GitHub.web_url(nil) == "https://github.com"

    assert GitHub.api_root("https://git.example.com/api/v3") == "https://git.example.com/api/v3/"
    assert GitHub.api_root("https://api.github.com/") == "https://api.github.com/"
  end

  # The connect form took a GitHub Enterprise API address while every link,
  # git remote and accepted pull-request address still assumed github.com: a
  # repository was cloned from github.com under its enterprise name, and a
  # draft pull request opened on the enterprise was refused as not GitHub's
  # (2026-10-04 review, 521).
  test "a source is cloned from the connected enterprise, and its pull requests are accepted there" do
    Config.put_override(:github_web_url, "https://git.example.com")

    assert {:ok, %{remote: "https://git.example.com/acme/tools.git"}} =
             ManagedSources.resolve_repository(
               %{repositories: [], github_bindings: []},
               "acme/tools",
               fn _slug -> {:ok, %{full_name: "acme/tools", id: 7}} end
             )

    review = %{"candidate_tree" => String.duplicate("a", 40), "candidate_head" => commit()}

    assert {:ok, _receipt} =
             Receipt.prepare(
               receipt("https://git.example.com/acme/api/pull/7"),
               review,
               "acme/api"
             )

    assert Receipt.prepare(receipt("https://github.com/acme/api/pull/7"), review, "acme/api") ==
             {:error, {:invalid_publication_receipt, :identity}}
  end

  test "without an enterprise, everything stays on github.com" do
    assert GitHub.web_url() == "https://github.com"
    assert GitHub.api_url() == "https://api.github.com/"
    assert GitHub.repository_url("acme/api") == "https://github.com/acme/api"
  end

  defp receipt(url) do
    %{
      "branch_ref" => "refs/heads/ryker/fix",
      "candidate_tree" => String.duplicate("a", 40),
      "commit_sha" => commit(),
      "pull_request_number" => 7,
      "pull_request_url" => url,
      "repository" => "acme/api"
    }
  end

  # Eight modules each held this pattern until 2026-10-08.
  test "a repository's full name is owner/name" do
    assert GitHub.repository_name?("emisar/ryker")
    assert GitHub.repository_name?("my-org/repo.name_2")
    refute GitHub.repository_name?("ryker")
    refute GitHub.repository_name?("emisar/ryker/extra")
    refute GitHub.repository_name?("emisar/ry ker")
    refute GitHub.repository_name?(nil)
    assert Regex.match?(GitHub.repository_name_pattern(), "emisar/ryker")
  end

  defp commit, do: String.duplicate("b", 40)
end
