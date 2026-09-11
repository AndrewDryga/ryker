defmodule Responder.Repo.Migrations.RecordWorkSelectionLedger do
  use Ecto.Migration

  # What the builder actually selected for this turn, recorded beside the frozen
  # submission rather than inside it so the prompt bytes and their fingerprint
  # are unchanged.
  #
  # The frozen context keeps the items that reached the model and one omitted
  # total. It cannot say how many inputs were eligible, how many fell outside
  # the history window and how many were cut to fit, and recomputing those from
  # today's episode would blame the current queue for a historical selection.
  # Null means nobody recorded it, including every turn that predates this
  # column; reading must say so rather than render a zero.
  def up do
    alter table(:episode_work_turns) do
      add(:selection_ledger, :text)
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_selection_ledger_valid,
        check: "selection_ledger IS NULL OR octet_length(selection_ledger) BETWEEN 2 AND 4096"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_turns")}
        WHERE selection_ledger IS NOT NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'work selection ledgers have data';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_work_turns, :episode_work_turn_selection_ledger_valid))

    alter table(:episode_work_turns) do
      remove(:selection_ledger)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
