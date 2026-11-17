defmodule Ryker.GitHub.LabelWorkerTest do
  use Ryker.DataCase, async: true
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.GitHub.{Client, Labels, LabelWorker}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Publication.{Custody, Followup}
  alias Ryker.TestSupport.GitHubRequester

  test "a pending PR request gains the working label and settling it clears only that label" do
    entry = pending_request!()

    {:ok, requester} =
      GitHubRequester.start([
        response(200, [%{"name" => "ryker:working"}]),
        response(200, [])
      ])

    binding = delivery_binding(requester)

    assert LabelWorker.run_once("github-main", binding, Client, MapSet.new()) ==
             {:ok, MapSet.new([42])}

    ignore!(entry)

    assert LabelWorker.run_once("github-main", binding, Client, MapSet.new([42])) ==
             {:ok, MapSet.new()}

    assert [
             {:post, "/repos/octo/example/issues/42/labels", _, _},
             {:delete, "/repos/octo/example/issues/42/labels/ryker%3Aworking", nil, _}
           ] = GitHubRequester.requests(requester)
  end

  test "restart discovers and clears a working label left on a closed or finished PR" do
    [review, working] = Labels.definitions()

    {:ok, requester} =
      GitHubRequester.start([
        response(200, %{"name" => review.name}),
        response(200, %{"name" => working.name}),
        response(200, [%{"number" => 42, "pull_request" => %{}}]),
        response(200, [])
      ])

    assert LabelWorker.run_once("github-main", delivery_binding(requester), Client, nil) ==
             {:ok, MapSet.new()}

    assert {:delete, "/repos/octo/example/issues/42/labels/ryker%3Aworking", nil, _} =
             List.last(GitHubRequester.requests(requester))
  end

  # A rebased update was recovered manually, but 197 refused review attempts
  # kept its PR labelled working while the episode waited for an event.
  test "a failed publication clears its working label until a retry actually runs" do
    %{episode: episode, publication: publication} =
      PublicationFixture.review_requested!("failed-label")

    episode
    |> Ecto.Changeset.change(
      state: :waiting_for_event,
      owner_kind: :event,
      owner_ref: "wait:failed-publication"
    )
    |> Repo.update!()

    publication
    |> Ecto.Changeset.change(
      github_repository: "octo/example",
      pull_request_number: 42,
      pull_request_url: "https://github.com/octo/example/pull/42",
      branch_ref: "refs/heads/ryker/failed-label",
      commit_sha: String.duplicate("a", 40),
      last_error_code: "coop_error",
      last_error_detail:
        "review source no longer contains the admitted source commit; restore the task branch before retrying",
      attempt_count: 197
    )
    |> Repo.update!()

    Repo.insert!(%Followup{
      publication_id: publication.id,
      episode_id: episode.id,
      next_poll_at: Repo.now!(),
      deadline_at: DateTime.add(Repo.now!(), 3600)
    })

    {:ok, requester} = GitHubRequester.start([response(200, [])])
    binding = delivery_binding(requester)

    assert Labels.active_pulls("github-main", binding) == MapSet.new()

    assert LabelWorker.run_once("github-main", binding, Client, MapSet.new([42])) ==
             {:ok, MapSet.new()}

    assert [{:delete, "/repos/octo/example/issues/42/labels/ryker%3Aworking", nil, _}] =
             GitHubRequester.requests(requester)

    assert {:ok, retry} = Custody.claim_next("label-publication-retry", 60)
    assert retry.publication.id == publication.id
    assert Labels.active_pulls("github-main", binding) == MapSet.new([42])

    retry.publication
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Repo.now!(), -1))
    |> Repo.update!()

    assert Labels.active_pulls("github-main", binding) == MapSet.new()

    assert {:ok, _} = Custody.recover(publication.ref, :retry, publication.recovery_generation)
    assert Labels.active_pulls("github-main", binding) == MapSet.new([42])
  end

  @tag capture_log: true
  test "an uncertain label write is reread even if the request has since ended" do
    entry = pending_request!()
    [review, working] = Labels.definitions()

    {:ok, requester} =
      GitHubRequester.start([
        {:error, :timeout},
        response(200, %{"name" => review.name}),
        response(200, %{"name" => working.name}),
        response(200, [%{"number" => 42, "pull_request" => %{}}]),
        response(200, [])
      ])

    binding = delivery_binding(requester)
    {:ok, state} = LabelWorker.setup(bindings: %{"github-main" => binding})

    previous = %{
      numbers: MapSet.new(),
      refresh_at: DateTime.add(DateTime.utc_now(), 300),
      retry_at: nil
    }

    state = %{state | observed: %{"github-main" => previous}}
    {_, failed} = LabelWorker.poll(state)
    assert failed.observed["github-main"].numbers == nil
    assert DateTime.compare(failed.observed["github-main"].retry_at, DateTime.utc_now()) == :gt
    ignore!(entry)
    retry = put_in(failed.observed["github-main"].retry_at, DateTime.add(DateTime.utc_now(), -1))
    {_, settled} = LabelWorker.poll(retry)
    assert settled.observed["github-main"].numbers == MapSet.new()
    assert {:delete, _, nil, _} = List.last(GitHubRequester.requests(requester))
  end

  defp pending_request! do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "github-user:7"},
        content: %{"body" => "Review this PR"},
        destination: %{
          transport: "github",
          conversation_ref: "github:github-main:repository:99",
          thread_ref: "github:github-main:pull:42"
        },
        event_kind: :message,
        event_ref: "event:label-test",
        native_input_id: "label-test",
        source_item_ref: "github:issue_comment:9001",
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :source,
        source_capabilities: %{},
        revision: 1,
        source: %{kind: "github", ref: "github-main"}
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp ignore!(entry) do
    entry
    |> Ecto.Changeset.change(
      status: :decided,
      decision_action: :ignore,
      decision_ref: "decision:#{entry.id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{}
    )
    |> Repo.update!()
  end

  defp delivery_binding(requester),
    do: %{
      repository_full_name: "octo/example",
      repository_id: 99,
      client: %Client{http: requester, requester: GitHubRequester}
    }

  defp response(status, body), do: {:ok, %{status: status, body: body, headers: []}}
end
