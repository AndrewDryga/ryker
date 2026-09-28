defmodule Ryker.RepositoryKnowledge.LaneTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.Projection
  alias Ryker.GitHub.Onboarding
  alias Ryker.{IntegrationSetup, RepositoryKnowledge, Settings}
  alias Ryker.RepositoryKnowledge.{Dispatcher, Document, Entry, Prompt, Run}
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.TestSupport.{FakeCoopAPI, FakeGitHubRepository}
  alias Ryker.Work.Session

  @actor "control-plane:local"
  @fixtures "test/ryker/repository_knowledge/fixtures"
  # The commit PR 84 read, and later heads of the same default branch.
  @head "783fc4801d274d5ee05feb3fbc5c70981b1bbd7a"
  @merged "1111111111111111111111111111111111111111"
  @pushed "2222222222222222222222222222222222222222"
  @later "3333333333333333333333333333333333333333"

  # The fleet answers every Coop mutation with an operation still running
  # and the worker finishes it a moment later (the fake's asynchronous mode);
  # a fake that answered at once would prove nothing about waiting.
  defmodule API do
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake

    defdelegate prepare_create_session(client, key, policy, ref, source), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, session_id, turn_id), to: Fake
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: Fake
    defdelegate operation_by_key(client, key), to: Fake

    def submit_frozen_turn(client, session_id, key, revision, submission, nil, []) do
      Agent.update(
        client,
        &Map.update(&1, :submissions, [submission], fn all -> all ++ [submission] end)
      )

      Fake.submit_turn(
        client,
        session_id,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def validate_frozen_candidate(client, session_id, turn_id, key, _attempt, sha256, verdict),
      do: Fake.validate_candidate(client, session_id, turn_id, key, sha256, verdict)
  end

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{
          ref: "emisar",
          display_name: "AndrewDryga/emisar",
          github_repository: "AndrewDryga/emisar",
          base_branch: "main"
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_github_binding(
        %{
          name: "emisar",
          repository_ref: "emisar",
          installation_id: 10,
          repository_id: 20,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        @actor
      )

    :ok
  end

  # Andrew, 2026-09-27: "those are pretty weak summaries for the repo, should
  # we do something better than that?!" A repository just added gets a
  # document a model wrote from reading it, checked against it, in one draft
  # pull request, and Work reads that proposal until it is merged.
  test "a repository just set up gets a model-written RYKER.md, proposed in one pull request" do
    github!()
    coop = coop!([answer_json()], turn_wait_polls: 2)

    assert {:ok, :ready} = Onboarding.run("emisar", api: FakeGitHubRepository)
    assert repository().onboarding_state == :ready
    assert repository().source_commit == @head

    results = drain(settings(coop))
    assert {:ok, :written} in results

    # The model read exactly the default branch head, read-only, alone.
    state = FakeCoopAPI.state(coop)
    assert state.create_sources == [%{"kind" => "commit", "sha" => @head}]
    assert [submission] = state.submissions
    assert submission["contract_version"] == Prompt.contract_version()
    assert submission["output_schema"] == Prompt.output_schema()
    assert submission["prompt"] =~ ~s("name":"AndrewDryga/emisar")
    assert submission["prompt"] =~ ~s("portal/mix.exs")

    # One pull request holds the checked document, which pins no link.
    assert %{number: 84, title: "Add Ryker repository knowledge", document: document, body: body} =
             FakeGitHubRepository.state().open

    assert String.starts_with?(document, "# RYKER.md\n\nWritten by Ryker from `783fc48` on ")
    assert document =~ "[portal/](portal/) — Elixir/Phoenix control plane"
    assert document =~ "- `./run help` — Lists every contributor command."
    refute document =~ "://"
    refute document =~ @head
    assert Document.origin(document) == :model
    assert body =~ "Why now: The repository has no RYKER.md yet."
    assert body =~ "Ryker never merges it"

    entry = RepositoryKnowledge.entry("emisar")
    assert entry.phase == :idle
    assert entry.document == document
    assert {entry.document_by, entry.document_commit} == {:model, @head}

    assert {entry.publication, entry.pull_request_number, entry.pull_request_state} ==
             {:opened, 84, :open}

    assert entry.error == nil
    assert DateTime.diff(entry.next_check_at, Repo.now!()) in 86_000..86_400

    # Work is briefed with the proposal.
    assert repository().knowledge_content == document
    assert repository().knowledge_status == :proposed
    assert repository().knowledge_source_commit == @head

    assert repository().knowledge_pull_request_url ==
             "https://github.com/AndrewDryga/emisar/pull/84"

    # The turn stopped with proof, so cleanup may close its session, and it
    # is metered under the repository's GitHub conversation.
    [run] = Repo.all(from(run in Run, where: run.repository_ref == "emisar"))
    assert {run.status, run.dropped_count} == {:applied, 0}
    assert %DateTime{} = run.remote_stopped_at

    session = Repo.get_by!(Session, execution_kind: :knowledge, knowledge_run_id: run.id)
    assert session.repository_ref == "emisar"
    assert session.repository_source == %{"kind" => "commit", "sha" => @head}

    assert Repo.exists?(
             from([session: eligible] in RetentionCustody.eligible_query(DateTime.utc_now()),
               where: eligible.id == ^session.id
             )
           )

    assert Repo.exists?(
             from(execution in Execution,
               where:
                 execution.kind == "knowledge" and execution.source_id == ^run.id and
                   execution.repository_ref == "emisar" and
                   execution.conversation_ref == "github:emisar:repository:20"
             )
           )

    # Written once: nothing is due until tomorrow's check.
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  # Andrew, 2026-09-27: "also when those are updated?" Once a day each
  # repository is checked; a push that touches no file a teammate reads to
  # learn it costs no model turn, and Work follows what was merged.
  test "the daily check rewrites only when the default branch moved and a key file changed" do
    github!()
    changed = Map.put(answer(), "purpose", answer()["purpose"] <> " It is dual-licensed.")
    coop = coop!([answer_json(), Jason.encode!(changed), Jason.encode!(changed)])
    written!(coop)

    # PR 84 is merged; the merge commit changed only RYKER.md.
    FakeGitHubRepository.merge_open(@merged)
    FakeGitHubRepository.push(@head, @merged, ["RYKER.md", "portal/apps/emisar/lib/emisar.ex"])
    due!()

    # One step, the check, and no turn.
    assert drain(settings(coop)) == [{:ok, :step}, {:ok, :idle}]
    assert length(FakeCoopAPI.state(coop).submissions) == 1
    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.pull_request_state} == {:idle, :merged}

    # Work reads what was merged, as the default branch holds it.
    assert repository().knowledge_status == :accepted
    assert repository().knowledge_content == FakeGitHubRepository.state().document

    # A README change is worth a turn; the proposal opens a new pull request.
    FakeGitHubRepository.push(@head, @pushed, ["README.md", "runner/main.go"])
    due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 2

    assert %{number: 85, title: "Update Ryker repository knowledge", body: body} =
             FakeGitHubRepository.state().open

    assert body =~ "Why now: These files changed: README.md."
    assert RepositoryKnowledge.entry("emisar").reason == "These files changed: README.md."

    # While it is open, the next rewrite updates it: never a second one.
    FakeGitHubRepository.push(@pushed, @later, ["portal/mix.exs"])
    due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 3
    assert FakeGitHubRepository.state().pull_requests == %{84 => :merged, 85 => :open}
    assert FakeGitHubRepository.state().open.document =~ "Written by Ryker from `3333333` on "

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.publication, entry.pull_request_number} == {:updated, 85}
    assert repository().knowledge_status == :proposed
    assert repository().knowledge_pull_request_url =~ "/pull/85"
  end

  test "a week after the last write, any code change is enough" do
    github!()
    coop = coop!([answer_json(), answer_json()])
    written!(coop)
    FakeGitHubRepository.merge_open(@merged)

    # Code only, six days after the write: nothing.
    age!(6)
    FakeGitHubRepository.push(@head, @pushed, ["runner/main.go"])
    due!()
    drain(settings(coop))
    assert length(FakeCoopAPI.state(coop).submissions) == 1

    # Seven days: the same kind of change is read again.
    age!(7)
    due!()
    drain(settings(coop))
    assert length(FakeCoopAPI.state(coop).submissions) == 2

    assert RepositoryKnowledge.entry("emisar").reason ==
             "A week has passed since the last write, and code changed."
  end

  # A rewrite names a new commit and a new date every time. When the model
  # says what the default branch already says, a pull request would change
  # only that line: nothing is opened, and Work reads the merged file.
  test "a rewrite that says what the default branch says opens nothing" do
    github!()
    coop = coop!([answer_json(), answer_json()])
    written!(coop)
    FakeGitHubRepository.merge_open(@merged)
    FakeGitHubRepository.push(@head, @pushed, ["AGENTS.md"])
    due!()

    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 2
    assert FakeGitHubRepository.state().open == nil
    assert FakeGitHubRepository.state().pull_requests == %{84 => :merged}

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.publication, entry.document_commit} == {:unchanged, @pushed}
    assert repository().knowledge_status == :accepted
    assert repository().knowledge_content == FakeGitHubRepository.state().document
  end

  # The four repositories set up before this change hold the old file-list
  # summary on their default branches (PR 84 is emisar's). Their first check
  # has a model write them at once.
  test "a repository whose RYKER.md is the old file-list summary is written again at once" do
    old = File.read!(Path.join([@fixtures, "emisar", "old_scan_RYKER.md"]))
    github!(document: old)
    ready!()
    coop = coop!([answer_json()])

    drain(settings(coop))

    assert %{number: 84, title: "Update Ryker repository knowledge", body: body} =
             FakeGitHubRepository.state().open

    assert body =~ "Why now: RYKER.md is the file-list summary setup wrote before."
    assert RepositoryKnowledge.entry("emisar").document_by == :model
  end

  # A RYKER.md a person wrote is theirs: accepted as it is, and Work reads it.
  test "a RYKER.md a person wrote is kept and never rewritten by the daily check" do
    person = "# How we work\n\nRun `./run gate all` before pushing.\n"
    github!(document: person)
    ready!()
    coop = coop!([answer_json()])

    drain(settings(coop))

    assert FakeCoopAPI.state(coop).create_keys == []
    assert FakeGitHubRepository.state().open == nil
    assert repository().knowledge_content == person
    assert repository().knowledge_status == :accepted
  end

  # "Refresh knowledge" on the Repositories page: the same rewrite, at once,
  # whatever the rules say.
  test "refresh writes RYKER.md again at once, and says so while it is being written" do
    github!()
    coop = coop!([answer_json(), answer_json()])
    written!(coop)

    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)
    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.requested_by} == {:write, @actor}
    assert entry.reason == "Someone asked for it on the Repositories page."

    # Asked again while it is under way, it is the same write.
    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop))
    assert {:ok, :already_writing} = RepositoryKnowledge.refresh("emisar", @actor)

    drain(settings(coop))
    assert length(FakeCoopAPI.state(coop).submissions) == 2

    # PR 84 is still open: the same one is updated.
    assert FakeGitHubRepository.state().pull_requests == %{84 => :open}
    assert RepositoryKnowledge.entry("emisar").publication == :updated

    assert {:error, :repository_not_found} = RepositoryKnowledge.refresh("missing", @actor)
  end

  # Review of the knowledge lane, 2026-09-28: every reason GitHub gave was
  # read as one another try would meet again, so a 502 while a refresh
  # someone asked for read the repository gave the refresh up until the
  # next day's check, with nothing on the page to say it had been dropped.
  test "GitHub failing for a moment keeps a requested refresh, and tries it again shortly" do
    github!()
    coop = coop!([answer_json(), answer_json()])
    written!(coop)
    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)

    FakeGitHubRepository.update(
      &%{&1 | errors: %{repository: {:error, {:github_onboarding, :response}}}}
    )

    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop, retry_delay_seconds: 60))

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.requested_by, entry.error} == {:write, @actor, nil}
    assert DateTime.diff(entry.next_attempt_at, Repo.now!()) in 55..60

    FakeGitHubRepository.update(&%{&1 | errors: %{}})
    retry_due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 2
    assert RepositoryKnowledge.entry("emisar").publication == :updated
  end

  # The same review: a 5xx while the pull request was opened, with the
  # branch already written, left the document unproposed for a day.
  test "a proposal GitHub failed to open is tried again shortly, not tomorrow" do
    github!(errors: %{publish: {:error, {:github_onboarding, :pull_request}}})
    ready!()
    coop = coop!([answer_json()])

    drain(settings(coop, retry_delay_seconds: 60))

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.published_at, entry.error} == {:publish, nil, nil}
    assert DateTime.diff(entry.next_attempt_at, Repo.now!()) in 55..60

    FakeGitHubRepository.update(&%{&1 | errors: %{}})
    retry_due!()
    drain(settings(coop))

    assert %{number: 84} = FakeGitHubRepository.state().open
    assert RepositoryKnowledge.entry("emisar").publication == :opened
  end

  test "an archived repository is skipped with a sentence, and costs no model turn" do
    github!(archived: true)
    ready!()
    coop = coop!([answer_json()])

    drain(settings(coop))

    assert FakeCoopAPI.state(coop).create_keys == []
    refute Enum.any?(FakeGitHubRepository.calls(), &match?({:publish, _document}, &1))
    entry = RepositoryKnowledge.entry("emisar")
    assert entry.phase == :idle
    assert entry.error =~ "archived on GitHub"
    assert DateTime.diff(entry.next_check_at, Repo.now!()) in 86_000..86_400

    # Asking for it on the page meets the same refusal before any turn.
    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)
    drain(settings(coop))
    assert FakeCoopAPI.state(coop).create_keys == []
    assert RepositoryKnowledge.entry("emisar").error =~ "archived on GitHub"
  end

  test "a removed repository is never checked, and a turn already out is only stopped" do
    github!()
    ready!()
    coop = coop!([answer_json()], turn_wait_polls: 1)

    # The model turn is out at Coop when the repository is removed.
    step_until_submitted!(coop)

    {:ok, _removed} =
      IntegrationSetup.remove_repository("emisar", storage_root: System.tmp_dir!())

    drain(settings(coop), 40)

    [run] = Repo.all(from(run in Run, where: run.repository_ref == "emisar"))
    assert run.error_code == "repository_knowledge_removed"
    assert %DateTime{} = run.remote_stopped_at
    refute Enum.any?(FakeGitHubRepository.calls(), &match?({:publish, _document}, &1))
    assert Enum.map(FakeCoopAPI.state(coop).validations, & &1.verdict) == []

    # Due or not, it is never taken up again.
    Repo.update_all(Entry, set: [next_check_at: DateTime.add(DateTime.utc_now(), -60)])
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  # Setup saved a repository again when a step finished after Remove
  # (2026-09-27). The knowledge lane saves Work's copy of RYKER.md on the same
  # row, so a proposal that finishes after Remove must not bring it back.
  test "a repository removed while its RYKER.md is proposed stays removed" do
    remove = fn ->
      {:ok, _removed} =
        IntegrationSetup.remove_repository("emisar", storage_root: System.tmp_dir!())
    end

    github!(on_publish: remove)
    ready!()
    coop = coop!([answer_json()])

    drain(settings(coop))

    assert Settings.fetch!().repositories == []
    assert Settings.fetch!().github_bindings == []
  end

  # The model's answer is an input: one that names nothing the repository
  # holds is never accepted. A repository no model ever wrote gets the
  # outline instead, which says what it is.
  test "an answer that names nothing real is refused, and the outline stands in" do
    github!()
    ready!()
    invented = Jason.encode!(invented_answer())
    coop = coop!([invented, invented])

    drain(settings(coop), 60)

    [first, second] =
      Repo.all(from(run in Run, where: run.repository_ref == "emisar", order_by: run.generation))

    assert {first.status, first.error_code} == {:rejected, "repository_knowledge_unusable"}
    assert {second.status, second.error_code} == {:rejected, "repository_knowledge_unusable"}
    assert Enum.map(FakeCoopAPI.state(coop).validations, & &1.verdict) == []

    [_first_prompt, second_prompt] = Enum.map(FakeCoopAPI.state(coop).submissions, & &1["prompt"])
    assert second_prompt =~ "named nothing Ryker"

    %{document: outline, title: "Add Ryker repository knowledge"} =
      FakeGitHubRepository.state().open

    assert Document.origin(outline) == :outline
    refute outline =~ "src/"

    entry = RepositoryKnowledge.entry("emisar")
    assert entry.document_by == :outline

    assert entry.error ==
             "RYKER.md is only an outline: the model named nothing Ryker could find in the " <>
               "repository. Ryker tries again with the next daily check, or refresh knowledge."
  end

  # The outline stands in only where there is nothing better: asking for a
  # refresh of a RYKER.md a person wrote, and a model that cannot finish,
  # must not propose the file list over their document.
  test "a person's RYKER.md is never replaced by the outline when a refresh fails" do
    person = "# How we work\n\nRun `./run gate all` before pushing.\n"
    github!(document: person)
    ready!()
    invented = Jason.encode!(invented_answer())
    coop = coop!([invented, invented])
    drain(settings(coop))

    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)
    drain(settings(coop), 60)

    assert length(FakeCoopAPI.state(coop).submissions) == 2
    refute Enum.any?(FakeGitHubRepository.calls(), &match?({:publish, _document}, &1))
    assert FakeGitHubRepository.state().document == person

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.document} == {:idle, nil}
    assert entry.error =~ "the model named nothing Ryker could find"
    assert repository().knowledge_content == person
  end

  test "a model's RYKER.md is kept when a rewrite names nothing real" do
    github!()
    invented = Jason.encode!(invented_answer())
    coop = coop!([answer_json(), invented, invented])
    written = written!(coop)

    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)
    drain(settings(coop), 60)

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.document} == {:idle, written.document}

    assert entry.error ==
             "RYKER.md was not updated: the model named nothing Ryker could find in the " <>
               "repository. Ryker tries again with the next daily check, or refresh knowledge."

    assert FakeGitHubRepository.state().open.document == written.document
  end

  # A repository row counts the tasks people asked for there. Reading the
  # repository for its RYKER.md is none of them: the first console run showed
  # emisar with "1 task" before anyone had asked Ryker anything.
  test "reading a repository for its RYKER.md is not counted as a task there" do
    github!()
    coop = coop!([answer_json()])
    written!(coop)

    assert Repo.exists?(from(session in Session, where: session.execution_kind == :knowledge))
    assert [%{ref: "emisar", sessions: 0}] = Projection.repositories(%{})
  end

  # The worker sleeps until the next check falls due, as a UTC DateTime,
  # whatever shape the database's aggregate came back in.
  test "the lane sleeps until the next check falls due" do
    github!()
    coop = coop!([answer_json()])
    written!(coop)

    due = Dispatcher.next_due_at(DateTime.add(DateTime.utc_now(), -1, :second))
    assert %DateTime{time_zone: "Etc/UTC"} = due
    assert DateTime.diff(due, Repo.now!()) in 86_000..86_400
  end

  # -- Helpers ---------------------------------------------------------------------

  defp github!(options \\ []) do
    start_supervised!(
      {FakeGitHubRepository,
       Keyword.merge([head: @head, tree: tree!(), files: files!()], options)}
    )
  end

  # Set up as onboarding leaves it, with its first check asked for.
  defp ready! do
    assert {:ok, :ready} = Onboarding.run("emisar", api: FakeGitHubRepository)
  end

  # Set up, written by the model and proposed in PR 84.
  defp written!(coop) do
    ready!()
    drain(settings(coop))
    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.document_by, entry.pull_request_number} == {:model, 84}
    entry
  end

  defp due!,
    do: Repo.update_all(Entry, set: [next_check_at: DateTime.add(DateTime.utc_now(), -60)])

  defp retry_due!,
    do: Repo.update_all(Entry, set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -60)])

  defp age!(days) do
    Repo.update_all(Entry,
      set: [document_at: DateTime.add(DateTime.utc_now(), -days * 86_400 - 60)]
    )
  end

  defp step_until_submitted!(coop) do
    Enum.reduce_while(1..20, nil, fn _pass, _ ->
      {:ok, _result} = Dispatcher.run_once(settings(coop))

      if Map.get(FakeCoopAPI.state(coop), :submissions, []) != [],
        do: {:halt, :ok},
        else: {:cont, nil}
    end)
  end

  defp repository, do: Enum.find(Settings.fetch!().repositories, &(&1.ref == "emisar"))

  defp settings(coop, overrides \\ []) do
    Map.merge(
      %{
        api: API,
        client: coop,
        remote: FakeGitHubRepository,
        worker_ref: "knowledge-test",
        poll_interval_ms: 100,
        idle_interval_ms: 10_000,
        execution_timeout_seconds: 1_800,
        lease_seconds: 300,
        step_delay_seconds: 0,
        retry_delay_seconds: 0
      },
      Map.new(overrides)
    )
  end

  defp coop!(answers, options \\ []) do
    {:ok, coop} =
      FakeCoopAPI.start_link(
        answers,
        Keyword.merge(
          [async_create: true, async_submit: true, async_operations_running: true],
          options
        )
      )

    coop
  end

  # Runs the queue until it has nothing to do, as the worker would.
  defp drain(settings, limit \\ 40) do
    Enum.reduce_while(1..limit, [], fn _pass, results ->
      case Dispatcher.run_once(settings) do
        {:ok, :idle} = idle -> {:halt, results ++ [idle]}
        {:ok, %Entry{}} -> {:cont, results ++ [{:ok, :step}]}
        result -> {:cont, results ++ [result]}
      end
    end)
  end

  defp answer,
    do: Path.join([@fixtures, "emisar", "answer.json"]) |> File.read!() |> Jason.decode!()

  defp answer_json, do: Jason.encode!(answer())

  defp invented_answer do
    %{
      answer()
      | "components" => [%{"path" => "src/", "what_it_does" => "The source."}],
        "build_test_run" => [
          %{"command" => "make test", "what_it_does" => "Tests.", "source_file" => "Makefile"}
        ]
    }
  end

  defp tree! do
    [@fixtures, "emisar", "tree.tsv"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [type, path] = String.split(line, "\t", parts: 2)
      {path, type}
    end)
  end

  defp files! do
    root = Path.join([@fixtures, "emisar", "files"])

    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    # A harvested .exs is kept as .exs.fixture, so ExUnit does not take it
    # for a test file.
    |> Map.new(
      &{&1 |> Path.relative_to(root) |> String.trim_trailing(".fixture"), File.read!(&1)}
    )
  end
end
