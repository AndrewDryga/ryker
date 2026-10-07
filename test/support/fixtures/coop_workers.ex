defmodule Ryker.Fixtures.CoopWorkers do
  @moduledoc """
  A Coop worker a test registers under a certificate it makes up. Production
  workers enroll (`Ryker.CoopFleet.Enrollment`); until 2026-10-07 this was a
  control-plane function nothing but tests called, and it minted ten-year
  certificates (2026-10-04 review). A test polls as the worker through
  `Ryker.CoopFleet.ControlPlane.handle_poll_certificate/3` with the
  certificate whose SHA-256 it registered.
  """

  alias Ryker.CoopFleet.{Certificate, Worker}
  alias Ryker.Repo

  @doc """
  Registers `worker_id` in `workspace_ref`, holding the certificate whose
  SHA-256 is `certificate_sha256`, the way enrollment leaves a new worker.
  Registering it again under the same digest changes nothing.
  """
  @spec authorize(String.t(), String.t(), String.t()) :: {:ok, Worker.t()} | {:error, term()}
  def authorize(worker_id, workspace_ref, certificate_sha256) do
    Repo.transaction(fn ->
      worker =
        Repo.one(Worker.Query.by_id(worker_id)) ||
          %{
            certificate_sha256: certificate_sha256,
            id: worker_id,
            workspace_ref: workspace_ref,
            state: :offline
          }
          |> Worker.Changeset.insert()
          |> Repo.insert!()

      now = Repo.now!()

      %{
        expires_at: DateTime.add(now, 24 * 3_600, :second),
        issued_by: "test",
        not_before: now,
        serial_number: "test-#{String.slice(certificate_sha256, 0, 16)}",
        sha256: certificate_sha256,
        source: :renewal,
        worker_id: worker_id
      }
      |> Certificate.Changeset.insert()
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :sha256)

      worker
    end)
  end
end
