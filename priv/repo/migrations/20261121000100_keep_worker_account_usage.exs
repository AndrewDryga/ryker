defmodule Ryker.Repo.Migrations.KeepWorkerAccountUsage do
  use Ecto.Migration

  # The allowance each account a worker holds has left, as its providers last
  # reported it in the worker's hello (Ryker.CoopFleet.AccountUsage).
  def change do
    alter table(:coop_workers) do
      add(:account_usage, :text)
    end

    create(
      constraint(:coop_workers, :coop_worker_account_usage_valid,
        check: """
        account_usage IS NULL OR (octet_length(account_usage) <= 65536 AND
          jsonb_typeof(account_usage::jsonb) = 'object' AND
          (account_usage::jsonb ->> 'version')::integer = 1)
        """
      )
    )
  end
end
