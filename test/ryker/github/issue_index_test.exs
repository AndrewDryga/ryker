defmodule Ryker.GitHub.IssueIndexTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.DatabaseClock
  alias Ryker.GitHub.{IndexedIssue, IssueIndex, IssueIndexState, IssueTriageWorker}
  alias Ryker.Settings

  @actor "control-plane:local"

  setup do
    {:ok, settings} = Settings.initialize(@actor)

    {:ok, settings} =
      Settings.save_github(
        %{enabled: true, app_id: 1234, app_slug: "ryker-test"},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget", github_issue_triage: true},
        settings.installation.revision,
        @actor
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          installation_id: 41,
          repository_id: 99,
          ryker_actor_id: 4321
        },
        settings.installation.revision,
        @actor
      )

    {:ok, configured} = IssueIndex.configuration("widget-app")
    %{configured: configured}
  end

  test "backfill is bounded and never requests triage for historical issues", %{
    configured: configured
  } do
    {:ok, _index} = IssueIndex.ensure(configured)

    for page <- 1..5 do
      {:ok, claimed} = IssueIndex.claim_next(["widget-app"])
      assert claimed.page == page

      assert {:ok, saved} =
               IssueIndex.backfilled(claimed, configured, %{numbers: [page], complete: false})

      assert saved.page == page + 1
    end

    assert Enum.all?(Repo.all(IndexedIssue), &(not &1.triage_pending))
    assert Repo.one(IssueIndexState).page == 6
  end

  test "a newer event remains pending when an older fetch finishes", %{configured: configured} do
    {:ok, first} = IssueIndex.enqueue(configured, 12, true)
    {:ok, claimed} = IssueIndex.claim_next(["widget-app"])
    {:ok, second} = IssueIndex.enqueue(configured, 12, false)
    assert second.generation > first.generation
    assert second.triage_pending

    assert IssueIndex.refreshed(
             claimed,
             first,
             configured,
             document(12, "Old title"),
             {nil, nil}
           ) == {:error, :issue_index_changed}

    assert {:ok, _saved} = IssueIndex.settled(claimed, first, configured, "old-digest")
    current = Repo.get!(IndexedIssue, first.id)
    assert current.pending
    assert current.triage_pending
    assert current.last_triaged_digest == nil
  end

  test "keyword search works without embeddings and never claims complete coverage", %{
    configured: configured
  } do
    {:ok, issue} = IssueIndex.enqueue(configured, 12, false)
    {:ok, claimed} = IssueIndex.claim_next(["widget-app"])

    assert {:ok, _saved} =
             IssueIndex.refreshed(
               claimed,
               issue,
               configured,
               document(12, "CSV export crashes"),
               {nil, nil}
             )

    assert {:ok, result} = IssueIndex.search(configured, "CSV", url: nil)
    assert [found] = result["items"]
    assert found["issue"]["number"] == 12
    assert result["coverage"] == "partial"
    refute result["meaning_search"]

    assert {:ok, %{"items" => [], "coverage" => "partial"}} =
             IssueIndex.search(configured, "unrelated", url: nil)
  end

  test "meaning search can retrieve different words but never another repository identity", %{
    configured: configured
  } do
    {:ok, issue} = IssueIndex.enqueue(configured, 12, false)
    {:ok, claimed} = IssueIndex.claim_next(["widget-app"])

    assert {:ok, _saved} =
             IssueIndex.refreshed(
               claimed,
               issue,
               configured,
               document(12, "Empty table export"),
               {"test-model", [1.0, 0.0]}
             )

    embedding = fn _url, _body, _timeout ->
      {:ok, %{"data" => [%{"index" => 0, "embedding" => [1.0, 0.0]}]}}
    end

    opts = [url: "http://localhost:9999", model: "test-model", request: embedding]

    assert {:ok, %{"items" => [_match], "meaning_search" => true}} =
             IssueIndex.search(configured, "zero rows download fails", opts)

    settings = Settings.fetch!()

    {:ok, _saved} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          installation_id: 41,
          repository_id: 100,
          ryker_actor_id: 4321
        },
        settings.installation.revision,
        @actor
      )

    assert IssueIndex.search(configured, "CSV", url: nil) == {:error, :repository_access_changed}
    {:ok, current} = IssueIndex.configuration("widget-app")
    assert {:ok, %{"items" => []}} = IssueIndex.search(current, "zero rows download fails", opts)
  end

  test "outside contributor webhook queues read-only triage only when the repository opted in", %{
    configured: configured
  } do
    payload = %{
      "action" => "opened",
      "issue" => %{"number" => 12, "state" => "open"},
      "sender" => %{"id" => 7}
    }

    assert IssueIndex.signal(configured.binding, "issues", payload) == :ok
    assert Repo.one(IndexedIssue).triage_pending
    settings = Settings.fetch!()

    {:ok, _saved} =
      Settings.put_repository(
        %{ref: "widget", github_issue_triage: false},
        settings.installation.revision,
        @actor
      )

    assert IssueIndex.signal(
             configured.binding,
             "issues",
             put_in(payload, ["issue", "number"], 13)
           ) == :ok

    assert Repo.aggregate(IndexedIssue, :count) == 1
  end

  test "the worker starts a quiet backfill and persists its cursor across runs", %{
    configured: configured
  } do
    options =
      IssueTriageWorker.options!(%{
        bindings: %{"widget-app" => %{read_client: :fixture}},
        api: __MODULE__.API
      })

    assert IssueTriageWorker.run_once(options) == {:ok, :updated}
    assert Repo.one(IssueIndexState).backfill_complete
    assert Repo.aggregate(IndexedIssue, :count) == 0
    assert Repo.aggregate(Ryker.GitHubActions.IssueRequest, :count) == 0
    assert_received {:backfill_page, 1}
    assert IssueTriageWorker.run_once(options) == {:ok, :updated}
    refute_received {:backfill_page, _page}
    assert IssueTriageWorker.run_once(options) == {:ok, :idle}
    assert {:ok, _index} = IssueIndex.ensure(configured)
  end

  # The dependency gate left a deleted issue searchable when the database clock
  # ran ahead: the worker backfilled instead of fetching the already-due refresh.
  test "a deleted issue is removed from search even when the database clock runs ahead", %{
    configured: configured
  } do
    DatabaseClock.ahead_of_host!()
    {:ok, issue} = IssueIndex.enqueue(configured, 12, false)
    {:ok, claimed} = IssueIndex.claim_next(["widget-app"])

    {:ok, _saved} =
      IssueIndex.refreshed(claimed, issue, configured, document(12, "CSV export"), {nil, nil})

    {:ok, _saved} = IssueIndex.settled(claimed, issue, configured, nil)
    {:ok, _issue} = IssueIndex.enqueue(configured, 12, true)

    options =
      IssueTriageWorker.options!(%{
        bindings: %{"widget-app" => %{read_client: :fixture}},
        api: __MODULE__.API
      })

    assert IssueTriageWorker.run_once(options) == {:ok, :updated}
    assert {:ok, %{"items" => []}} = IssueIndex.search(configured, "CSV", url: nil)
    refute Repo.get!(IndexedIssue, issue.id).pending
    assert Repo.aggregate(Ryker.GitHubActions.IssueRequest, :count) == 0
  end

  test "a host clock ahead of the database cannot make an issue retry run early", %{
    configured: configured
  } do
    now = DatabaseClock.behind_host!()
    {:ok, issue} = IssueIndex.enqueue(configured, 12, false)
    {:ok, claimed} = IssueIndex.claim_next(["widget-app"])

    issue
    |> IndexedIssue.Changeset.update(%{next_attempt_at: DateTime.add(now, 30)})
    |> Repo.update!()

    assert IssueIndex.fetch_next_issue(claimed) == {:error, :not_found}
  end

  defmodule API do
    @moduledoc false
    def repository(:fixture, "acme/widget", 99), do: :ok

    def page(:fixture, "acme/widget", page) do
      send(self(), {:backfill_page, page})
      {:ok, %{numbers: [], complete: true}}
    end

    def read(_client, _repository, _number), do: {:error, :issue_unavailable}
  end

  defp document(number, title),
    do: %{"issue" => %{"number" => number, "title" => title}, "discussion" => %{"items" => []}}
end
