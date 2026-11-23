defmodule Ryker.GitHub.CIRepairsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Config
  alias Ryker.GitHub
  alias Ryker.GitHub.{CIRepair, CIRepairAuthority, CIRepairRound, CIRepairs}
  alias Ryker.Ingress
  alias Ryker.Settings
  alias Ryker.Work

  @actor "control-plane:local"
  @head String.duplicate("a", 40)
  @next String.duplicate("b", 40)
  @third String.duplicate("c", 40)

  defmodule SnapshotAPI do
    def snapshot(agent, _repository, _id, _number), do: {:ok, Agent.get(agent, & &1.pull)}
  end

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
        %{ref: "widget", github_repository: "acme/widget", github_ci_repair: :all},
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

    {:ok, binding} =
      GitHub.Binding.new(%{
        name: "widget-app",
        repository_full_name: "acme/widget",
        installation_id: 41,
        repository_id: 99,
        ryker_actor_id: 4321,
        work_profile: %{
          policy: "widget-conversation",
          policy_digest: String.duplicate("d", 64),
          repository_ref: "widget"
        }
      })

    Config.put_override(:github, %{server: %{bindings: %{"widget-app" => binding}}})
    :ok
  end

  defp runtime_binding, do: Config.get_env(:github).server.bindings["widget-app"]

  test "a verified signal cannot cross a changed repository binding" do
    old = runtime_binding()
    settings = Settings.fetch!()

    assert {:ok, _settings} =
             Settings.put_github_binding(
               %{
                 name: old.name,
                 repository_ref: "widget",
                 installation_id: 42,
                 repository_id: 100,
                 ryker_actor_id: 4321
               },
               settings.installation.revision,
               @actor
             )

    assert CIRepairs.nudge(old, 12, @head) == {:error, :ci_repair_binding_changed}
    assert Repo.aggregate(CIRepair, :count) == 0
  end

  test "verified check and label signals share the same queued repair" do
    binding = runtime_binding()

    payload = %{
      "installation" => %{"id" => 41},
      "repository" => %{"id" => 99, "full_name" => "acme/widget"},
      "action" => "completed",
      "check_run" => %{"head_sha" => @head, "pull_requests" => [%{"number" => 12}]}
    }

    assert GitHub.CIRepairSignals.observe(binding, "check_run", payload) == :ok
    assert GitHub.CIRepairSignals.observe(binding, "check_run", payload) == :ok
    assert Repo.aggregate(CIRepair, :count) == 1
    assert Repo.aggregate(CIRepairRound, :count) == 0

    label =
      payload
      |> Map.delete("check_run")
      |> Map.merge(%{
        "action" => "unlabeled",
        "label" => %{"name" => "ryker:no-ci-fix"},
        "pull_request" => %{"number" => 12, "head" => %{"sha" => @head}}
      })

    assert GitHub.CIRepairSignals.observe(binding, "pull_request", label) == :ok
    assert Repo.one!(CIRepair).refresh_requested
    forged = put_in(payload, ["repository", "id"], 100)

    assert GitHub.CIRepairSignals.observe(binding, "check_run", forged) ==
             {:error, {:invalid_github_input, :repository}}
  end

  test "own-PR polling queues the same policy and cannot follow a reused repository alias" do
    settings = Settings.fetch!()

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "example/repository", github_ci_repair: :own},
        settings.installation.revision,
        @actor
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          repository_id: 17,
          installation_id: 41,
          ryker_actor_id: 4321
        },
        settings.installation.revision,
        @actor
      )

    %{publication: publication} =
      Ryker.Fixtures.Publication.published!("ci-policy-poll",
        repository: "widget",
        github_repository: "example/repository",
        pull_request_number: 12
      )

    {:ok, poll} = Ryker.Publication.Followups.claim_poll("ci-policy-poll", 60)

    observation = %{
      "base_ref" => "main",
      "checks_failed" => 1,
      "checks_passed" => 0,
      "checks_state" => "failing",
      "checks_total" => 1,
      "checks_url" => publication.pull_request_url <> "/checks",
      "draft" => false,
      "head_ref" => String.replace_prefix(publication.branch_ref, "refs/heads/", ""),
      "head_sha" => publication.commit_sha,
      "merge_sha" => nil,
      "merged" => false,
      "merged_at" => nil,
      "number" => 12,
      "state" => "open",
      "url" => publication.pull_request_url
    }

    assert {:ok, _followup} =
             Ryker.Publication.Followups.store_poll(publication.ref, poll.lease_ref, observation)

    event =
      Repo.get_by!(Ryker.Publication.LifecycleEvent,
        publication_id: publication.id,
        kind: :checks
      )

    assert GitHub.CIRepairSignals.observe_lifecycle(event.ref) == :ok
    repair = Repo.one!(CIRepair)
    assert repair.pending_heads == [publication.commit_sha]
    assert repair.repository_id == 17

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          repository_id: 100,
          installation_id: 41,
          ryker_actor_id: 4321
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    assert GitHub.CIRepairSignals.observe_lifecycle(event.ref) == :ok
    assert Repo.one!(CIRepair).revision == repair.revision
  end

  test "a PR stays silent until an automatic repair starts" do
    # A human PR received a repair announcement before CI finished under Ryker-only policy.
    {:ok, _settings} =
      Settings.put_repository(
        %{ref: "widget", github_ci_repair: :own},
        Settings.fetch!().installation.revision,
        @actor
      )

    pending = put_in(snapshot(@head), ["checks", "state"], "pending")

    {:ok, agent} =
      Agent.start_link(fn ->
        %{pull: pending, marker: nil, body: nil, creates: 0, updates: 0, lose_response: false}
      end)

    options = worker_options(agent)

    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :updated}
    assert Agent.get(agent, & &1.creates) == 0
    assert Repo.aggregate(CIRepairRound, :count) == 0
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :idle}

    {:ok, _settings} =
      Settings.put_repository(
        %{ref: "widget", github_ci_repair: :all},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :updated}
    assert Agent.get(agent, & &1.creates) == 0
    assert Repo.aggregate(CIRepairRound, :count) == 0
    assert Repo.one!(CIRepair).next_attempt_at

    Agent.update(agent, &%{&1 | pull: snapshot(@head)})
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :updated}
    assert Agent.get(agent, & &1.creates) == 1
    assert Repo.aggregate(CIRepairRound, :count) == 1
  end

  test "a lost PR comment response does not duplicate the repair or its status comment" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          pull: snapshot(@head),
          marker: nil,
          body: nil,
          creates: 0,
          updates: 0,
          lose_response: true
        }
      end)

    options = worker_options(agent)

    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :deferred}
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :updated}
    assert Repo.aggregate(CIRepairRound, :count) == 1
    assert Agent.get(agent, & &1.creates) == 1
    Agent.update(agent, &put_in(&1.pull["labels"], ["ryker:no-ci-fix"]))
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert GitHub.CIRepairWorker.run_once(options) == {:ok, :updated}
    assert Agent.get(agent, & &1.body) =~ "Automatic changes are disabled by ryker:no-ci-fix"
    refute Repo.one!(CIRepair).allowed
    assert Agent.get(agent, & &1.creates) == 1
  end

  test "fresh publication checks refuse a newly applied label without trusting the admission snapshot" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    projected = evaluate!(snapshot(@head))

    pull = %{
      "number" => 12,
      "state" => "open",
      "merged" => false,
      "base" => %{"repo" => %{"id" => 99}, "ref" => "main"},
      "head" => %{"repo" => %{"id" => 99}, "ref" => "fix", "sha" => @head},
      "user" => %{"id" => 7, "type" => "User"}
    }

    {:ok, agent} =
      Ryker.TestSupport.GitHubRequester.start([
        {:ok, %{status: 200, body: pull}},
        {:ok, %{status: 200, body: [%{"name" => "ryker:no-ci-fix"}]}}
      ])

    client = %GitHub.Client{http: agent, requester: Ryker.TestSupport.GitHubRequester}

    assert CIRepairAuthority.fresh(projected.round.snapshot["target"], client) ==
             {:error, :publication_grant_denied}

    assert Repo.one!(CIRepair).allowed

    assert Enum.map(Ryker.TestSupport.GitHubRequester.requests(agent), &elem(&1, 0)) == [
             :get,
             :get
           ]
  end

  test "a CI policy instruction cannot start a different saved proposal" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))

    source =
      first.round.entry_id
      |> then(&Repo.get!(Ingress.Inbox.Entry, &1))
      |> Ryker.Fixtures.Corrections.from_entry!()

    payload =
      Ryker.Fixtures.TaskOffer.payload(%{
        "repository" => "widget",
        "instruction_ref" => source.arguments["source_event_ref"],
        "prompt" => "Replace the whole application",
        "repository_source" => %{"kind" => "commit", "sha" => @head}
      })

    authorize = fn _, _ ->
      {:ok,
       %{name: "widget-contributor", digest: String.duplicate("d", 64), repository_ref: "widget"}}
    end

    assert {:ok, offered} =
             Ryker.StateTools.TaskTools.request_task(
               Map.put(payload, "start", false),
               source.binding
             )

    sessions = Repo.aggregate(Work.Session, :count)

    assert Ryker.Records.TaskOffers.start(
             source.binding,
             payload,
             authorize,
             offered["record_ref"]
           ) == {:error, :task_instruction_not_authorized}

    assert Ryker.Records.TaskOffers.start(source.binding, payload, authorize, nil) ==
             {:error, :state_record_operation_conflict}

    assert Repo.get_by!(Ryker.Records.Record, ref: offered["record_ref"]).confirmed_episode_id ==
             nil

    assert Repo.aggregate(Work.Session, :count) == sessions
  end

  test "an admitted policy request starts an exact existing-PR task and opt-out stops its work" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))
    entry = Repo.get!(Ingress.Inbox.Entry, first.round.entry_id)
    source = Ryker.Fixtures.Corrections.from_entry!(entry)

    policy = %{
      name: "widget-contributor",
      digest: String.duplicate("d", 64),
      repository_ref: "widget"
    }

    options = %{
      configuration: GitHub.TaskAccess.authority_configuration(Settings.fetch!()),
      bindings: %{
        "widget-app" => %{
          binding: Config.get_env(:github).server.bindings["widget-app"],
          repository: "widget",
          policy: policy
        }
      },
      repository_access: fn _, _ ->
        flunk("A repository-policy grant must not impersonate a GitHub user")
      end
    }

    authorize = fn
      {:policy, request}, repository -> GitHub.TaskAccess.policy(request, repository, options)
      request, repository -> GitHub.TaskAccess.authorize(request, repository, options)
    end

    payload =
      Ryker.Fixtures.TaskOffer.payload(%{
        "repository" => "widget",
        "instruction_ref" => source.arguments["source_event_ref"],
        "prompt" => "Replace the whole application"
      })

    assert {:ok, started} =
             Ryker.Records.TaskOffers.start(source.binding, payload, authorize, nil)

    record = Repo.get_by!(Ryker.Records.Record, ref: started["record_ref"])
    session = Repo.get_by!(Work.Session, episode_id: record.confirmed_episode_id)
    assert session.repository_source == %{"kind" => "commit", "sha" => @head}
    assert session.publication_target["authorization"]["round_id"] == first.round.id
    assert session.workspace_task["prompt"] =~ "Reproduce the failure"
    refute session.workspace_task["prompt"] =~ "Replace the whole application"
    {:ok, _released} = delivered!(first)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    stopped = evaluate!(Map.put(snapshot(@head), "labels", ["ryker:no-ci-fix"]))
    assert GitHub.CIRepairStop.request(stopped) == :ok
    turn = Repo.get_by!(Work.Turn, episode_id: record.confirmed_episode_id)
    assert turn.status == :blocked
    assert turn.cancellation_intent["action"] == "block"
    assert Repo.get!(Work.Session, session.id).workspace_task == session.workspace_task

    {:ok, _released} = delivered!(stopped)
    assert {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head, true)
    restarted = evaluate!(snapshot(@head))
    assert restarted.round.ordinal == 2
    assert restarted.round.id != first.round.id
    assert Repo.get!(CIRepairRound, first.round.id).outcome["status"] == "stopped"
  end

  test "duplicate failure signals and a restart keep one active repair and its exact head" do
    assert {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    assert {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))
    assert first.repair.rounds == 1
    assert first.repair.allowed
    assert first.round.head == @head
    assert {:ok, _released} = delivered!(first)
    assert {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    repeated = evaluate!(snapshot(@head))
    assert repeated.round.id == first.round.id
    assert Repo.aggregate(CIRepairRound, :count) == 1
    assert Repo.aggregate(Ingress.Inbox.Entry, :count) == 1
    entry = Repo.get!(Ingress.Inbox.Entry, first.round.entry_id)
    assert {:ok, target} = Work.PublicationTarget.from_input(entry, "widget")
    assert target["head_commit"] == @head
    assert target["reason"] == "automatic_ci_repair"
    assert target["authorization"]["round_id"] == first.round.id

    assert CIRepairAuthority.instruction(entry, "another") ==
             {:error, :task_instruction_not_authorized}
  end

  test "Ryker follow-up commits spend the same two-round budget and passing CI closes it" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))
    published!(first, @next)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @next)
    second = evaluate!(snapshot(@next))
    assert second.round.ordinal == 2
    assert second.round.generation == first.round.generation
    published!(second, @third)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @third)
    exhausted = evaluate!(snapshot(@third))
    assert exhausted.repair.status == "limit_reached"
    refute exhausted.repair.allowed
    assert Repo.aggregate(CIRepairRound, :count) == 2
    {:ok, _released} = delivered!(exhausted)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @third)
    passing = evaluate!(put_in(snapshot(@third), ["checks", "state"], "passing"))
    # The live status said zero rounds immediately after a successful repair.
    assert {:ok, message} = Ryker.GitHub.CIRepairMessages.request(passing)
    assert message.document["message"] =~ "Repair rounds used: 2 of 2"
    assert passing.repair.rounds == 0
    assert passing.repair.generation == first.round.generation + 1
    assert Repo.get!(CIRepairRound, first.round.id).outcome["commit"] == @next
  end

  test "a pushed fix with a target warning cannot trigger a second automatic round" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))

    warning = %{
      "status" => "publication_needs_attention",
      "commit" => @next,
      "terminal" => true,
      "target_observation" => %{"state" => "changed_after_push"}
    }

    first.round |> CIRepairRound.Changeset.finish(warning, Repo.now!()) |> Repo.update!()
    {:ok, _released} = delivered!(first)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @next, true)
    stopped = evaluate!(snapshot(@next))
    assert stopped.repair.status == "publication_needs_attention"
    refute stopped.repair.allowed
    refute stopped.pending
    assert stopped.round.outcome == warning
    assert Repo.aggregate(CIRepairRound, :count) == 1
    {:ok, request} = GitHub.CIRepairMessages.request(stopped)
    assert request.document["message"] =~ "Automatic repair has stopped"
  end

  test "skip and Off revoke an active round without deleting its accepted request" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    first = evaluate!(snapshot(@head))
    entry = Repo.get!(Ingress.Inbox.Entry, first.round.entry_id)
    assert {:ok, {_entry, _actor}} = CIRepairAuthority.instruction(entry, "widget")
    {:ok, _released} = delivered!(first)
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    skipped = evaluate!(Map.put(snapshot(@head), "labels", ["ryker:no-ci-fix"]))
    assert skipped.stop
    assert skipped.repair.status == "skipped"

    assert CIRepairAuthority.instruction(entry, "widget") ==
             {:error, :task_instruction_not_authorized}

    assert Repo.get!(Ingress.Inbox.Entry, entry.id).content == entry.content

    {:ok, _settings} =
      Settings.put_repository(
        %{ref: "widget", github_ci_repair: :off},
        Settings.fetch!().installation.revision,
        @actor
      )

    assert CIRepairAuthority.current(first.round.snapshot["target"]) ==
             {:error, :ci_repair_revoked}
  end

  test "a stale head and a signal that races the API read start nothing" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @head)
    {:ok, claimed} = CIRepairs.claim_next(["widget-app"])
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, @next)
    assert CIRepairs.evaluate(claimed, snapshot(@head)) == {:error, :ci_repair_changed}
    {:ok, _released} = CIRepairs.defer(claimed, :ci_repair_changed, 0)
    stale = evaluate!(snapshot(@third))
    assert stale.repair.status == "stale_event"
    assert Repo.aggregate(CIRepairRound, :count) == 0
  end

  test "unlabeled refresh with passing checks does not spend a round" do
    {:ok, _repair} = CIRepairs.nudge(runtime_binding(), 12, nil, true)
    passing = evaluate!(put_in(snapshot(@head), ["checks", "state"], "passing"))
    assert passing.repair.status == "passing"
    assert Repo.aggregate(CIRepairRound, :count) == 0
  end

  defp worker_options(agent) do
    GitHub.CIRepairWorker.options!(%{
      api: SnapshotAPI,
      bindings: %{
        "widget-app" => %{
          api: Ryker.Fixtures.GitHubComments,
          client: agent,
          read_client: agent,
          repository_full_name: "acme/widget",
          repository_id: 99
        }
      }
    })
  end

  defp delivered!(projected) do
    {:ok, request} = GitHub.CIRepairMessages.request(projected)

    {:ok, receipt} =
      Work.DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        "github:widget-app:review:901"
      )

    CIRepairs.delivered(projected, receipt)
  end

  defp evaluate!(pull) do
    assert {:ok, %CIRepair{} = claimed} = CIRepairs.claim_next(["widget-app"])
    assert {:ok, projected} = CIRepairs.evaluate(claimed, pull)
    projected
  end

  defp published!(projected, commit) do
    projected.round
    |> CIRepairRound.Changeset.finish(
      %{"status" => "pull_request_ready", "commit" => commit, "terminal" => true},
      Repo.now!()
    )
    |> Repo.update!()

    assert {:ok, _released} = delivered!(projected)
  end

  defp snapshot(head) do
    %{
      "number" => 12,
      "repository_id" => 99,
      "head_repository_id" => 99,
      "head" => head,
      "branch" => "fix",
      "base_branch" => "main",
      "state" => "open",
      "merged" => false,
      "author_id" => 7,
      "author_type" => "User",
      "labels" => [],
      "checks" => %{"state" => "failing", "failed" => 1, "total" => 1, "passed" => 0}
    }
  end
end
