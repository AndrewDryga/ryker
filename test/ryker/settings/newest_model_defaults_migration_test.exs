defmodule Ryker.Settings.NewestModelDefaultsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.TestMigrations

  @version 20_261_121_000_400
  @lists ~w(routing_models conversation_models standard_models deep_models learning_models)

  # Andrew, 2026-11-21, of Settings › Models showing gpt-5.6-sol on an install set up the day
  # before: "default models should be latest not 5.6". A kind of work still on the model Ryker
  # shipped moves to the newest one; a model an owner chose, and a fallback they added, stay.
  test "an upgrade moves the shipped models to the newest and keeps every model an owner chose" do
    in_scratch_schema("newest_model_defaults", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))
      installation!(repo, prefix, "host-models")

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.work_settings (id, standard_models, deep_models)
        VALUES ('host-models', ARRAY['codex:gpt-5.6-sol/high@default'],
                ARRAY['codex:gpt-5.6-sol/xhigh@default', 'claude:claude-opus-5-5/high@work'])
        """,
        []
      )

      assert @version in migrate!(repo, prefix, @version)

      assert lists(repo, prefix, "host-models") == [
               ["codex:gpt-6.2-sol/medium@default"],
               ["codex:gpt-6.1-terra/medium@default"],
               ["codex:gpt-5.6-sol/high@default"],
               ["codex:gpt-5.6-sol/xhigh@default", "claude:claude-opus-5-5/high@work"],
               ["codex:gpt-6.2-sol/medium@default"]
             ]

      # A new install starts on the newest models.
      SQL.query!(repo, "DELETE FROM #{prefix}.work_settings", [])
      SQL.query!(repo, "INSERT INTO #{prefix}.work_settings (id) VALUES ('host-models')", [])

      assert lists(repo, prefix, "host-models") == [
               ["codex:gpt-6.2-sol/medium@default"],
               ["codex:gpt-6.1-terra/medium@default"],
               ["codex:gpt-6.2-sol/medium@default"],
               ["codex:gpt-6.2-sol/xhigh@default"],
               ["codex:gpt-6.2-sol/medium@default"]
             ]
    end)
  end

  defp installation!(repo, prefix, host) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.installation_settings (host_ref, revision, saved_by, saved_at, inserted_at)
      VALUES ($1, 1, 'operator:test', now(), now())
      """,
      [host]
    )
  end

  defp lists(repo, prefix, host) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        "SELECT #{Enum.join(@lists, ", ")} FROM #{prefix}.work_settings WHERE id = $1",
        [host]
      )

    row
  end
end
