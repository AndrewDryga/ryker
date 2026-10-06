defmodule Ryker.GitHub.RepositoryFilesTokenTest do
  @moduledoc """
  Reading a repository's files took the setup token, which could push to the
  repository and open pull requests, to read content anyone who can push there
  writes (2026-10-04 review). A read asks for a token that can only read.
  """
  # Token minting is a named process and the file requester is application
  # configuration, so this test runs alone.
  use Ryker.DataCase, async: false
  alias Ryker.GitHub.{InstallationTokens, RepositoryFiles}
  alias Ryker.Settings

  defmodule App do
    @moduledoc false
    # GitHub's token endpoint: tells the test what the token was asked to do.
    def request(test, :post, "/app/installations/41/access_tokens", document, _headers) do
      send(test, {:minted, document})

      {:ok,
       %{
         body: %{"expires_at" => "2999-01-01T00:00:00Z", "token" => "ghs_read"},
         headers: [],
         status: 201
       }}
    end
  end

  defmodule Files do
    @moduledoc false
    # Takes the client's token as JSONClient does, then finds the repository empty.
    def request(client, :get, _path, nil, _headers) do
      {:ok, "ghs_read"} = client.token_provider.()
      {:ok, %{body: %{"message" => "Git Repository is empty."}, headers: [], status: 409}}
    end
  end

  setup do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    previous = Application.fetch_env!(:ryker, :github_files_requester)
    Application.put_env(:ryker, :github_files_requester, Files)
    on_exit(fn -> Application.put_env(:ryker, :github_files_requester, previous) end)

    start_supervised!(
      {InstallationTokens,
       %{
         app_http: self(),
         bindings: %{"widget" => %{installation_id: 41, repository_id: 99}},
         requester: App
       }}
    )

    :ok
  end

  test "reading a repository's files asks GitHub for a token that can only read" do
    repository = %{base_branch: "main", github_repository: "acme/widget"}
    assert RepositoryFiles.head(%{name: "widget"}, repository) == {:error, :repository_empty}

    assert_received {:minted, %{"permissions" => permissions, "repository_ids" => [99]}}
    assert permissions == %{"contents" => "read"}
  end
end
