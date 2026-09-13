defmodule Ryker.Repo.Migrations.RecordSelectedWorkInputs do
  use Ecto.Migration

  def change do
    alter table(:episode_work_turns) do
      # The durable inputs this turn was actually built from, recorded beside
      # the frozen submission rather than inside it so the prompt bytes and
      # their fingerprint are unchanged.
      #
      # Null means the selection was never recorded, including every turn that
      # predates this column. Reading must say "Not recorded"; a turn's inputs
      # cannot be reconstructed from today's episode state, and guessing the
      # nearest message in time is how later input gets blamed for earlier work.
      add(:selected_input_refs, {:array, :text})
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_selected_inputs_valid,
        check: """
        selected_input_refs IS NULL
        OR (
          array_length(selected_input_refs, 1) IS NOT NULL
          AND array_length(selected_input_refs, 1) <= 40
          AND array_position(selected_input_refs, NULL) IS NULL
        )
        """
      )
    )
  end
end
