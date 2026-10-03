defmodule Ryker.Work.RetryCurrentSettingsTest do
  @moduledoc """
  A blitz task stopped on theblitzapp/blitz-core, a read-only repository whose submodule
  Ryker cannot fetch (2026-10-03). Taking blitz-core out of the environment did not help it:
  "Run the task again" reused the session admitted with blitz-core, and Ryker's settings no
  longer matched it, so the retry stopped too. Andrew: a retry of a task that never started
  should pick up the environment as it is now.
  """
  use Ryker.DataCase, async: true

  alias Ryker.CoopFleet.{JobAuthority, JobTemplates}
  alias Ryker.{Episodes, Repo, Settings}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.Cancellation, as: WorkCancellation
  alias Ryker.Work.{Custody, Session}
  alias Ryker.Work.Custody.CurrentAuthority
  alias Ryker.Work.Executor.Remote

  @actor "control-plane:local"

  setup do
    {:ok, _snapshot} = Settings.initialize(@actor)
    add_repository!("app", 17)
    add_repository!("library", 18)
    add_repository!("tools", 19)
    environment!(["app", "library", "tools"])
    :ok
  end

  test "a task no worker ever took runs again on its environment as it is now" do
    work = blocked_unstarted!("taken-out")

    # The read-only repository that stopped it is taken out of the environment.
    environment!(["app", "library"])

    assert {:ok, _episode} =
             Custody.retry_blocked(work.episode_key, Custody.recovery_fingerprint(work.turn))

    session = Repo.get!(Session, work.session.id)
    current = binding!("app")

    assert session.repository_context["read_only_repositories"] == ["library"]
    assert session.policy_digest == current.policy_digest
    assert session.authority_digest == current.authority_digest
    assert session.worker_job_document == nil

    # And the job pins against settings as they are, with only what is left.
    prepare = fn _root, ref, _selector -> {:ok, %{source: source(ref)}} end
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, nil, prepare)
    assert Enum.map(pinned.worker_job_document["companions"], & &1["name"]) == ["library"]
  end

  test "a session a worker has taken keeps the authority it was admitted with" do
    work = blocked_unstarted!("started")
    environment!(["app", "library"])

    started =
      work.session
      |> Ecto.Changeset.change(coop_session_id: "coop-session-started")
      |> Repo.update!()

    assert CurrentAuthority.refresh_locked(started) == started

    assert Repo.get!(Session, started.id).repository_context["read_only_repositories"] == [
             "library",
             "tools"
           ]
  end

  defp blocked_unstarted!(suffix) do
    id = Ecto.UUID.generate()
    template = binding!("app")

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "retry-current:#{suffix}:#{id}",
        native_input_id: "source:retry-current:#{suffix}:#{id}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:retry-current:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               id,
               template.policy_name,
               template.policy_digest,
               template.authority_digest,
               "app"
             )

    session
    |> Ecto.Changeset.change(
      environment_ref: "production",
      repository_context: %{
        "context_ref" => "production",
        "parallel_goal_limit" => 3,
        "primary_repository" => "app",
        "read_only_repositories" => ["library", "tools"]
      }
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)

    assert {:ok, _requested} =
             Custody.request_block(
               id,
               command.episode_key,
               command.turn_ref,
               claim.lease_ref,
               "coop_worker_companion_refused: {:coop_worker_companion_refused, \"example/tools\", \"skypjack/entt\"}"
             )

    assert {:ok, stop} = Custody.claim_next("worker:#{suffix}:stop", 60)

    assert {:ok, receipt} =
             WorkCancellation.absent_receipt(Remote.create_key(stop.session), nil, nil, nil, nil)

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               id,
               command.episode_key,
               command.turn_ref,
               stop.lease_ref,
               receipt
             )

    assert blocked.turn.status == :blocked

    %{
      episode_key: command.episode_key,
      session: Repo.get!(Session, stop.session.id),
      turn: blocked.turn
    }
  end

  defp binding!(primary) do
    Enum.find(
      JobTemplates.from_settings(Settings.fetch!()),
      &(&1.purpose == :contributor and &1.scope_kind == :environment and
          &1.scope_ref == "production" and &1.repository_ref == primary)
    )
  end

  defp environment!(repositories) do
    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: repositories},
        Settings.fetch!().installation.revision,
        @actor
      )
  end

  defp add_repository!(ref, id) do
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: ref, github_repository: "example/" <> ref, base_branch: "main"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _} =
      Settings.put_github_binding(
        %{
          name: ref,
          repository_ref: ref,
          installation_id: 41,
          repository_id: id,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        @actor
      )

    Repo.get_by!(Settings.Repository, ref: ref)
    |> Ecto.Changeset.change(source_commit: String.duplicate("a", 40))
    |> Repo.update!()
  end

  defp source(ref) do
    commit = String.duplicate("a", 40)

    %{
      "repository_ref" => ref,
      "github_repository" => "example/" <> ref,
      "github_repository_id" => %{"app" => 17, "library" => 18, "tools" => 19}[ref],
      "submodules" => [],
      "binding" => %{
        "version" => 1,
        "kind" => "default",
        "requested" => %{"kind" => "default"},
        "remote_identity" => "origin",
        "default_ref" => "refs/heads/main",
        "selected_ref" => "refs/heads/main",
        "default_commit" => commit,
        "selected_commit" => commit,
        "base_commit" => commit,
        "admitted_tree" => String.duplicate("b", 40),
        "resolved_at" => "2026-10-03T12:00:00Z"
      }
    }
  end
end
