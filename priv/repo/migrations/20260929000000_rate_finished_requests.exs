defmodule Ryker.Repo.Migrations.RateFinishedRequests do
  use Ecto.Migration

  # Andrew, 2026-09-28, of "Mark how this request ended as reviewed?": "WHAT
  # IS THE POINT OF THIS? i just mark it so what next? this is half baked!"
  # Marking a request reviewed recorded its ending (complete or cancelled)
  # and nothing followed. A person now rates how it went instead: good, or
  # needs work, which makes the request a candidate for Ryker's
  # self-analysis (`Ryker.Improvement`). The review keeps its rating, so the
  # same rating given twice is one; its feedback signal carries it as its
  # value. Reviews recorded before have no rating and keep their ending as
  # their signal's value.
  #
  # Rolling back refuses while any rating is kept: the previous release
  # accepts only an ending.

  @kinds ~w(reaction_added reaction_removed message_edited message_deleted asked_again sentiment reviewed)
  @categories ~w(frustrated asked_again edited neutral satisfied reviewed)
  @sentiments ~w(satisfied neutral frustrated angry)

  def up do
    alter table(:episode_operator_reviews) do
      add(:rating, :text)
    end

    create(
      constraint(:episode_operator_reviews, :episode_operator_review_rating_valid,
        check: "rating IS NULL OR rating IN ('good', 'needs_work')"
      )
    )

    drop(constraint(:answer_feedback, :answer_feedback_valid))

    create(
      constraint(:answer_feedback, :answer_feedback_valid,
        check: check(~w(complete cancelled good needs_work))
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("answer_feedback")}
        WHERE kind = 'reviewed' AND value IN ('good', 'needs_work')
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("episode_operator_reviews")} WHERE rating IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'requests rated good or needs work are kept; the previous release accepts only an ending';
      END IF;
    END
    $$
    """)

    drop(constraint(:answer_feedback, :answer_feedback_valid))

    create(
      constraint(:answer_feedback, :answer_feedback_valid, check: check(~w(complete cancelled)))
    )

    alter table(:episode_operator_reviews) do
      remove(:rating)
    end
  end

  defp check(reviewed) do
    """
    kind IN (#{quoted(@kinds)})
    AND category IN (#{quoted(@categories)})
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

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
