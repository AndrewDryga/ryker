defmodule Ryker.Fixtures.ModelAccess do
  @moduledoc false
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.{Config, Episodes, Repo}
  alias Ryker.CoopFleet.{ControlPlane, JobSpec, ModelAccounts}
  alias Ryker.Fixtures.{CoopWorkers, WorkerJob, WorkSessions}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.Session

  def create! do
    Config.put_override(:credential_key, :binary.copy(<<31>>, 32))
    certificate = "model-worker-certificate"
    {:ok, _worker} = CoopWorkers.authorize("model-worker", "model-pool", digest(certificate))
    {:ok, _response} = ControlPlane.handle_poll_certificate(certificate, poll())
    episode = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode,
          episode_key: "models:#{episode}",
          native_input_id: "models:#{episode}",
          occurred_at: Repo.now!(),
          turn_ref: "models:#{episode}"
        })
      )

    {:ok, session} =
      WorkSessions.pin_episode(episode, "work-read-only", String.duplicate("b", 64),
        repository_ref: "ryker"
      )

    session = WorkerJob.pin!(session)

    job =
      session.worker_job_document
      |> Map.put("model_credentials", "controller")
      |> Map.put("targets", ["claude:sonnet/high@work"])

    {:ok, checksum} = JobSpec.digest(job)
    session = session |> Session.Changeset.pin_worker_job(job, checksum) |> Repo.update!()

    {:ok, placement} =
      ControlPlane.place_session(
        session.id,
        %{capability_names: [], repository_ref: "ryker", workspace_ref: "model-pool"},
        60
      )

    {:ok, _metadata} =
      ModelAccounts.put_key("claude@work", "controller-only-provider-key-canary", "test")

    request = %{
      "job_digest" => checksum,
      "provider" => "claude",
      "account" => "work",
      "run_id" => "native-run"
    }

    %{certificate: certificate, session: session, placement: placement, request: request}
  end

  defp poll do
    %{
      "version" => 2,
      "poll_ref" => "models-first",
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "worker" => %{
        "id" => "model-worker",
        "workspace_ref" => "model-pool",
        "protocol_version" => "2",
        "build_version" => "test",
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "capabilities" => [],
        "capacity" => %{
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2,
          "state" => "eligible",
          "cooldown_until" => nil
        }
      }
    }
  end
end
