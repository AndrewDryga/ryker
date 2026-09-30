defmodule Ryker.Evals.ClientJobTest do
  use Ryker.DataCase, async: true

  alias Ryker.Coop.Client
  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Evals.{Job, WorldSource}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Learning.FleetSession
  alias Ryker.Work.{Custody, RepositorySource, Session}

  setup do
    {:ok, job} = Job.new(:world, "codex:fixture/high@eval")

    {:ok, client} =
      Client.new(
        finch: NoNetwork,
        receive_timeout: 100,
        socket: "/tmp/eval-never-dialed.sock",
        job: job
      )

    {:ok, client: client, job: job}
  end

  test "real eval client pins Work authority before network and never rewrites it", %{
    client: client,
    job: job
  } do
    session = work_session(job)
    key = Custody.Sessions.create_operation_key(session)
    ref = Session.coop_task_ref(session)

    assert :ok = Client.prepare_create_session(client, key, job.name, ref, nil)
    pinned = Repo.get!(Session, session.id)
    assert {:ok, ^pinned} = JobAuthority.validate(pinned)
    assert {:ok, expected, digest} = Job.bind(job, session.external_ref)
    assert pinned.worker_job_document == expected
    assert pinned.worker_job_digest == digest
    assert :ok = Client.prepare_create_session(client, key, job.name, ref, nil)

    {:ok, changed} = Job.new(:world, "codex:different/high@eval")

    assert {:error, :model_eval_session_authority_mismatch} =
             Client.prepare_create_session(%{client | job: changed}, key, job.name, ref, nil)

    assert Repo.get!(Session, session.id).worker_job_digest == digest
  end

  test "noncanonical, stale, crossed, repository and abandoned creates do not pin", %{
    client: client,
    job: job
  } do
    session = work_session(job)
    key = Custody.Sessions.create_operation_key(session)
    ref = Session.coop_task_ref(session)

    for invalid <- [
          String.replace_suffix(key, "g1", "g01"),
          String.replace_suffix(key, "g1", "g+1"),
          String.replace_suffix(key, "g1", "g2"),
          "ryker:learning:create:#{session.id}"
        ] do
      assert {:error, _} = Client.prepare_create_session(client, invalid, job.name, ref, nil)
      assert Repo.get!(Session, session.id).worker_job_document == nil
    end

    assert {:error, _} = Client.prepare_create_session(client, key, job, ref, nil)
    assert {:error, _} = Client.prepare_create_session(client, key, job.name, "wrong-task", nil)

    assert {:error, _} =
             Client.prepare_create_session(client, key, job.name, ref, %{"kind" => "default"})

    assert Repo.get!(Session, session.id).worker_job_document == nil

    session |> Ecto.Changeset.change(cleanup_status: :close_pending) |> Repo.update!()
    assert {:error, _} = Client.prepare_create_session(client, key, job.name, ref, nil)
    assert Repo.get!(Session, session.id).worker_job_document == nil
  end

  test "a world session may name only the repository its job's staged checkout holds", %{
    client: client,
    job: job
  } do
    source =
      WorldSource.source(
        "blitz-rivals-scraper",
        String.duplicate("1", 40),
        String.duplicate("2", 40),
        ~U[2026-08-21 02:21:46Z]
      )

    {:ok, sourced} = Job.with_source(job, source)
    client = %{client | job: sourced}

    session = work_session(sourced, "blitz-rivals-scraper")
    key = Custody.Sessions.create_operation_key(session)
    ref = Session.coop_task_ref(session)
    default = RepositorySource.default()
    assert :ok = Client.prepare_create_session(client, key, sourced.name, ref, default)
    pinned = Repo.get!(Session, session.id)
    assert pinned.worker_job_document["source"] == source
    assert {:ok, ^pinned} = JobAuthority.validate(pinned)

    other = work_session(sourced, "another-repository")

    assert {:error, :model_eval_session_authority_mismatch} =
             Client.prepare_create_session(
               client,
               Custody.Sessions.create_operation_key(other),
               sourced.name,
               Session.coop_task_ref(other),
               default
             )

    unsourced = work_session(job, "blitz-rivals-scraper")

    assert {:error, :model_eval_session_authority_mismatch} =
             Client.prepare_create_session(
               %{client | job: job},
               Custody.Sessions.create_operation_key(unsourced),
               job.name,
               Session.coop_task_ref(unsourced),
               nil
             )

    assert {:error, {:invalid_coop_request, :repository_source}} =
             Client.prepare_create_session(
               client,
               key,
               sourced.name,
               ref,
               %{"kind" => "branch", "name" => "feature"}
             )
  end

  test "learning uses the real preparation callback with no scratch checkout", %{client: client} do
    {:ok, job} = Job.new(:learning, "codex:fixture/high@eval")
    inputs = LearningFixtures.inputs!()

    {:ok, run} =
      Ryker.Learning.prepare(Enum.map(inputs, & &1.id), %{
        policy: job.name,
        policy_digest: job.digest
      })

    {:ok, session} = FleetSession.ensure(run)
    key = Ryker.Learning.operation_key(run, :create)

    assert :ok =
             Client.prepare_create_session(
               %{client | job: job},
               key,
               job.name,
               FleetSession.external_ref(run),
               nil
             )

    pinned = Repo.get!(Session, session.id)
    assert pinned.worker_job_document["source"] == nil
    assert pinned.worker_job_document["repository_read_only"]
    assert {:ok, ^pinned} = JobAuthority.validate(pinned)
  end

  defp work_session(job, repository_ref \\ nil) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Ryker.Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "eval:#{id}",
          native_input_id: "source:#{id}",
          occurred_at: Repo.now!(),
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, session} = Custody.pin_episode(id, job.name, job.digest, nil, repository_ref)
    session
  end
end
