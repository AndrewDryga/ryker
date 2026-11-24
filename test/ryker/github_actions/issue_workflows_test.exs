defmodule Ryker.GitHubActions.IssueWorkflowsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Config
  alias Ryker.Fixtures.Corrections
  alias Ryker.Fixtures.GitHubActions.Requester
  alias Ryker.GitHub
  alias Ryker.GitHubActions
  alias Ryker.GitHubActions.{IssueInstructions, IssuePlan, IssueRequest}
  alias Ryker.GitHubActions.{IssueWorkflow, IssueWorkflows}
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Settings

  @actor "control-plane:local"
  @commit String.duplicate("a", 40)

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
        %{ref: "ryker", github_repository: "acme/widget"},
        settings.installation.revision,
        @actor
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "ryker",
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
        repository_id: 99,
        installation_id: 41,
        ryker_actor_id: 4321,
        work_profile: %{
          policy: "widget-conversation",
          policy_digest: String.duplicate("b", 64),
          repository_ref: "ryker"
        }
      })

    Config.put_override(:github, %{server: %{bindings: %{"widget-app" => binding}}})
    {:ok, access} = GitHubActions.authorize("widget-app", "writer-token", requester: Requester)

    issue = %{
      "id" => 31,
      "number" => 12,
      "title" => "Handle empty input",
      "body" => "Handle empty input.",
      "updated_at" => "2026-11-17T12:00:00Z",
      "url" => "https://github.com/acme/widget/issues/12"
    }

    %{access: access, issue: issue}
  end

  test "a large accepted issue starts Build this without duplicating its body in ingress" do
    body = String.duplicate("a", 30_000)
    Process.put(:github_issue_body, body)
    {:ok, view} = GitHubActions.issue("widget-app", "writer-token", 12, requester: Requester)

    assert {:ok, %{request: request}} =
             GitHubActions.start_issue(
               "widget-app",
               "writer-token",
               12,
               :build_issue,
               view.expected,
               requester: Requester
             )

    assert request.source_snapshot["issue"]["body"] == body
    entry = Repo.get!(Ingress.Inbox.Entry, request.entry_id)
    assert byte_size(Ryker.CanonicalJSON.encode!(entry.content)) < 12_288
    {source, _request} = admit!(request)

    payload =
      Ryker.Fixtures.TaskOffer.payload(%{
        "instruction_ref" => source.arguments["source_event_ref"]
      })

    authorize = fn _, _ ->
      {:ok,
       %{name: "ryker-contributor", digest: String.duplicate("b", 64), repository_ref: "ryker"}}
    end

    assert {:ok, started} = Records.TaskOffers.start(source.binding, payload, authorize, nil)
    record = Repo.get_by!(Records.Record, ref: started["record_ref"])

    assert Repo.get_by!(Ryker.Work.Session, episode_id: record.confirmed_episode_id).workspace_task[
             "prompt"
           ] =~ body
  end

  test "an oversized direct build offers planning without saving a partial task" do
    Process.put(:github_issue_body, String.duplicate("a", 40_000))
    {:ok, view} = GitHubActions.issue("widget-app", "writer-token", 12, requester: Requester)

    assert GitHubActions.start_issue(
             "widget-app",
             "writer-token",
             12,
             :build_issue,
             view.expected,
             requester: Requester
           ) == {:error, :issue_build_too_large}

    assert Repo.aggregate(IssueRequest, :count) == 0

    assert {:ok, %{request: request}} =
             GitHubActions.start_issue(
               "widget-app",
               "writer-token",
               12,
               :make_plan,
               view.expected,
               requester: Requester
             )

    assert request.kind == :make_plan
  end

  test "a large issue and saved plan retain their full approved text through implementation", %{
    access: access
  } do
    body = String.duplicate("a", 30_000)
    Process.put(:github_issue_body, body)
    {:ok, initial} = GitHubActions.issue("widget-app", "writer-token", 12, requester: Requester)
    {planning, _request} = planning!(access, initial.issue)
    plan_body = String.duplicate("Check the empty input. ", 600)

    {:ok, plan} =
      IssueWorkflows.save(planning.binding, planning.arguments["source_event_ref"], plan_body)

    {:ok, view} = GitHubActions.issue("widget-app", "writer-token", 12, requester: Requester)

    assert {:ok, %{request: request}} =
             GitHubActions.start_issue(
               "widget-app",
               "writer-token",
               12,
               :implement_plan,
               view.expected,
               requester: Requester
             )

    assert request.source_snapshot["issue"]["body"] == body
    assert request.source_snapshot["plan"]["body"] == plan.body
    entry = Repo.get!(Ingress.Inbox.Entry, request.entry_id)
    assert byte_size(Ryker.CanonicalJSON.encode!(entry.content)) < 12_288
  end

  test "opening an issue page creates no workflow or task", %{access: access, issue: issue} do
    view = IssueWorkflows.view(access, issue)
    assert view.plan == nil
    assert view.plans == []
    assert Repo.aggregate(IssueWorkflow, :count) == 0
    assert Repo.aggregate(Ingress.Inbox.Entry, :count) == 0
  end

  test "two writers clicking the same plan request share one durable start", %{
    access: access,
    issue: issue
  } do
    expected = IssueWorkflows.view(access, issue).expected
    assert {:ok, first} = IssueWorkflows.start(access, issue, :make_plan, expected)
    another = %{access | actor: %{"id" => 8, "login" => "another-writer", "type" => "User"}}
    assert {:ok, duplicate} = IssueWorkflows.start(another, issue, :make_plan, expected)
    assert duplicate.request.id == first.request.id
    assert duplicate.status == :duplicate
    assert Repo.aggregate(IssueRequest, :count) == 1
    assert Repo.aggregate(Ingress.Inbox.Entry, :count) == 1
  end

  test "planning cannot authorize code changes and saves its inspected commit once", %{
    access: access,
    issue: issue
  } do
    {source, request} = planning!(access, issue)
    reference = source.arguments["source_event_ref"]

    assert Records.TaskInstruction.fetch(source.binding, reference, nil, "ryker") ==
             {:error, :planning_is_read_only}

    assert IssueInstructions.read_only?(source.binding)

    assert Ryker.StateTools.TaskTools.request_task(%{}, source.binding) ==
             {:error, :planning_is_read_only}

    assert GitHub.CapabilityTools.call("rerun_github_ci", %{}, source.binding, %{}) ==
             {:error, "planning_is_read_only"}

    assert {:ok, plan} = IssueWorkflows.save(source.binding, reference, "Handle empty input.")
    assert plan.source_commit == @commit
    assert plan.revision == 1
    assert {:ok, duplicate} = IssueWorkflows.save(source.binding, reference, plan.body)
    assert duplicate.id == plan.id

    assert IssueWorkflows.save(source.binding, reference, "Different steps.") ==
             {:error, :plan_already_saved}

    assert Repo.aggregate(IssuePlan, :count) == 1
    saved = Repo.get!(IssueRequest, request.id)
    assert saved.outcome == %{"status" => "plan_ready", "plan_id" => plan.id}
  end

  test "reopening a completed plan reuses its original implementation and pull request",
       %{access: access, issue: issue} do
    # Reopening the same saved version after its draft PR was ready queued
    # another build. Refreshing changes the page's request ID, not the plan.
    {source, _} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input."
      )

    first_page = IssueWorkflows.view(access, issue)

    {:ok, %{request: first}} =
      IssueWorkflows.start(access, issue, :implement_plan, first_page.expected)

    outcome = %{
      "status" => "pull_request_ready",
      "terminal" => true,
      "url" => "https://github.com/acme/widget/pull/8"
    }

    Repo.update!(IssueRequest.Changeset.finish(first, outcome, Repo.now!()))

    refreshed = IssueWorkflows.view(access, issue)
    assert refreshed.implementation == outcome
    assert refreshed.expected["request_id"] != first_page.expected["request_id"]

    assert {:ok, %{status: :duplicate, request: duplicate}} =
             IssueWorkflows.start(access, issue, :implement_plan, refreshed.expected)

    assert duplicate.id == first.id
    assert duplicate.outcome == outcome
    assert IssueWorkflows.view(access, issue).progress == outcome

    # A previous release accepted the refreshed page again. Both the issue
    # comment and action page must link to the original PR. Keep both receipts.
    historical =
      first
      |> Map.from_struct()
      |> Map.merge(%{
        request_key: String.duplicate("c", 64),
        entry_id: Ecto.UUID.generate(),
        inserted_at: DateTime.add(first.inserted_at, 1)
      })
      |> IssueRequest.Changeset.insert()
      |> Repo.insert!()

    other_outcome = %{outcome | "url" => "https://github.com/acme/widget/pull/14"}
    Repo.update!(IssueRequest.Changeset.finish(historical, other_outcome, Repo.now!()))

    refreshed.workflow
    |> IssueWorkflow.Changeset.update(%{
      current_request_id: historical.id,
      next_attempt_at: Repo.now!()
    })
    |> Repo.update!()

    assert IssueWorkflows.view(access, issue).progress == outcome
    {:ok, claimed} = GitHubActions.IssueMessages.claim_next(["widget-app"])
    {:ok, projected} = GitHubActions.IssueMessages.request(claimed, "https://ryker.example")
    assert projected.progress == outcome
    assert projected.request.document["message"] =~ "acme/widget/pull/8"
    refute projected.request.document["message"] =~ "acme/widget/pull/14"
    assert Repo.get!(IssueRequest, historical.id).outcome == other_outcome
  end

  test "a completed direct build is reused after the issue gains a progress comment",
       %{access: access, issue: issue} do
    page = IssueWorkflows.view(access, issue)
    {:ok, %{request: first}} = IssueWorkflows.start(access, issue, :build_issue, page.expected)

    outcome = %{
      "status" => "published",
      "terminal" => true,
      "url" => "https://github.com/acme/widget/pull/9"
    }

    Repo.update!(IssueRequest.Changeset.finish(first, outcome, Repo.now!()))

    newer = %{issue | "updated_at" => "2026-11-19T20:00:00Z"}

    assert {:ok, %{status: :duplicate, request: same}} =
             IssueWorkflows.start(
               access,
               newer,
               :build_issue,
               IssueWorkflows.view(access, newer).expected
             )

    assert same.id == first.id

    # Later triage became the current request and the action page offered Build again,
    # although the approved issue and its published pull request were unchanged.
    assert {:ok, %{request: triage}} =
             IssueWorkflows.start(
               access,
               newer,
               :triage_issue,
               IssueWorkflows.view(access, newer).expected
             )

    Repo.update!(
      IssueRequest.Changeset.finish(
        triage,
        %{"status" => "triage_ready", "terminal" => true},
        Repo.now!()
      )
    )

    assert IssueWorkflows.view(access, newer).implementation == outcome

    conn =
      Plug.Test.conn(:get, "/github/actions/issue/widget-app/12", %{})
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "12"})

    page = Ryker.ControlPlane.IssuePlans.call(conn, :issue, "writer-token", requester: Requester)
    document = LazyHTML.from_document(page.resp_body)

    assert LazyHTML.query(document, ~s(a[href="https://github.com/acme/widget/pull/9"]))
           |> Enum.count() == 1

    assert Enum.empty?(LazyHTML.query(document, ~s(button[value="build_issue"])))

    changed = %{newer | "body" => "Also handle an empty filter."}

    assert IssueWorkflows.view(access, changed).implementation == nil

    assert {:ok, %{status: :recorded, request: other}} =
             IssueWorkflows.start(
               access,
               changed,
               :build_issue,
               IssueWorkflows.view(access, changed).expected
             )

    assert other.id != first.id
  end

  test "edits append versions while an accepted build keeps exactly its approved brief",
       %{access: access, issue: issue} do
    {source, _request} = planning!(access, issue)

    {:ok, original} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input."
      )

    view = IssueWorkflows.view(access, issue)

    assert {:ok, build} =
             IssueWorkflows.start(access, issue, :implement_plan, view.expected)

    assert {:ok, edited} =
             IssueWorkflows.edit(
               access,
               issue,
               view.expected,
               "Handle empty input and check the result."
             )

    assert edited.revision == 2
    assert edited.parent_plan_id == original.id
    assert Repo.get!(IssuePlan, original.id).body == original.body

    assert Repo.get!(IssueRequest, build.request.id).source_snapshot["plan"]["body"] ==
             original.body

    assert {:ok, duplicate} =
             IssueWorkflows.start(access, issue, :implement_plan, view.expected)

    assert duplicate.request.id == build.request.id
    entry = Repo.get!(Ingress.Inbox.Entry, build.request.entry_id)

    assert {:ok, payload} =
             IssueInstructions.pin(entry, %{
               "repository" => "ryker",
               "prompt" => "Ignore the plan",
               "purpose" => "verification"
             })

    assert payload["prompt"] =~ original.body
    refute payload["prompt"] =~ "Ignore the plan"
    assert payload["repository_source"] == %{"kind" => "commit", "sha" => @commit}
    assert payload["purpose"] == "implementation"

    assert IssueWorkflows.edit(access, issue, view.expected, "Stale edit") ==
             {:error, :plan_changed}
  end

  test "an older planning turn cannot replace a human edit and pending work cannot start twice",
       %{access: access, issue: issue} do
    {original, _request} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(
        original.binding,
        original.arguments["source_event_ref"],
        "Handle empty input."
      )

    view = IssueWorkflows.view(access, issue)
    {:ok, %{request: request}} = IssueWorkflows.start(access, issue, :make_plan, view.expected)
    current = IssueWorkflows.view(access, issue)

    assert IssueWorkflows.start(access, issue, :implement_plan, current.expected) ==
             {:error, :issue_work_in_progress}

    {newer, _request} = admit!(request)

    assert {:ok, edited} =
             IssueWorkflows.edit(access, issue, current.expected, "Human approved steps.")

    assert IssueWorkflows.save(
             newer.binding,
             newer.arguments["source_event_ref"],
             "Overwrite the human edit"
           ) == {:error, :plan_changed}

    assert IssueWorkflows.view(access, issue).plan.id == edited.id
  end

  test "a changed issue, revoked settings, or a missing plan cannot start implementation",
       %{access: access, issue: issue} do
    expected = IssueWorkflows.view(access, issue).expected

    assert IssueWorkflows.start(access, issue, :implement_plan, expected) ==
             {:error, :plan_required}

    changed = Map.put(issue, "body", "New request")

    assert IssueWorkflows.start(access, changed, :build_issue, expected) ==
             {:error, :plan_changed}

    settings = Settings.fetch!()

    {:ok, _saved} =
      Settings.save_github(%{enabled: false}, settings.installation.revision, @actor)

    assert IssueWorkflows.start(access, issue, :build_issue, expected) ==
             {:error, :repository_access_changed}

    assert Repo.aggregate(Ingress.Inbox.Entry, :count) == 0
  end

  test "a lost comment response and later plan update keep one GitHub comment", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{marker: nil, body: nil, creates: 0, updates: 0, lose_response: true}
      end)

    options = %{
      base_url: "https://ryker.example",
      bindings: %{
        "widget-app" => %{
          api: Ryker.Fixtures.GitHubComments,
          client: agent,
          repository_full_name: "acme/widget",
          repository_id: 99
        }
      }
    }

    assert GitHubActions.IssueMessageWorker.run_once(options) == {:ok, :deferred}
    workflow = Repo.one!(IssueWorkflow)
    assert workflow.external_receipt == nil
    Repo.update!(Ecto.Changeset.change(workflow, next_attempt_at: DateTime.add(Repo.now!(), -1)))
    assert GitHubActions.IssueMessageWorker.run_once(options) == {:ok, :updated}
    state = Agent.get(agent, & &1)
    assert state.creates == 1
    assert state.updates == 1
    assert state.body =~ "Reading the issue and relevant code"
    assert state.body =~ "/github/actions/issue/widget-app/12"

    {:ok, _plan} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input."
      )

    assert GitHubActions.IssueMessageWorker.run_once(options) == {:ok, :updated}
    state = Agent.get(agent, & &1)
    assert state.creates == 1
    assert state.updates == 2
    assert state.body =~ "Plan · version 1"
    assert state.body =~ "Handle empty input."
    assert state.body =~ "Implement plan"
    assert Repo.one!(IssueWorkflow).next_attempt_at == nil
  end

  test "an in-flight comment cannot acknowledge a newer plan as delivered", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)
    {:ok, claimed} = GitHubActions.IssueMessages.claim_next(["widget-app"])
    {:ok, projected} = GitHubActions.IssueMessages.request(claimed, "https://ryker.example")

    {:ok, _plan} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input."
      )

    request = projected.request

    {:ok, receipt} =
      Ryker.Work.DeliveryReceipt.new(
        request.ref,
        "github",
        request.conversation_ref,
        request.thread_ref,
        "github:issue_comment:901"
      )

    assert {:ok, saved} = GitHubActions.IssueMessages.mark(projected, receipt)
    refute is_nil(saved.next_attempt_at)
    assert saved.revision == 1
  end

  test "a large planning input still refuses native mutations and proposals", %{access: access} do
    {:ok, %{entry: entry}} =
      GitHubActions.Requests.record(
        access,
        12,
        "make_plan",
        "Make a plan. " <> String.duplicate("Report details. ", 1_000),
        %{"request_key" => String.duplicate("c", 64)}
      )

    source = Corrections.from_entry!(entry)
    [input] = Records.TaskInstruction.current_inputs(source.binding)
    assert byte_size(input["content"]["content"]["request"]) > 12_288
    assert IssueInstructions.read_only?(source.binding)

    for name <- ~w(rerun_github_ci cancel_github_ci close_github_pull_request) do
      assert GitHub.CapabilityTools.call(name, %{}, source.binding, %{}) ==
               {:error, "planning_is_read_only"}
    end

    assert Ryker.StateTools.TaskTools.request_task(%{"start" => false}, source.binding) ==
             {:error, :planning_is_read_only}
  end

  test "an approved plan cannot start a different saved proposal", %{access: access, issue: issue} do
    {planning, _request} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(
        planning.binding,
        planning.arguments["source_event_ref"],
        "Handle empty input."
      )

    {:ok, %{request: request}} =
      IssueWorkflows.start(
        access,
        issue,
        :implement_plan,
        IssueWorkflows.view(access, issue).expected
      )

    {source, _request} = admit!(request)

    payload =
      Ryker.Fixtures.TaskOffer.payload(%{
        "instruction_ref" => source.arguments["source_event_ref"],
        "prompt" => "Replace the whole application",
        "repository_source" => %{"kind" => "commit", "sha" => @commit}
      })

    authorize = fn _, _ ->
      {:ok,
       %{name: "ryker-contributor", digest: String.duplicate("b", 64), repository_ref: "ryker"}}
    end

    assert {:ok, offered} =
             Ryker.StateTools.TaskTools.request_task(
               Map.put(payload, "start", false),
               source.binding
             )

    sessions = Repo.aggregate(Ryker.Work.Session, :count)

    assert Records.TaskOffers.start(source.binding, payload, authorize, offered["record_ref"]) ==
             {:error, :task_instruction_not_authorized}

    assert Records.TaskOffers.start(source.binding, payload, authorize, nil) ==
             {:error, :state_record_operation_conflict}

    assert Repo.get_by!(Records.Record, ref: offered["record_ref"]).confirmed_episode_id == nil
    assert Repo.aggregate(Ryker.Work.Session, :count) == sessions
  end

  test "an approved plan starts one actual task and progress follows its linked episode", %{
    access: access,
    issue: issue
  } do
    {planning, _request} = planning!(access, issue)

    {:ok, plan} =
      IssueWorkflows.save(
        planning.binding,
        planning.arguments["source_event_ref"],
        "Handle empty input."
      )

    view = IssueWorkflows.view(access, issue)

    {:ok, %{request: request}} =
      IssueWorkflows.start(access, issue, :implement_plan, view.expected)

    {source, _request} = admit!(request)

    payload =
      Ryker.Fixtures.TaskOffer.payload(%{
        "instruction_ref" => source.arguments["source_event_ref"],
        "prompt" => "Replace the approved plan"
      })

    authorize = fn _requester, _repository ->
      {:ok,
       %{name: "ryker-contributor", digest: String.duplicate("b", 64), repository_ref: "ryker"}}
    end

    assert {:ok, started} = Records.TaskOffers.start(source.binding, payload, authorize, nil)
    assert {:ok, repeated} = Records.TaskOffers.start(source.binding, payload, authorize, nil)
    assert repeated["record_ref"] == started["record_ref"]
    record = Repo.get_by!(Records.Record, ref: started["record_ref"])
    session = Repo.get_by!(Ryker.Work.Session, episode_id: record.confirmed_episode_id)

    assert session.workspace_task["prompt"] ==
             IssueInstructions.prompt(:implement_plan, request.source_snapshot)

    assert session.repository_source == %{"kind" => "commit", "sha" => plan.source_commit}
    assert GitHubActions.IssueProgress.read(request) == %{"status" => "building"}
    episode = Repo.get!(Ryker.Episodes.Episode, record.confirmed_episode_id)

    assert {:ok, _cancelled} =
             Ryker.Episodes.apply(
               Ryker.Fixtures.Episodes.cancel_episode(%{
                 episode_key: episode.key,
                 expected_owner: %{kind: episode.owner_kind, ref: episode.owner_ref},
                 occurred_at: Repo.now!()
               })
             )

    assert GitHubActions.IssueProgress.read(request) == %{
             "status" => "cancelled",
             "terminal" => true
           }

    {:ok, claimed} = GitHubActions.IssueMessages.claim_next(["widget-app"])
    {:ok, _projected} = GitHubActions.IssueMessages.request(claimed, "https://ryker.example")

    assert Repo.get!(IssueRequest, request.id).outcome == %{
             "status" => "cancelled",
             "terminal" => true
           }
  end

  test "history stays accessible beyond ten plan versions", %{access: access, issue: issue} do
    {source, _request} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input."
      )

    for version <- 2..12 do
      view = IssueWorkflows.view(access, issue)

      assert {:ok, plan} =
               IssueWorkflows.edit(access, issue, view.expected, "Human revision #{version}.")

      assert plan.revision == version
    end

    newest = IssueWorkflows.view(access, issue)
    assert Enum.map(newest.plans, & &1.revision) == Enum.to_list(12..3//-1)
    older = IssueWorkflows.view(access, issue, newest.history_before)
    assert Enum.map(older.plans, & &1.revision) == [2, 1]
    assert older.plan.revision == 12
  end

  test "a current issue conversation can offer controls without authorizing a build", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)
    configured = %{repository_id: 99, client: %{http: access.http, requester: Requester}}
    target = %{subject_kind: "issue", number: 12}

    assert GitHubActions.offer_issue_controls(source.binding, target, configured) ==
             {:error, :issue_actions_unavailable}

    {:ok, _secret} =
      Ryker.Credentials.put(:github_oauth_secret, "primary", "oauth-secret-example", @actor)

    {:ok, _settings} =
      Settings.save_github(
        %{oauth_client_id: "Iv1.example"},
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, %{"status" => "controls_queued", "url" => url}} =
             GitHubActions.offer_issue_controls(source.binding, target, configured)

    assert url =~ "/github/actions/issue/widget-app/12"
    assert Repo.aggregate(IssueRequest, :count) == 1
    assert Repo.aggregate(Records.Record, :count) == 0

    assert GitHubActions.offer_issue_controls(
             source.binding,
             %{subject_kind: "pull", number: 12},
             configured
           ) == {:error, :issue_required}

    assert GitHubActions.offer_issue_controls(source.binding, target, %{
             configured
             | repository_id: 100
           }) == {:error, :issue_actions_unavailable}

    Config.put_override(:control_public_url, nil)

    assert GitHubActions.offer_issue_controls(source.binding, target, configured) ==
             {:error, :issue_actions_unavailable}
  end

  test "quick actions are opt in and never admit work", %{access: access, issue: issue} do
    {:ok, _secret} =
      Ryker.Credentials.put(:github_oauth_secret, "primary", "oauth-secret-example", @actor)

    settings = Settings.fetch!()

    {:ok, _saved} =
      Settings.save_github(
        %{oauth_client_id: "Iv1.example"},
        settings.installation.revision,
        @actor
      )

    runtime = Config.get_env(:github).server.bindings[access.binding.name]

    payload = %{
      "action" => "opened",
      "installation" => %{"id" => 41},
      "repository" => %{"id" => 99, "full_name" => "acme/widget"},
      "issue" => Map.put(issue, "state", "open")
    }

    assert GitHubActions.offer_issue_actions(runtime, "issues", payload) == :ok
    assert Repo.aggregate(IssueWorkflow, :count) == 0

    {:ok, _saved} =
      Settings.put_repository(
        %{ref: "ryker", github_issue_actions: true},
        Settings.fetch!().installation.revision,
        @actor
      )

    assert GitHubActions.offer_issue_actions(runtime, "issues", payload) == :ok
    assert GitHubActions.offer_issue_actions(runtime, "issues", payload) == :ok
    assert Repo.aggregate(IssueWorkflow, :count) == 1
    assert Repo.aggregate(Ingress.Inbox.Entry, :count) == 0
  end

  test "the saved plan page displays its exact version and escapes editable text", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)
    body = "Handle empty input.\n</textarea><script>alert(1)</script>"
    {:ok, _plan} = IssueWorkflows.save(source.binding, source.arguments["source_event_ref"], body)
    secret = String.duplicate("s", 64)
    session = %{"token" => "writer-token", "expires_at" => System.system_time(:second) + 3600}

    signed =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, secret)
      |> Plug.Conn.put_resp_cookie("_ryker_github_user", session, encrypt: true)
      |> Plug.Conn.send_resp(200, "")

    conn =
      Plug.Test.conn(:get, "/github/actions/issue/widget-app/12", %{})
      |> Map.put(:secret_key_base, secret)
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "12"})
      |> Plug.Test.recycle_cookies(signed)

    page = Ryker.ControlPlane.GitHubActions.call(conn, {:issue, requester: Requester})
    assert page.status == 200
    assert page.resp_body =~ "Implement plan · version 1"
    assert page.resp_body =~ "data-saved-plan"
    assert page.resp_body =~ "data-workflow-id"
    assert page.resp_body =~ "data-plan-id"
    assert page.resp_body =~ "Refresh status"
    assert page.resp_body =~ "data-plan-draft-recovery"
    refute page.resp_body =~ "<script>alert"
    assert page.resp_body =~ "Plan ready for your review"
  end

  test "a stale plan POST shows the saved version and keeps submitted edits separate", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(source.binding, source.arguments["source_event_ref"], "Original plan")

    view = IssueWorkflows.view(access, issue)
    secret = String.duplicate("s", 64)

    snapshot =
      Phoenix.Token.sign(secret, "github-issue-plan", %{
        binding: "widget-app",
        number: 12,
        expected: view.expected
      })

    {:ok, _newer} = IssueWorkflows.edit(access, issue, view.expected, "New saved plan")
    params = %{"snapshot" => snapshot, "body" => "Earlier unsaved edits"}

    conn =
      Plug.Test.conn(:post, "/github/actions/issue/widget-app/12/edit", params)
      |> Map.put(:secret_key_base, secret)
      |> Map.put(:params, params)
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "12"})

    page =
      Ryker.ControlPlane.IssuePlans.call(conn, :edit_issue_plan, "writer-token",
        requester: Requester
      )

    assert page.status == 409
    html = LazyHTML.from_document(page.resp_body)
    assert LazyHTML.query(html, "textarea") |> LazyHTML.text() == "New saved plan"

    assert LazyHTML.query(html, "[data-server-draft]") |> LazyHTML.attribute("data-server-draft") ==
             ["Earlier unsaved edits"]

    assert page.resp_body =~ "Plan · version 2"
  end

  test "automatic triage is a system input, requires opt-in, and shares manual deduplication", %{
    access: access,
    issue: issue
  } do
    assert IssueWorkflows.auto_triage(access, issue, grant(access, issue)) ==
             {:error, :issue_triage_disabled}

    enable_triage!(false)
    {:ok, configured} = GitHub.IssueIndex.configuration("widget-app")
    assert {:ok, first} = IssueWorkflows.auto_triage(configured, issue, grant(access, issue))
    entry = Repo.get!(Ingress.Inbox.Entry, first.request.entry_id)
    assert entry.actor_ref =~ "system:"
    refute entry.actor_ref =~ "user:"
    assert first.request.actor_id == 0
    assert {:ok, repeated} = IssueWorkflows.auto_triage(configured, issue, grant(access, issue))
    assert repeated.request.id == first.request.id
    access = %{access | settings: Settings.fetch!()}

    assert {:ok, manual} =
             IssueWorkflows.start(
               access,
               issue,
               :triage_issue,
               IssueWorkflows.view(access, issue).expected
             )

    assert manual.request.id == first.request.id
    assert Repo.aggregate(IssueRequest, :count) == 1
    assert Repo.aggregate(Records.Record, :count) == 0
  end

  # Losing Write after enqueue used to leave a payable system instruction behind.
  for change <- [:permission_revoked, :report_edited] do
    @change change
    test "deferred automatic triage expires on #{@change} and a writer can authorize a new request",
         %{access: access, issue: issue} do
      enable_triage!(false)
      {:ok, configured} = GitHub.IssueIndex.configuration("widget-app")

      {:ok, %{request: request}} =
        IssueWorkflows.auto_triage(configured, issue, grant(access, issue))

      {source, _request} = admit!(request)
      entry = source.entry
      runtime = Config.get_env(:github)
      binding = runtime.server.bindings["widget-app"]
      check = fn _, _ -> Process.get(:writer_check, :ok) end
      placement = %{binding: binding, check: check, read_client: triage_client().client}

      Config.put_override(
        :github,
        Map.put(runtime, :issue_triage, %{bindings: %{"widget-app" => placement}})
      )

      assert GitHub.RequestAuthority.check_entry(entry) == :ok
      assert GitHub.RequestAuthority.check_turn(source.binding) == :ok
      Process.put(:writer_check, {:error, {:github_repository_access_unavailable, :timeout}})

      assert GitHub.RequestAuthority.check_turn(source.binding) ==
               {:error, {:github_repository_access_unavailable, :timeout}}

      assert Repo.get!(IssueRequest, request.id).outcome == nil

      Process.put(
        :writer_check,
        if(@change == :permission_revoked, do: {:error, :actor_not_authorized}, else: :ok)
      )

      Process.put(:triage_issue_changed, @change == :report_edited)

      assert GitHub.RequestAuthority.check_turn(source.binding) ==
               {:error, :triage_request_expired}

      assert Repo.get!(IssueRequest, request.id).outcome["status"] == "authorization_expired"

      Process.delete(:writer_check)
      Process.delete(:triage_issue_changed)
      assert GitHub.RequestAuthority.check_entry(entry) == {:error, :triage_request_expired}

      assert {:ok, %{status: :recorded, request: manual}} =
               IssueWorkflows.start(
                 access,
                 issue,
                 :triage_issue,
                 IssueWorkflows.view(access, issue).expected
               )

      assert manual.actor_id == access.actor["id"]
    end
  end

  test "triage can save an editable plan but cannot authorize a task or apply labels without opt-in",
       %{access: access, issue: issue} do
    {source, request} = triaging!(access, issue)
    reference = source.arguments["source_event_ref"]

    assert Records.TaskInstruction.fetch(source.binding, reference, nil, "ryker") ==
             {:error, :planning_is_read_only}

    assert Ryker.StateTools.TaskTools.request_task(%{}, source.binding) ==
             {:error, :planning_is_read_only}

    assert GitHub.CapabilityTools.call(
             "close_github_pull_request",
             %{"number" => 12},
             source.binding,
             %{}
           ) == {:error, "planning_is_read_only"}

    client = triage_client()

    assert {:ok, prepared} =
             GitHubActions.IssueTriage.call(
               "prepare_github_issue_triage",
               %{"instruction_ref" => reference},
               source.binding,
               client
             )

    assert prepared["labels"]["names"] == ["bug"]
    assert prepared["related"]["coverage"] == "partial"

    assert {:ok, related} =
             GitHubActions.IssueTriage.call(
               "read_related_github_issue",
               %{"instruction_ref" => reference, "number" => 13},
               source.binding,
               client
             )

    assert related["issue"]["state"] == "closed"
    result = triage_result(reference)

    assert {:ok, outcome} =
             GitHubActions.IssueTriage.call(
               "complete_github_issue_triage",
               result,
               source.binding,
               client
             )

    assert outcome["status"] == "triage_ready"
    assert outcome["triage"]["labels_status"] =~ "Suggested only"
    refute_received {:triage_labels, _body}
    plan = Repo.get!(IssuePlan, outcome["plan_id"])
    assert plan.body == result["plan"]
    assert plan.source_commit == @commit
    assert Repo.get!(IssueRequest, request.id).outcome == outcome

    assert {:ok, ^outcome} =
             GitHubActions.IssueTriage.call(
               "complete_github_issue_triage",
               result,
               source.binding,
               client
             )

    assert Repo.aggregate(IssuePlan, :count) == 1
    assert Repo.aggregate(Records.Record, :count) == 0
  end

  test "missing label permission preserves the triage result and never replaces human labels", %{
    access: access,
    issue: issue
  } do
    enable_triage!(true)
    access = %{access | settings: Settings.fetch!()}
    {source, _request} = triaging!(access, issue)
    result = triage_result(source.arguments["source_event_ref"]) |> Map.put("plan", nil)

    assert GitHubActions.IssueTriage.call(
             "complete_github_issue_triage",
             result,
             source.binding,
             triage_client()
           ) == {:error, :related_issue_not_read}

    read_related!(source)
    Process.put(:triage_labels_denied, true)

    assert {:ok, outcome} =
             GitHubActions.IssueTriage.call(
               "complete_github_issue_triage",
               result,
               source.binding,
               triage_client()
             )

    assert_received {:triage_labels, %{"labels" => ["bug"]}}
    assert outcome["triage"]["labels_status"] =~ "Could not confirm"
    assert outcome["plan_id"] == nil
    assert Repo.aggregate(IssuePlan, :count) == 0
  end

  test "an edited issue or invented label cannot save a stale triage result", %{
    access: access,
    issue: issue
  } do
    {source, request} = triaging!(access, issue)
    result = triage_result(source.arguments["source_event_ref"])
    Process.put(:triage_issue_changed, true)

    assert GitHubActions.IssueTriage.call(
             "complete_github_issue_triage",
             result,
             source.binding,
             triage_client()
           ) == {:error, :issue_changed}

    Process.delete(:triage_issue_changed)
    read_related!(source)

    assert GitHubActions.IssueTriage.call(
             "complete_github_issue_triage",
             %{result | "labels" => ["invented"]},
             source.binding,
             triage_client()
           ) == {:error, :unknown_triage_label}

    assert Repo.get!(IssueRequest, request.id).outcome == nil
    assert Repo.aggregate(IssuePlan, :count) == 0
    refute_received {:triage_labels, _body}
  end

  test "automatic triage loses authority when its repository is disabled", %{
    access: access,
    issue: issue
  } do
    enable_triage!(false)
    {:ok, configured} = GitHub.IssueIndex.configuration("widget-app")

    {:ok, %{request: request}} =
      IssueWorkflows.auto_triage(configured, issue, grant(access, issue))

    {source, _request} = admit!(request)
    settings = Settings.fetch!()

    {:ok, _saved} =
      Settings.put_repository(
        %{ref: access.repository.ref, github_issue_triage: false},
        settings.installation.revision,
        @actor
      )

    assert GitHubActions.IssueTriage.call(
             "complete_github_issue_triage",
             triage_result(source.arguments["source_event_ref"]),
             source.binding,
             triage_client()
           ) == {:error, :triage_request_required}

    assert Repo.get!(IssueRequest, request.id).outcome == nil
  end

  test "a bot comment timestamp change does not invalidate the approved report", %{
    access: access,
    issue: issue
  } do
    {source, _request} = planning!(access, issue)

    {:ok, _plan} =
      IssueWorkflows.save(
        source.binding,
        source.arguments["source_event_ref"],
        "Handle empty input. Test empty input."
      )

    current = %{issue | "updated_at" => "2026-11-18T12:00:00Z"}
    expected = IssueWorkflows.view(access, current).expected
    assert {:ok, _accepted} = IssueWorkflows.start(access, current, :implement_plan, expected)
  end

  test "enabled label application adds only the approved existing labels", %{
    access: access,
    issue: issue
  } do
    enable_triage!(true)
    {source, _request} = triaging!(%{access | settings: Settings.fetch!()}, issue)
    read_related!(source)
    read_related!(source)
    result = triage_result(source.arguments["source_event_ref"])

    assert {:ok, outcome} =
             GitHubActions.IssueTriage.call(
               "complete_github_issue_triage",
               result,
               source.binding,
               triage_client()
             )

    assert_received {:triage_labels, %{"labels" => ["bug"]}}
    assert outcome["triage"]["labels_status"] == "Applied. Existing labels were kept."
    assert Repo.aggregate(GitHubActions.IssueTriageRead, :count) == 1
    assert is_binary(hd(outcome["triage"]["related"])["observed"]["read_id"])
  end

  defp read_related!(source) do
    assert {:ok, _read} =
             GitHubActions.IssueTriage.call(
               "read_related_github_issue",
               %{"instruction_ref" => source.arguments["source_event_ref"], "number" => 13},
               source.binding,
               triage_client()
             )
  end

  test "the triage page shows evidence and saved-plan controls with escaped report text", %{
    access: access,
    issue: issue
  } do
    {source, _request} = triaging!(access, issue)
    read_related!(source)
    result = triage_result(source.arguments["source_event_ref"])

    result = %{
      result
      | "summary" => result["summary"] <> " Literal text: <script>alert(1)</script>"
    }

    {:ok, _outcome} =
      GitHubActions.IssueTriage.call(
        "complete_github_issue_triage",
        result,
        source.binding,
        triage_client()
      )

    conn =
      Plug.Test.conn(:get, "/github/actions/issue/widget-app/12", %{})
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "12"})

    page = Ryker.ControlPlane.IssuePlans.call(conn, :issue, "writer-token", requester: Requester)
    assert page.status == 200
    assert page.resp_body =~ "Issue triage"
    assert page.resp_body =~ "possible duplicate"
    assert page.resp_body =~ "Implement plan · version 1"
    assert page.resp_body =~ "Triage this issue"
    assert page.resp_body =~ "&lt;script&gt;"
    refute page.resp_body =~ "<script>alert"
  end

  defp grant(access, issue) do
    {:ok, grant} =
      GitHub.IssueTriageGrant.new(%{
        "sender" => access.actor,
        "issue" => Map.put(issue, "user", access.actor)
      })

    grant
  end

  defp enable_triage!(labels) do
    Settings.put_repository(
      %{ref: "ryker", github_issue_triage: true, github_triage_labels: labels},
      Settings.fetch!().installation.revision,
      @actor
    )
  end

  defp triaging!(access, issue) do
    {:ok, %{request: request}} =
      IssueWorkflows.start(
        access,
        issue,
        :triage_issue,
        IssueWorkflows.view(access, issue).expected
      )

    admit!(request)
  end

  defp triage_client do
    {:ok, client} =
      GitHub.Client.new(%{http: %{}, requester: Ryker.Fixtures.GitHubActions.TriageRequester})

    %{
      client: client,
      triage_client: client,
      repository_id: 99,
      repository_full_name: "acme/widget"
    }
  end

  defp triage_result(reference),
    do: %{
      "instruction_ref" => reference,
      "summary" =>
        "The empty-input branch needs to return an empty result. The related report describes the same branch.",
      "plan" => "Return an empty result for empty input. Test empty and populated input.",
      "labels" => ["bug"],
      "related" => [
        %{
          "number" => 13,
          "relation" => "possible_duplicate",
          "evidence" => "Both reports concern an empty input producing no rows."
        }
      ]
    }

  # Two issue reports each received a useful triage comment and then a second
  # acknowledgement that merely linked to the comment Ryker had just saved.
  test "the saved issue result accounts for exactly its own reply", %{
    access: access,
    issue: issue
  } do
    enable_triage!(false)
    access = %{access | settings: Settings.fetch!()}
    {source, _request} = triaging!(access, issue)
    binding = source.binding
    reference = source.arguments["source_event_ref"]
    assert accepted_delivery(binding) == :reply

    assert {:ok, _} =
             IssueWorkflows.save_triage(
               binding,
               reference,
               recorded_triage()["triage"] |> Map.delete("instruction_ref")
             )

    assert accepted_delivery(binding) == :none

    turn =
      update_in(binding.turn.submission["context"]["inputs"]["items"], fn [item] ->
        [item, %{"current" => true, "actor_ref" => "github:user:7"}]
      end)

    assert accepted_delivery(turn) == :reply
  end

  defp accepted_delivery(binding) do
    candidate = recorded_triage()["candidate"] |> Jason.encode!()

    context = Ryker.Work.ValidationContext.build(binding.episode, binding.turn)
    assert {:accept, accepted} = Ryker.Work.Validator.validate(candidate, context, Repo.now!())
    accepted.result.delivery
  end

  defp recorded_triage do
    "testdata/github/issue-triage-duplicate-acknowledgement.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp planning!(access, issue) do
    expected = IssueWorkflows.view(access, issue).expected

    {:ok, %{request: request}} =
      IssueWorkflows.start(access, issue, :make_plan, expected)

    admit!(request)
  end

  defp admit!(request) do
    entry = Repo.get!(Ingress.Inbox.Entry, request.entry_id)

    source = Corrections.from_entry!(entry)

    session =
      source.binding.session
      |> Ecto.Changeset.change(
        repository_ref: "ryker",
        worker_job_document: %{"source" => %{"binding" => %{"selected_commit" => @commit}}}
      )
      |> Repo.update!()

    {put_in(source.binding.session, session), request}
  end
end
