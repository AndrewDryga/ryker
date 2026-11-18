defmodule Ryker.GitHub.CIRepairTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.{CIRepairPolicy, Client}
  alias Ryker.TestSupport.GitHubRequester

  @head String.duplicate("a", 40)

  test "a skip label after the first hundred labels still prevents repair" do
    {:ok, requester} =
      GitHubRequester.start([
        response(pull()),
        response(Enum.map(1..100, &%{"name" => "label-#{&1}"})),
        response([%{"name" => "ryker:no-ci-fix"}]),
        response(%{
          "check_runs" => [%{"status" => "completed", "conclusion" => "failure"}],
          "total_count" => 1
        }),
        response(%{"statuses" => [], "total_count" => 0})
      ])

    client = %Client{http: requester, requester: GitHubRequester}
    assert {:ok, snapshot} = Client.CIRepair.snapshot(client, "acme/widget", 99, 12)
    assert snapshot["checks"]["state"] == "failing"

    assert CIRepairPolicy.eligibility(repository(:all), configured_binding(), snapshot) ==
             {:error, :skipped}

    assert Enum.any?(GitHubRequester.requests(requester), fn {_method, path, _, _} ->
             String.ends_with?(path, "labels?per_page=100&page=2")
           end)
  end

  test "own-only means the numeric installed bot identity and all still excludes forks" do
    snapshot = %{
      "labels" => [],
      "state" => "open",
      "merged" => false,
      "repository_id" => 99,
      "head_repository_id" => 99,
      "branch" => "fix",
      "base_branch" => "main",
      "author_id" => 7,
      "author_type" => "User"
    }

    assert CIRepairPolicy.eligibility(repository(:off), configured_binding(), snapshot) ==
             {:error, :disabled}

    assert CIRepairPolicy.eligibility(repository(:own), configured_binding(), snapshot) ==
             {:error, :not_owned}

    assert CIRepairPolicy.eligibility(repository(:all), configured_binding(), snapshot) == :ok

    assert CIRepairPolicy.eligibility(repository(:all), configured_binding(), %{
             snapshot
             | "head_repository_id" => 100
           }) == {:error, :fork}

    owned = %{snapshot | "author_id" => 4321, "author_type" => "Bot"}
    assert CIRepairPolicy.eligibility(repository(:own), configured_binding(), owned) == :ok

    assert CIRepairPolicy.eligibility(repository(:all), configured_binding(), %{
             owned
             | "merged" => true
           }) ==
             {:error, :closed}
  end

  test "missing label pages and mismatched numeric repository fail closed" do
    {:ok, requester} =
      GitHubRequester.start([
        response(pull()),
        {:ok, %{status: 403, body: %{"message" => "Forbidden"}}}
      ])

    assert {:error, _unavailable} =
             Client.CIRepair.target(
               %Client{http: requester, requester: GitHubRequester},
               "acme/widget",
               99,
               12
             )

    {:ok, requester} = GitHubRequester.start([response(pull())])

    assert Client.CIRepair.target(
             %Client{http: requester, requester: GitHubRequester},
             "acme/widget",
             100,
             12
           ) == {:error, {:github_protocol_error, :ci_repair_target}}
  end

  defp response(body), do: {:ok, %{status: 200, body: body}}
  defp repository(policy), do: %{github_ci_repair: policy, github_access: :available}
  defp configured_binding, do: %{repository_id: 99, ryker_actor_id: 4321}

  defp pull do
    %{
      "number" => 12,
      "state" => "open",
      "merged" => false,
      "base" => %{"repo" => %{"id" => 99}, "ref" => "main"},
      "head" => %{"repo" => %{"id" => 99}, "ref" => "fix", "sha" => @head},
      "user" => %{"id" => 7, "type" => "User"}
    }
  end
end
