defmodule Ryker.Repo.Migrations.AddModelsToWorkSettings do
  use Ecto.Migration

  # The model each kind of work runs on in the bundled worker, saved in
  # revisioned, audited settings instead of a container environment variable
  # an operator could neither see nor change without a restart.
  @models [
    routing_model: "codex:gpt-5.6-sol/medium@default",
    conversation_model: "codex:gpt-5.6-terra/medium@default",
    standard_model: "codex:gpt-5.6-sol/medium@default",
    deep_model: "codex:gpt-5.6-sol/xhigh@default",
    contributor_model: "codex:gpt-5.6-sol/medium@default",
    schedule_model: "codex:gpt-5.6-sol/medium@default",
    incident_model: "codex:gpt-5.6-sol/medium@default",
    learning_model: "codex:gpt-5.6-sol/medium@default"
  ]
  @target "^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$"

  def up do
    alter table(:work_settings) do
      for {column, default} <- @models do
        add(column, :text, null: false, default: default)
      end
    end

    for {column, _default} <- @models do
      create(
        constraint(:work_settings, :"work_settings_#{column}_valid",
          check: "#{column} ~ '#{@target}'"
        )
      )
    end
  end

  def down do
    for {column, _default} <- @models do
      drop(constraint(:work_settings, :"work_settings_#{column}_valid"))
    end

    alter table(:work_settings) do
      for {column, _default} <- @models, do: remove(column)
    end
  end
end
