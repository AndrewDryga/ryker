defmodule Ryker.Repo.Migrations.FeedbackReviewsAreRatings do
  use Ecto.Migration

  # A review has carried a rating since 2026-09-29 (`RateFinishedRequests`). A review of how a
  # request ended, from before ratings, left no feedback signal on any install (none live on
  # 2026-10-05; the second install began after ratings), so the table stops accepting one, and
  # the category only it filled goes with it (2026-10-04 review). A row of that kind would make
  # this migration fail rather than lose it.

  @kinds ~w(reaction_added reaction_removed message_edited message_deleted asked_again sentiment reviewed)
  @categories ~w(frustrated asked_again edited neutral satisfied)
  @sentiments ~w(satisfied neutral frustrated angry)

  def up do
    drop(constraint(:answer_feedback, :answer_feedback_valid))

    create(
      constraint(:answer_feedback, :answer_feedback_valid,
        check: check(@categories, ~w(good needs_work))
      )
    )
  end

  def down do
    drop(constraint(:answer_feedback, :answer_feedback_valid))

    create(
      constraint(:answer_feedback, :answer_feedback_valid,
        check: check(@categories ++ ["reviewed"], ~w(complete cancelled good needs_work))
      )
    )
  end

  defp check(categories, reviewed) do
    """
    kind IN (#{quoted(@kinds)})
    AND category IN (#{quoted(categories)})
    AND num_nonnulls(episode_id, input_id) = 1
    AND char_length(actor_ref) BETWEEN 1 AND 1024
    AND source ~ '^[a-z0-9_.-]+$' AND char_length(source) BETWEEN 1 AND 64
    AND char_length(source_ref) BETWEEN 1 AND 1024
    AND (note IS NULL OR (char_length(note) >= 1 AND octet_length(note) <= 2048))
    AND COALESCE(
      CASE kind
        WHEN 'sentiment' THEN value IN (#{quoted(@sentiments)})
        WHEN 'reviewed' THEN value IN (#{quoted(reviewed)})
        WHEN 'reaction_added' THEN value ~ '^[a-z0-9_+-]{1,100}$'
        WHEN 'reaction_removed' THEN value ~ '^[a-z0-9_+-]{1,100}$'
        ELSE value IS NULL
      END,
      false
    )
    """
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
