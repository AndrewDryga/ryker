defmodule Ryker.Repo.Migrations.MoveShippedModelDefaultsToTheNewest do
  use Ecto.Migration

  # Andrew, 2026-11-21, of Settings › Models showing gpt-5.6-sol: "default models should be
  # latest not 5.6". A kind of work still on exactly the model Ryker shipped moves to the newest
  # model of its family: GPT-6.2 Sol, and GPT-6.1 Terra for conversation. A list an owner changed
  # keeps their choice, and new installs start on the newest through the column defaults. The
  # worker runs both from Codex 0.166.0 (Coop 2ffe1516 ships 0.170.0), and both cost less than
  # the models they replace.
  @moves [
    routing: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"},
    conversation: {"codex:gpt-5.6-terra/medium@default", "codex:gpt-6.1-terra/medium@default"},
    standard: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"},
    deep: {"codex:gpt-5.6-sol/xhigh@default", "codex:gpt-6.2-sol/xhigh@default"},
    contributor: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"},
    schedule: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"},
    incident: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"},
    learning: {"codex:gpt-5.6-sol/medium@default", "codex:gpt-6.2-sol/medium@default"}
  ]

  def up do
    for {kind, {shipped, newest}} <- @moves do
      execute("""
      ALTER TABLE #{qualified("work_settings")}
        ALTER COLUMN #{kind}_models SET DEFAULT ARRAY['#{newest}']::text[]
      """)

      execute("""
      UPDATE #{qualified("work_settings")} SET #{kind}_models = ARRAY['#{newest}']::text[]
      WHERE #{kind}_models = ARRAY['#{shipped}']::text[]
      """)
    end
  end

  # Rolling back restores the defaults; a list this migration moved stays on the newer model,
  # which the previous release runs as well.
  def down do
    for {kind, {shipped, _newest}} <- @moves do
      execute("""
      ALTER TABLE #{qualified("work_settings")}
        ALTER COLUMN #{kind}_models SET DEFAULT ARRAY['#{shipped}']::text[]
      """)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
