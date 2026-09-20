defmodule Ryker.Repo.Migrations.KeepGitHubSemanticDeduplicationInInputCustody do
  use Ecto.Migration

  def change do
    # A webhook delivery ID is the transport idempotency key. Equivalent
    # payloads with different delivery IDs must still reach input/publication
    # custody, which owns revision-aware semantic deduplication and can return
    # the original durable receipt.
    drop_if_exists(unique_index(:github_repository_events, [:binding_ref, :payload_digest]))
  end
end
