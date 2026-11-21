defmodule Ryker.Repo.Migrations.AllowFastModeInModelLists do
  use Ecto.Migration

  # Andrew, 2026-11-21: "can we also allow using fast mode?" A model may ask Coop for its
  # provider's fast mode, written after its effort: codex:gpt-6.2-sol/medium+fast@default. Each
  # kind of work's list of models is checked whole, so the check learns the optional +fast.
  @lists [
    routing_models: :work_settings_routing_models_valid,
    conversation_models: :work_settings_conversation_models_valid,
    standard_models: :work_settings_standard_models_valid,
    deep_models: :work_settings_deep_models_valid,
    contributor_models: :work_settings_contributor_models_valid,
    schedule_models: :work_settings_schedule_models_valid,
    incident_models: :work_settings_incident_models_valid,
    learning_models: :work_settings_learning_models_valid
  ]
  @plain "(codex|claude):[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}"
  @fast "(codex|claude):[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)(\\+fast)?@[a-z0-9][a-z0-9_-]{0,63}"

  def up, do: recheck(@fast)

  # Rolling back needs every saved model back on standard speed first.
  def down, do: recheck(@plain)

  defp recheck(entry) do
    for {column, name} <- @lists do
      drop(constraint(:work_settings, name))
      create(constraint(:work_settings, name, check: list_check(column, entry, 4)))
    end
  end

  # One dimension, one to `most` entries, none of them null, each matching `entry` exactly. An
  # entry holds no spaces, so the entries joined by one space match the pattern repeated only
  # when every one of them does.
  defp list_check(column, entry, most) do
    """
    array_ndims(#{column}) = 1 AND cardinality(#{column}) BETWEEN 1 AND #{most} AND
    array_position(#{column}, NULL) IS NULL AND
    array_to_string(#{column}, ' ') ~ '^#{entry}( #{entry})*$'
    """
  end
end
