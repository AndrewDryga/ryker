defmodule Ryker.GitHub.LabelsClientTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.{Client, Labels}
  alias Ryker.TestSupport.GitHubRequester

  test "provisioning preserves existing labels and validates a concurrent creation" do
    [review, working] = Labels.definitions()

    {:ok, requester} =
      GitHubRequester.start([
        response(200, %{"name" => review.name, "color" => "custom"}),
        response(404, %{}),
        response(422, %{}),
        response(200, %{"name" => working.name})
      ])

    client = client(requester)
    assert Client.ensure_label(client, "octo/example", review) == :ok
    assert Client.ensure_label(client, "octo/example", working) == :ok

    assert [
             {:get, _, _, _},
             {:get, _, _, _},
             {:post, "/repos/octo/example/labels", ^working, _},
             {:get, _, _, _}
           ] = GitHubRequester.requests(requester)
  end

  test "working label discovery includes closed PRs and every page but excludes issues" do
    first = for number <- 1..100, do: %{"number" => number, "pull_request" => %{}}

    {:ok, requester} =
      GitHubRequester.start([
        response(200, first),
        response(200, [%{"number" => 101, "pull_request" => %{}}, %{"number" => 102}])
      ])

    assert Client.labeled_pulls(client(requester), "octo/example", "ryker:working") ==
             {:ok, MapSet.new(1..101)}

    assert [{:get, first_path, nil, _}, {:get, last_path, nil, _}] =
             GitHubRequester.requests(requester)

    assert first_path =~ "state=all&labels=ryker%3Aworking"
    assert last_path =~ "page=2"
  end

  test "working label changes preserve every unrelated label and tolerate repeated removal" do
    {:ok, requester} =
      GitHubRequester.start([
        response(200, [%{"name" => "bug"}, %{"name" => "ryker:working"}]),
        response(404, %{})
      ])

    client = client(requester)
    assert Client.add_pull_label(client, "octo/example", 42, "ryker:working") == :ok
    assert Client.remove_pull_label(client, "octo/example", 42, "ryker:working") == :ok

    assert [
             {:post, "/repos/octo/example/issues/42/labels", %{"labels" => ["ryker:working"]}, _},
             {:delete, "/repos/octo/example/issues/42/labels/ryker%3Aworking", nil, _}
           ] = GitHubRequester.requests(requester)
  end

  defp client(requester) do
    {:ok, client} = Client.new(http: requester, requester: GitHubRequester)
    client
  end

  defp response(status, body), do: {:ok, %{status: status, body: body, headers: []}}
end
