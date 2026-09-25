defmodule Ryker.Repo.Migrations.NameTheEnvironmentSetupStep do
  @moduledoc """
  The channel setup Q&A asks for an environment where it asked for a
  repository, so its second step is named `environment`.

  A Q&A still open when this runs offered repositories that no channel can
  select any more; it is marked expired, the way an unanswered one ends after
  thirty minutes, and the channel keeps its saved settings. Finished ones keep
  their drafts as history. Rolling back does the same in the other direction.
  """
  use Ecto.Migration

  def up, do: rename_step("repository", "environment")
  def down, do: rename_step("environment", "repository")

  defp rename_step(from, to) do
    execute("""
    UPDATE #{qualified("slack_configuration_sessions")}
    SET status = 'expired'
    WHERE status IN ('asking', 'confirming')
    """)

    drop(constraint(:slack_configuration_sessions, :slack_configuration_session_valid))

    execute(
      "UPDATE #{qualified("slack_configuration_sessions")} SET step = '#{to}' WHERE step = '#{from}'"
    )

    create(
      constraint(:slack_configuration_sessions, :slack_configuration_session_valid,
        check:
          "step IN ('participation', '#{to}', 'alerts', 'audience', 'confirm') " <>
            "AND status IN ('asking', 'confirming', 'saved', 'cancelled', 'expired') " <>
            "AND membership_generation > 0 AND revision > 0 " <>
            "AND char_length(start_fingerprint) = 64 " <>
            "AND jsonb_typeof(draft::jsonb) = 'object' " <>
            "AND (status <> 'confirming' OR step = 'confirm')"
      )
    )
  end

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
