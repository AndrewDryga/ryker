defmodule Ryker.Repo.Migrations.AddPublicationFixLoop do
  use Ecto.Migration

  # Andrew, 2026-09-28, after a refused change's card told him to reply to have
  # it fixed: "why I should ask it myself, it should be automatic feedback loop,
  # agent needs to get errors from CI, fix them without me doing a man in the
  # middle." A refusal the task's own work can fix now goes back to that work,
  # and one that is only the moment it was checked is checked again
  # (`Ryker.Publication.FixLoop`). Both are bounded per publication:
  #
  #   * `fix_rounds` counts the fix turns Ryker started on its own;
  #   * `recheck_rounds` counts the reviews it asked again unchanged;
  #   * `fix_review_generation` is the review generation whose refusal the
  #     latest fix round answers. The round is running while it is still the
  #     publication's current generation, so a new review ends it without
  #     anyone clearing it;
  #   * `review_gate_output` is what the host kept of the current review's
  #     failed gate output for that round (`Ryker.Publication.GateOutput`):
  #     the file it was kept in, or Coop's word that it could not keep it. It
  #     belongs to one review, so a publication with no review has none.
  #
  # Every publication an installation already has starts with no rounds spent
  # and no output. Rolling back forgets only the counts and the output notes;
  # the kept files are ordinary input artifacts.

  def change do
    alter table(:episode_publications) do
      add(:fix_rounds, :bigint, null: false, default: 0)
      add(:recheck_rounds, :bigint, null: false, default: 0)
      add(:fix_review_generation, :bigint)
      add(:review_gate_output, :text)
    end

    create(
      constraint(:episode_publications, :episode_publication_fix_loop_valid,
        check: """
        fix_rounds >= 0 AND recheck_rounds >= 0 \
        AND (fix_review_generation IS NULL OR (fix_review_generation > 0 AND fix_review_generation <= review_generation)) \
        AND (review_gate_output IS NULL OR review_document IS NOT NULL)\
        """
      )
    )
  end
end
