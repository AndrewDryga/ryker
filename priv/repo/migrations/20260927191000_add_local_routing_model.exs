defmodule Ryker.Repo.Migrations.AddLocalRoutingModel do
  use Ecto.Migration

  # Settings › Models › Local routing model (Andrew, 2026-09-27: "build/fine-tune
  # our own super-efficient self hosted model later ... So we can do more on
  # free routing steps more accurately and fallback to large provider models
  # only when needed"). Phase 1 only measures: with the mode at `shadow`, each
  # routing decision Ryker accepts queues one comparison, which asks the local
  # model at the saved OpenAI-compatible endpoint the exact prompt the provider
  # answered and records how its answer compares (`Ryker.LocalRouting`).
  #
  # Every installation arrives with it off and nothing else changes. A
  # comparison is operational data: it leaves with its message's bodies, and
  # with the message itself.

  def up do
    alter table(:work_settings) do
      add(:local_routing_mode, :text, null: false, default: "off")
      add(:local_routing_endpoint, :text)
      add(:local_routing_model, :text)
    end

    create(
      constraint(:work_settings, :work_settings_local_routing_valid,
        check: """
        local_routing_mode IN ('off', 'shadow') AND
        (local_routing_endpoint IS NULL OR octet_length(local_routing_endpoint) BETWEEN 1 AND 2048) AND
        (local_routing_model IS NULL OR octet_length(local_routing_model) BETWEEN 1 AND 200) AND
        (local_routing_mode = 'off' OR
          (local_routing_endpoint IS NOT NULL AND local_routing_model IS NOT NULL))
        """
      )
    )

    create table(:local_routing_comparisons, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:generation, :integer, null: false)
      add(:execution_mode, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error, :text)
      add(:local_model, :text, null: false)
      add(:valid, :boolean)
      add(:invalid_reason, :text)
      add(:agrees, :boolean)
      add(:differing_fields, {:array, :text}, null: false, default: fragment("'{}'::text[]"))
      add(:local_answer, :text)
      add(:local_ms, :bigint)
      add(:local_input_tokens, :bigint)
      add(:local_output_tokens, :bigint)
      add(:provider_cost_usd, :decimal, precision: 30, scale: 12)
      add(:provider_cost_estimated, :boolean)
      add(:provider_ms, :bigint)
      add(:compared_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:local_routing_comparisons, [:input_id, :generation]))

    create(
      index(:local_routing_comparisons, [:next_attempt_at],
        name: :local_routing_comparisons_due_index,
        where: "status = 'pending'"
      )
    )

    create(index(:local_routing_comparisons, [:inserted_at]))

    create(
      constraint(:local_routing_comparisons, :local_routing_comparison_valid,
        check: """
        generation > 0 AND attempt_count >= 0 AND
        execution_mode IN ('live', 'shadow') AND
        status IN ('pending', 'compared', 'failed') AND
        octet_length(local_model) BETWEEN 1 AND 200 AND
        (last_error IS NULL OR octet_length(last_error) BETWEEN 1 AND 1024) AND
        (invalid_reason IS NULL OR octet_length(invalid_reason) BETWEEN 1 AND 256) AND
        (local_answer IS NULL OR octet_length(local_answer) <= 16384) AND
        (local_ms IS NULL OR local_ms >= 0) AND
        (local_input_tokens IS NULL OR local_input_tokens >= 0) AND
        (local_output_tokens IS NULL OR local_output_tokens >= 0) AND
        (provider_ms IS NULL OR provider_ms >= 0) AND
        (provider_cost_usd IS NULL OR provider_cost_usd >= 0) AND
        (status <> 'pending' OR (valid IS NULL AND agrees IS NULL AND compared_at IS NULL)) AND
        (status <> 'compared' OR
          (valid IS NOT NULL AND compared_at IS NOT NULL AND local_ms IS NOT NULL AND
           next_attempt_at IS NULL)) AND
        (status <> 'failed' OR
          (last_error IS NOT NULL AND valid IS NULL AND next_attempt_at IS NULL)) AND
        (valid IS NOT TRUE OR (agrees IS NOT NULL AND invalid_reason IS NULL)) AND
        (valid IS NOT FALSE OR (agrees IS NULL AND invalid_reason IS NOT NULL)) AND
        (agrees IS NOT TRUE OR cardinality(differing_fields) = 0) AND
        (agrees IS NOT FALSE OR cardinality(differing_fields) > 0)
        """
      )
    )
  end

  # The previous release has nowhere to keep a comparison or the setting, so
  # rolling back waits until neither holds anything rather than dropping what
  # someone typed or what the comparisons measured.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("local_routing_comparisons")}) THEN
        RAISE EXCEPTION 'local routing comparisons are recorded; the previous release has nowhere to keep them';
      END IF;

      IF EXISTS (
        SELECT 1 FROM #{qualified("work_settings")}
        WHERE local_routing_mode <> 'off' OR local_routing_endpoint IS NOT NULL
           OR local_routing_model IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'Local routing model is set in Settings › Models; turn it off and clear it before rolling back';
      END IF;
    END
    $$
    """)

    drop(table(:local_routing_comparisons))
    drop(constraint(:work_settings, :work_settings_local_routing_valid))

    alter table(:work_settings) do
      remove(:local_routing_model)
      remove(:local_routing_endpoint)
      remove(:local_routing_mode)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
