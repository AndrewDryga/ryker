defmodule Ryker.Repo.Migrations.DropOriginCorrections do
  use Ecto.Migration

  # Every origin has been written effective with no correction since origins began, and nothing
  # ever corrected one, so every "effective" filter read a constant (2026-10-04 review; all 134
  # live rows).
  @valid """
  char_length(input_ref) > 0 AND sequence > 0 AND revision > 0 AND char_length(actor_ref) > 0
    AND char_length(transport) > 0 AND char_length(conversation_ref) > 0
    AND origin_kind IN ('channel_root', 'thread_reply', 'conversation')
  """

  def up do
    execute("ALTER TABLE #{table()} DROP CONSTRAINT episode_input_origin_valid")
    execute("ALTER TABLE #{table()} ADD CONSTRAINT episode_input_origin_valid CHECK (#{@valid})")

    alter table(:episode_input_origins) do
      remove(:effective)
      remove(:correction_ref)
    end
  end

  def down do
    alter table(:episode_input_origins) do
      add(:effective, :boolean, null: false, default: true)
      add(:correction_ref, :text)
    end

    execute("ALTER TABLE #{table()} DROP CONSTRAINT episode_input_origin_valid")

    execute("""
    ALTER TABLE #{table()} ADD CONSTRAINT episode_input_origin_valid
      CHECK (#{@valid} AND (effective OR correction_ref IS NOT NULL))
    """)
  end

  defp table do
    schema = String.replace(prefix() || "public", "\"", "\"\"")
    ~s("#{schema}".episode_input_origins)
  end
end
