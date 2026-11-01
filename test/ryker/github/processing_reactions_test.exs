defmodule Ryker.GitHub.ProcessingReactionsTest do
  use Ryker.DataCase, async: true
  alias Ryker.Episodes.{Episode, Origin}
  alias Ryker.GitHub.{Client, ProcessingReaction, ProcessingReactions, ProcessingReactionWorker}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.TestSupport.GitHubRequester
  alias Ryker.Work.{Session, Turn}

  @target %{comment_kind: "issue_comment", comment_id: 9_001}
  @binding %{repository_id: 99, ryker_actor_id: 88}

  test "current live user comments receive eyes and settled comments lose only the App receipt" do
    input = input!()
    requester = requester!([reaction(201, 7_001), response(204, nil)])
    binding = delivery_binding(requester)

    assert ProcessingReactionWorker.run_once("github-main", binding) == {:ok, 1}
    assert ProcessingReactionWorker.run_once("github-main", binding) == {:ok, 0}
    assert Repo.get_by!(ProcessingReaction, comment_id: 9_001).reaction_id == 7_001

    ignore!(input)
    assert ProcessingReactionWorker.run_once("github-main", binding) == {:ok, 1}
    assert Repo.all(ProcessingReaction) == []

    assert [
             {:post, "/repos/octo/example/issues/comments/9001/reactions", %{"content" => "eyes"},
              _},
             {:delete, "/repos/octo/example/issues/comments/9001/reactions/7001", nil, _}
           ] =
             GitHubRequester.requests(requester)
  end

  test "a lost add receipt is recovered after restart even when work already ended" do
    input = input!()
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, abandoned} = ProcessingReactions.claim_next("github-main", @binding)
    assert abandoned.uncertain
    ignore!(input)
    expire!(abandoned)

    requester = requester!([reaction(200, 7_001), response(204, nil)])

    assert ProcessingReactionWorker.run_once("github-main", delivery_binding(requester)) ==
             {:ok, 1}

    assert Repo.all(ProcessingReaction) == []
    assert length(GitHubRequester.requests(requester)) == 2
  end

  test "new desired state waits for an older write and its receipt cannot erase newer work" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, add} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])
    assert ProcessingReactions.claim_next("github-main", @binding) == {:ok, nil}

    assert {:ok, %{desired: false, reaction_id: 7_001}} =
             ProcessingReactions.settle(add, {:ok, 7_001})

    assert {:ok, remove} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])

    assert {:ok, %{desired: true, reaction_id: nil}} =
             ProcessingReactions.settle(remove, {:ok, nil})

    assert {:ok, %{desired: true}} = ProcessingReactions.claim_next("github-main", @binding)
  end

  test "an expired claimant cannot settle a replacement claim" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, old} = ProcessingReactions.claim_next("github-main", @binding)
    expire!(old)
    assert {:ok, current} = ProcessingReactions.claim_next("github-main", @binding)
    refute current.lease_ref == old.lease_ref

    assert ProcessingReactions.settle(old, {:ok, 7_001}) ==
             {:error, :github_processing_lease_lost}
  end

  test "an expired unreclaimed lease cannot settle" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, claim} = ProcessingReactions.claim_next("github-main", @binding)
    expire!(claim)

    assert ProcessingReactions.settle(claim, {:ok, 7_001}) ==
             {:error, :github_processing_lease_lost}
  end

  test "new work recovers eyes after an uncertain deletion, including an abandoned cleanup lease" do
    for outcome <- [:lost_reply, :restart] do
      assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
      assert {:ok, add} = ProcessingReactions.claim_next("github-main", @binding)
      assert {:ok, _} = ProcessingReactions.settle(add, {:ok, 7_001})
      assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])
      assert {:ok, remove} = ProcessingReactions.claim_next("github-main", @binding)
      assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])

      case outcome do
        :lost_reply -> assert {:ok, _} = ProcessingReactions.settle(remove, {:error, :closed})
        :restart -> expire!(remove)
      end

      assert {:ok, %ProcessingReaction{desired: true} = recovered} =
               ProcessingReactions.claim_next("github-main", @binding)

      assert recovered.desired
      assert recovered.uncertain
      assert {:ok, _} = ProcessingReactions.settle(recovered, {:ok, 7_002})
      assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])
      assert {:ok, cleanup} = ProcessingReactions.claim_next("github-main", @binding)
      assert {:ok, _} = ProcessingReactions.settle(cleanup, {:ok, nil})
    end
  end

  test "an old failed write cannot block cleanup requested while the request was in flight" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, add} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])

    assert {:ok, %{blocked: false, desired: false, attempt_count: 0}} =
             ProcessingReactions.settle(add, {:error, {:github_api_error, 403, %{}}})

    assert {:ok, %{desired: false}} = ProcessingReactions.claim_next("github-main", @binding)
  end

  test "only current active inputs show eyes and blocked turns and waiting or terminal episodes clear them" do
    input = input!()

    episode =
      Repo.insert!(%Episode{
        key: "processing:#{input.id}",
        state: :working,
        owner_kind: :turn,
        owner_ref: "turn:processing",
        execution_mode: :live,
        destination_transport: "chat",
        destination_conversation_ref: "chat:processing",
        active_input_refs: ["input:processing"]
      })

    Repo.insert!(%Origin{
      episode_id: episode.id,
      input_ref: "input:processing",
      sequence: 1,
      native_input_id: input.native_input_id,
      revision: input.revision,
      actor_ref: "github:user:github-user:7",
      transport: "github",
      conversation_ref: input.destination_conversation_ref,
      thread_ref: input.destination_thread_ref,
      source_kind: "github",
      source_ref: "github-main",
      source_item_ref: input.source_item_ref,
      origin_kind: :conversation,
      occurred_at: input.occurred_at
    })

    input
    |> Ecto.Changeset.change(
      status: :decided,
      decision_action: :continue_episode,
      episode_id: episode.id,
      decision_ref: "decision:#{input.id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{}
    )
    |> Repo.update!()

    session =
      Repo.insert!(%Session{
        episode_id: episode.id,
        external_ref: "processing:#{input.id}",
        policy: "ryker-work",
        policy_digest: String.duplicate("a", 64)
      })

    turn =
      Repo.insert!(%Turn{
        episode_id: episode.id,
        session_id: session.id,
        turn_ref: episode.owner_ref,
        status: :pending
      })

    assert ProcessingReactions.active_targets("github-main", 99) == [@target]
    turn |> Ecto.Changeset.change(status: :blocked) |> Repo.update!()
    assert ProcessingReactions.active_targets("github-main", 99) == []
    turn |> Ecto.Changeset.change(status: :pending) |> Repo.update!()

    for {state, owner_kind, owner_ref} <- [
          {:waiting_for_input, :input, "wait:input"},
          {:waiting_for_event, :event, "wait:event"},
          {:complete, nil, nil},
          {:cancelled, nil, nil}
        ] do
      episode
      |> Ecto.Changeset.change(
        state: state,
        owner_kind: owner_kind,
        owner_ref: owner_ref,
        active_input_refs: []
      )
      |> Repo.update!()

      assert ProcessingReactions.active_targets("github-main", 99) == []
    end

    Repo.get!(Episode, episode.id)
    |> Ecto.Changeset.change(
      state: :working,
      owner_kind: :turn,
      owner_ref: "turn:processing",
      active_input_refs: ["input:newer"]
    )
    |> Repo.update!()

    assert ProcessingReactions.active_targets("github-main", 99) == []
  end

  test "quota waits keep their attempt budget and deleted targets stop until state changes" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, claim} = ProcessingReactions.claim_next("github-main", @binding)

    assert {:ok, limited} =
             ProcessingReactions.settle(
               claim,
               {:error, {:delivery_rate_limited, 120, :quota}}
             )

    assert limited.attempt_count == 0
    refute limited.blocked
    assert DateTime.diff(limited.next_attempt_at, DateTime.utc_now()) in 119..120
    assert ProcessingReactions.claim_next("github-main", @binding) == {:ok, nil}
    limited |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()
    assert {:ok, claim} = ProcessingReactions.claim_next("github-main", @binding)

    assert {:ok, %{blocked: true}} =
             ProcessingReactions.settle(
               claim,
               {:error, {:github_api_error, 404, %{"message" => "gone"}}}
             )

    assert ProcessingReactions.claim_next("github-main", @binding) == {:ok, nil}
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])
    assert {:ok, %{desired: false}} = ProcessingReactions.claim_next("github-main", @binding)
  end

  test "binding repository and actor fences preserve other installations' custody" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])

    assert {:ok, _} =
             ProcessingReactions.reconcile("github-main", %{@binding | repository_id: 100}, [])

    assert ProcessingReactions.claim_next("github-main", %{@binding | ryker_actor_id: 89}) ==
             {:ok, nil}

    assert {:ok, %{comment_id: 9_001}} = ProcessingReactions.claim_next("github-main", @binding)
  end

  test "cleanup survives more than eight failures and resumes after permission repair" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, add} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.settle(add, {:ok, 7_001})
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [])

    for attempt <- 1..10 do
      assert {:ok, remove} = ProcessingReactions.claim_next("github-main", @binding)
      reason = if attempt == 10, do: {:github_api_error, 403, %{}}, else: :closed
      assert {:ok, retried} = ProcessingReactions.settle(remove, {:error, reason})
      refute retried.blocked
      assert retried.reaction_id == 7_001
      assert retried.attempt_count == attempt
      retried |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()
    end

    assert {:ok, remove} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.settle(remove, {:ok, nil})
    assert Repo.all(ProcessingReaction) == []
  end

  test "an admission backlog cannot suspend cleanup of a settled comment" do
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, add} = ProcessingReactions.claim_next("github-main", @binding)
    assert {:ok, _} = ProcessingReactions.settle(add, {:ok, 7_001})
    targets = Enum.map(10_001..11_001, &%{comment_kind: "issue_comment", comment_id: &1})
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, targets)
    assert {:ok, cleanup} = ProcessingReactions.claim_next("github-main", @binding)
    refute cleanup.desired
    assert cleanup.reaction_id == 7_001
    assert {:ok, _} = ProcessingReactions.settle(cleanup, {:ok, nil})
    assert Repo.get_by(ProcessingReaction, comment_id: 9_001) == nil
    assert Repo.aggregate(ProcessingReaction, :count) == 1_001
  end

  test "a deleted comment during uncertain cleanup is already clear" do
    input = input!()
    assert {:ok, _} = ProcessingReactions.reconcile("github-main", @binding, [@target])
    assert {:ok, abandoned} = ProcessingReactions.claim_next("github-main", @binding)
    expire!(abandoned)
    ignore!(input)
    requester = requester!([response(404, %{})])

    assert ProcessingReactionWorker.run_once("github-main", delivery_binding(requester)) ==
             {:ok, 1}

    assert Repo.all(ProcessingReaction) == []
  end

  test "a newer deletion clears eyes even if an older admission remains pending" do
    input!()
    input!(revision: 2, event_kind: :delete)
    assert ProcessingReactions.active_targets("github-main", 99) == []
  end

  test "shadow comments, bots, review summaries and other repositories receive no processing eyes" do
    input!(execution_mode: :shadow)

    input!(
      native_input_id: "bot",
      source_item_ref: "github:issue_comment:9002",
      actor: %{kind: :bot, ref: "github-user:8"}
    )

    input!(native_input_id: "review", source_item_ref: "github:pull_request_review:9003")
    assert ProcessingReactions.active_targets("github-main", 99) == []
    assert ProcessingReactions.active_targets("github-main", 100) == []
  end

  test "the client recovers only its own eyes and deletes at the exact comment endpoint" do
    for {kind, path} <- [{"issue_comment", "issues"}, {"pull_request_review_comment", "pulls"}] do
      requester =
        requester!([
          reaction(200, 7_001),
          response(204, nil),
          response(404, %{}),
          response(201, %{"id" => 5, "content" => "eyes", "user" => %{"id" => 123}})
        ])

      client = client(requester)

      assert Client.ensure_processing_reaction(client, "octo/example", kind, 9_001, 88) ==
               {:ok, 7_001}

      assert Client.remove_processing_reaction(client, "octo/example", kind, 9_001, 7_001) == :ok
      assert Client.remove_processing_reaction(client, "octo/example", kind, 9_001, 7_001) == :ok

      assert Client.ensure_processing_reaction(client, "octo/example", kind, 9_001, 88) ==
               {:error, {:github_protocol_error, :processing_reaction}}

      assert [{:post, "/repos/octo/example/" <> rest, _, _} | _] =
               GitHubRequester.requests(requester)

      assert rest == "#{path}/comments/9001/reactions"
    end
  end

  defp input!(overrides \\ []) do
    attributes =
      %{
        actor: %{kind: :user, ref: "github-user:7"},
        content: %{"text" => "Please investigate"},
        destination: %{
          conversation_ref: "github:github-main:repository:99",
          thread_ref: "github:github-main:pull:42",
          transport: "github"
        },
        event_kind: :message,
        event_ref: "delivery:#{Ecto.UUID.generate()}",
        native_input_id: "comment:9001",
        source_item_ref: "github:issue_comment:9001",
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :source,
        source_capabilities: %{},
        revision: 1,
        source: %{kind: "github", ref: "github-main"}
      }
      |> Map.merge(Map.new(overrides))

    {execution_mode, attributes} = Map.pop(attributes, :execution_mode, :live)
    {:ok, input} = Input.new(attributes)
    {:ok, %{entry: entry}} = Inbox.record(input, execution_mode: execution_mode)
    entry
  end

  defp ignore!(input) do
    input
    |> Ecto.Changeset.change(
      status: :decided,
      decision_action: :ignore,
      decision_ref: "decision:#{input.id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{}
    )
    |> Repo.update!()
  end

  defp expire!(reaction) do
    reaction
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()
  end

  defp requester!(responses), do: elem(GitHubRequester.start(responses), 1)
  defp client(requester), do: %Client{http: requester, requester: GitHubRequester}

  defp delivery_binding(requester) do
    Map.merge(@binding, %{client: client(requester), repository_full_name: "octo/example"})
  end

  defp response(status, body), do: {:ok, %{status: status, body: body, headers: []}}

  defp reaction(status, id),
    do: response(status, %{"id" => id, "content" => "eyes", "user" => %{"id" => 88}})
end
