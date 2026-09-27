defmodule Ryker.Repo.Migrations.AddCoopWorkerJobAuthority do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      add(:worker_job_document, :text)
      add(:worker_job_digest, :string)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_worker_job_valid,
        check: """
        (worker_job_document IS NULL AND worker_job_digest IS NULL)
        OR (worker_job_document IS NOT NULL AND worker_job_digest ~ '^[0-9a-f]{64}$'
            AND octet_length(worker_job_document::text) <= 262144)
        """
      )
    )
  end
end
