defmodule Ryker.RepositoryKnowledge.LaneTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.RepositoryProjection
  alias Ryker.GitHub.Onboarding
  alias Ryker.{IntegrationSetup, RepositoryKnowledge, Settings}
  alias Ryker.RepositoryKnowledge.{Dispatcher, Entry, Prompt, Run}
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

  # A mirror of a large repository that takes longer than the lease to
  # prepare. Halfway through, a rival worker tries to take the run.
  defmodule SlowPreparationAPI do
    alias Ryker.RepositoryKnowledge.Custody
    alias Ryker.RepositoryKnowledge.LaneTest.API

    def prepare_create_session(client, key, policy, ref, source) do
      Process.sleep(1_600)
      rival = Custody.claim("knowledge-rival", %{lease_seconds: 60}, ["emisar"])
      send(self(), {:rival_claim, rival})
      API.prepare_create_session(client, key, policy, ref, source)
    end

    defdelegate create_session(client, key, policy, ref, source), to: API
    defdelegate get_session(client, id), to: API
    defdelegate get_turn(client, session_id, turn_id), to: API
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: API
    defdelegate operation_by_key(client, key), to: API

    defdelegate submit_frozen_turn(client, session_id, key, revision, submission, gate, extra),
      to: API

    defdelegate validate_frozen_candidate(
                  client,
                  session_id,
                  turn_id,
                  key,
                  attempt,
                  sha,
                  verdict
                ),
                to: API
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
  # document a model wrote from reading it, checked against it.
  #
  # Andrew, 2026-09-28: "Since we refresh repo knowledge daily should we save
  # its state locally instead of DB? I don't want to make daily PRs to update
  # those files." Every write was proposed besides in a draft pull request,
  # and four stood open (emisar#85, ryker#10, coop#17, test#1) for knowledge
  # Ryker already kept and briefed Work with. A finished run is the
  # repository's knowledge at once, and GitHub is only read.
  test "a finished knowledge run becomes the repository's knowledge without a pull request" do
    github!()
    coop = coop!([answer_json()], turn_wait_polls: 2)

    assert {:ok, :ready} = Onboarding.run("emisar", api: FakeGitHubRepository)
    assert repository().onboarding_state == :ready
    assert repository().source_commit == @head

    results = drain(settings(coop))
    assert {:ok, :written} in results

    # GitHub is only read: the head, the tree and the files the answer
    # cites. Nothing is written there, and a RYKER.md the repository holds is
    # never asked for by name.
    assert FakeGitHubRepository.calls() |> Enum.map(&call_kind/1) |> Enum.uniq() |> Enum.sort() ==
             [:head, :read, :tree]

    refute Enum.any?(FakeGitHubRepository.calls(), &match?({:read, "RYKER.md", _ref}, &1))

    # The model read exactly the default branch head, read-only, alone.
    state = FakeCoopAPI.state(coop)
    assert state.create_sources == [%{"kind" => "commit", "sha" => @head}]
    assert [submission] = state.submissions
    assert submission["contract_version"] == Prompt.contract_version()
    assert submission["output_schema"] == Prompt.output_schema()
    assert submission["prompt"] =~ ~s("name":"AndrewDryga/emisar")
    assert submission["prompt"] =~ ~s("portal/mix.exs")

    # The checked document, which pins no link, is the repository's
    # knowledge until tomorrow's check.
    entry = RepositoryKnowledge.entry("emisar")
    document = entry.document

    assert {entry.phase, entry.document_by, entry.document_commit, entry.error} ==
             {:idle, :model, @head, nil}

    assert String.starts_with?(document, "# RYKER.md\n\nWritten by Ryker from `783fc48` on ")
    assert document =~ "[portal/](portal/) — Elixir/Phoenix control plane"
    assert document =~ "- `./run help` — Lists every contributor command."
    refute document =~ "://"
    refute document =~ @head
    assert entry.reason == "Ryker has no RYKER.md for this repository yet."
    assert DateTime.diff(entry.next_check_at, Repo.now!()) in 86_000..86_400

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

  # Mirroring a large repository before its session can be created can take
  # minutes, and nothing renewed the lease meanwhile: another worker took the
  # run over mid-preparation. The 2026-09-28 review found it in Work first.
  test "a source preparation that outlasts the lease keeps the run" do
    github!()
    coop = coop!([answer_json()], turn_wait_polls: 2)
    assert {:ok, :ready} = Onboarding.run("emisar", api: FakeGitHubRepository)

    results = drain(settings(coop, api: SlowPreparationAPI, lease_seconds: 1))

    assert_received {:rival_claim, {:ok, :idle}}
    assert {:ok, :written} in results
    assert RepositoryKnowledge.entry("emisar").document_by == :model
  end

  # Andrew, 2026-09-27: "also when those are updated?" Once a day each
  # repository is checked; a push that touches no file a teammate reads to
  # learn it costs no model turn, and each rewrite is the knowledge at once.
  test "the daily check rewrites only when the default branch moved and a key file changed" do
    github!()
    changed = Map.put(answer(), "purpose", answer()["purpose"] <> " It is dual-licensed.")
    later = Map.put(answer(), "purpose", answer()["purpose"] <> " It is MIT-licensed.")
    coop = coop!([answer_json(), Jason.encode!(changed), Jason.encode!(later)])
    written!(coop)

    # A push that changed only code: one step, the check, and no turn.
    FakeGitHubRepository.push(@head, @merged, ["portal/apps/emisar/lib/emisar.ex"])
    due!()

    assert drain(settings(coop)) == [{:ok, :step}, {:ok, :idle}]
    assert length(FakeCoopAPI.state(coop).submissions) == 1
    assert RepositoryKnowledge.entry("emisar").phase == :idle

    # A README change is worth a turn, and its document is the knowledge.
    FakeGitHubRepository.push(@head, @pushed, ["README.md", "runner/main.go"])
    due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 2
    entry = RepositoryKnowledge.entry("emisar")
    assert entry.reason == "These files changed: README.md."
    assert entry.document =~ "dual-licensed"

    # The next rewrite replaces it the same way.
    FakeGitHubRepository.push(@pushed, @later, ["portal/mix.exs"])
    due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 3
    entry = RepositoryKnowledge.entry("emisar")
    assert entry.document =~ "Written by Ryker from `3333333` on "
    assert entry.document =~ "MIT-licensed"
  end

  test "a week after the last write, any code change is enough" do
    github!()
    coop = coop!([answer_json(), answer_json()])
    written!(coop)

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

    # The rewrite is the repository's knowledge as soon as it is written.
    assert applied_runs() == 2
    assert RepositoryKnowledge.entry("emisar").phase == :idle

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
      &%{&1 | errors: %{head: {:error, {:github_onboarding, :response}}}}
    )

    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop, retry_delay_seconds: 60))

    entry = RepositoryKnowledge.entry("emisar")
    assert {entry.phase, entry.requested_by, entry.error} == {:write, @actor, nil}
    assert DateTime.diff(entry.next_attempt_at, Repo.now!()) in 55..60

    FakeGitHubRepository.update(&%{&1 | errors: %{}})
    retry_due!()
    drain(settings(coop))

    assert length(FakeCoopAPI.state(coop).submissions) == 2
    assert applied_runs() == 2
  end

  # The outline stands in when no model could finish, and a README Ryker
  # cannot read failed it as if GitHub had not answered, every minute.
  test "the outline stands in without a README Ryker cannot read" do
    github!(files: Map.put(files!(), "README.md", :unreadable))
    ready!()
    invented = Jason.encode!(invented_answer())
    coop = coop!([invented, invented])

    drain(settings(coop), 60)

    outline = RepositoryKnowledge.entry("emisar").document
    assert RepositoryKnowledge.entry("emisar").document_by == :outline
    assert outline =~ "The README does not say what the repository is for."
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
    assert Enum.map(FakeCoopAPI.state(coop).validations, & &1.verdict) == []

    # Due or not, it is never taken up again.
    Repo.update_all(Entry, set: [next_check_at: DateTime.add(DateTime.utc_now(), -60)])
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
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

    outline = RepositoryKnowledge.entry("emisar").document
    assert RepositoryKnowledge.entry("emisar").document_by == :outline
    refute outline =~ "src/"

    entry = RepositoryKnowledge.entry("emisar")
    assert entry.document_by == :outline

    assert entry.error ==
             "RYKER.md is only an outline: the model named nothing Ryker could find in the " <>
               "repository. Ryker tries again with the next daily check, or refresh knowledge."
  end

  # Review of the knowledge lane, 2026-09-28: an answer the custody refuses
  # to keep (larger than a run holds) read as Coop not answering, so the
  # same turn was asked about again and again for a day and a half, left
  # open at the worker, with no start spent. It ends its attempt now: the
  # turn is cancelled and stopped, and the next start is made.
  test "an answer too large to keep ends its attempt, and the next start is made" do
    github!()
    ready!()
    coop = coop!([String.duplicate("a", 131_073), answer_json()])

    drain(settings(coop), 60)

    [first, second] =
      Repo.all(from(run in Run, where: run.repository_ref == "emisar", order_by: run.generation))

    assert {first.status, first.error_code} == {:rejected, "invalid_repository_knowledge"}
    assert %DateTime{} = first.remote_stopped_at
    assert first.stop_receipt["state"] == "cancelled"
    assert first.result == nil

    assert second.status == :applied
    assert length(FakeCoopAPI.state(coop).submissions) == 2
    assert RepositoryKnowledge.entry("emisar").document_by == :model
  end

  # Review of the knowledge lane, 2026-09-28: the rendered RYKER.md had no
  # bound of its own, but both tables keep at most 128,000 bytes of it. An
  # answer within every limit of the contract can render larger, since each
  # path is written twice in its link, once percent-encoded, and keeping it
  # raised at the database on every step. It is refused as unusable first.
  test "a document too large to keep is refused as unusable, and the next start is made" do
    directories = for n <- 10..49, do: "d#{n}" <> String.duplicate("𝒜", 120)
    github!(tree: Enum.map(directories, &{&1, "tree"}), files: %{})
    ready!()

    large = %{
      answer()
      | "components" =>
          Enum.map(directories, &%{"path" => &1, "what_it_does" => String.duplicate("a", 400)}),
        "build_test_run" => [],
        "deploy_release" => [],
        "conventions" => [],
        "where_to_look" =>
          directories
          |> Enum.take(20)
          |> Enum.map(&%{"task" => String.duplicate("b", 200), "path" => &1}),
        "open_questions" => []
    }

    small = %{large | "components" => Enum.take(large["components"], 1), "where_to_look" => []}
    assert byte_size(Jason.encode!(large)) <= 131_072
    coop = coop!([Jason.encode!(large), Jason.encode!(small)])

    drain(settings(coop), 60)

    [first, second] =
      Repo.all(from(run in Run, where: run.repository_ref == "emisar", order_by: run.generation))

    assert {first.status, first.error_code, first.document} ==
             {:rejected, "repository_knowledge_unusable", nil}

    assert second.status == :applied
    assert RepositoryKnowledge.entry("emisar").document_by == :model
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
  end

  # A repository row counts the tasks people asked for there. Reading the
  # repository for its RYKER.md is none of them: the first console run showed
  # emisar with "1 task" before anyone had asked Ryker anything.
  test "reading a repository for its RYKER.md is not counted as a task there" do
    github!()
    coop = coop!([answer_json()])
    written!(coop)

    assert Repo.exists?(from(session in Session, where: session.execution_kind == :knowledge))
    assert [%{ref: "emisar", sessions: 0}] = RepositoryProjection.list(%{})
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

  # Set up and written by the model.
  defp written!(coop) do
    ready!()
    drain(settings(coop))
    entry = RepositoryKnowledge.entry("emisar")
    assert entry.document_by == :model
    entry
  end

  defp applied_runs,
    do:
      Repo.aggregate(
        from(run in Run, where: run.repository_ref == "emisar" and run.status == :applied),
        :count
      )

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

  # What GitHub was asked, without its arguments: `:head`, `:tree`, `:read`.
  defp call_kind(call) when is_tuple(call), do: elem(call, 0)
  defp call_kind(call), do: call

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
