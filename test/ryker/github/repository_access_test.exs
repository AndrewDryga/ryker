defmodule Ryker.GitHub.RepositoryAccessTest do
  use ExUnit.Case, async: true

  alias Ryker.GitHub.{Binding, RepositoryAccess}

  defmodule Requester do
    def request(test, method, path, document, headers) do
      send(test, {:request, method, path, document, headers})

      receive do
        {:respond, response} -> response
      end
    end
  end

  test "repository write access authorizes requests without a saved username" do
    for permission <- ~w(write admin) do
      parent = self()

      task =
        Task.async(fn ->
          RepositoryAccess.authorize(binding!(), payload("Ada Lovelace"), parent,
            requester: Requester
          )
        end)

      assert_receive {:request, :get,
                      "/repos/acme/widget/collaborators/Ada%20Lovelace/permission", nil, _headers}

      send(task.pid, {:respond, {:ok, %{body: %{"permission" => permission}, status: 200}}})
      assert Task.await(task) == :ok
    end
  end

  test "read, triage-equivalent, and missing access cannot start repository work" do
    parent = self()

    task =
      Task.async(fn ->
        RepositoryAccess.authorize(binding!(), payload("reader"), parent, requester: Requester)
      end)

    assert_receive {:request, :get, _path, nil, _headers}
    send(task.pid, {:respond, {:ok, %{body: %{"permission" => "read"}, status: 200}}})
    assert Task.await(task) == {:error, :actor_not_authorized}

    task =
      Task.async(fn ->
        RepositoryAccess.authorize(binding!(), payload("missing"), parent, requester: Requester)
      end)

    assert_receive {:request, :get, _path, nil, _headers}
    send(task.pid, {:respond, {:ok, %{body: %{}, status: 404}}})
    assert Task.await(task) == {:error, :actor_not_authorized}
  end

  test "provider failures remain retryable instead of becoming authorization denials" do
    parent = self()

    task =
      Task.async(fn ->
        RepositoryAccess.authorize(binding!(), payload("ada"), parent, requester: Requester)
      end)

    assert_receive {:request, :get, _path, nil, _headers}
    send(task.pid, {:respond, {:ok, %{body: %{}, status: 503}}})

    assert Task.await(task) ==
             {:error, {:github_repository_access_unavailable, {:http_status, 503}}}
  end

  defp binding! do
    %Binding{
      action_grants: ["read"],
      installation_id: 41,
      max_body_bytes: 40_000,
      name: "github-main",
      repository_full_name: "acme/widget",
      repository_id: 99,
      ryker_actor_id: 4_321,
      secret: String.duplicate("s", 32),
      work_profile: nil
    }
  end

  defp payload(login) do
    %{"sender" => %{"id" => 7, "login" => login, "type" => "User"}}
  end
end
