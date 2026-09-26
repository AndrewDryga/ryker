defmodule Ryker.Repo.Migrations.RoutingAnswersSimpleMessages do
  use Ecto.Migration

  # Routing can answer a simple message itself ("hi", "thanks", "are you
  # there?") in a sentence or two instead of starting Work, the way it could
  # already react with an emoji. Both are what routing sends without Work, so
  # the reaction custody becomes routing responses of two kinds: a reaction on
  # the message, or a short message beside it. Every reaction keeps its row.
  #
  # Rolling back would leave the quick replies nowhere to live, so `down`
  # refuses while any exists.
  def up do
    rename(table(:delivery_reactions), to: table(:delivery_routing_responses))

    rename_constraint("delivery_reactions_pkey", "delivery_routing_responses_pkey")

    rename_constraint(
      "delivery_reactions_input_id_fkey",
      "delivery_routing_responses_input_id_fkey"
    )

    rename_constraint(
      "delivery_reaction_custody_valid",
      "delivery_routing_response_custody_valid"
    )

    rename_constraint(
      "delivery_reaction_identity_valid",
      "delivery_routing_response_identity_valid"
    )

    rename_constraint(
      "delivery_reactions_retry_generation_check",
      "delivery_routing_responses_retry_generation_check"
    )

    rename_index("delivery_reactions_claimable", "delivery_routing_responses_claimable")

    rename_index(
      "delivery_reactions_delivery_ref_index",
      "delivery_routing_responses_delivery_ref_index"
    )

    rename_index(
      "delivery_reactions_input_id_index",
      "delivery_routing_responses_input_id_index"
    )

    drop(constraint(:delivery_routing_responses, :delivery_reaction_document_valid))

    alter table(:delivery_routing_responses) do
      add(:kind, :text, null: false, default: "reaction")
    end

    execute(
      "ALTER TABLE #{qualified("delivery_routing_responses")} ALTER COLUMN kind DROP DEFAULT"
    )

    create(
      constraint(:delivery_routing_responses, :delivery_routing_response_document_valid,
        check: """
        jsonb_typeof(document::jsonb) = 'object'
        AND (
          (
            kind = 'reaction'
            AND document::jsonb ? 'emoji_name'
            AND (document::jsonb - 'emoji_name') = '{}'::jsonb
            AND jsonb_typeof(document::jsonb -> 'emoji_name') = 'string'
            AND char_length(document::jsonb ->> 'emoji_name') > 0
          )
          OR
          (
            kind = 'message'
            AND document::jsonb ? 'message'
            AND (document::jsonb - 'message') = '{}'::jsonb
            AND jsonb_typeof(document::jsonb -> 'message') = 'string'
            AND char_length(document::jsonb ->> 'message') > 0
          )
        )
        """
      )
    )

    replace_decision_checks(~w(start_episode continue_episode reply quick_reply react ignore))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("delivery_routing_responses")} WHERE kind <> 'reaction')
        OR EXISTS (SELECT 1 FROM #{qualified("ingress_inbox_entries")} WHERE decision_action = 'quick_reply')
        OR EXISTS (SELECT 1 FROM #{qualified("standing_assignment_runs")} WHERE decision_action = 'quick_reply')
      THEN
        RAISE EXCEPTION 'quick replies exist; rolling back would leave them nowhere to live';
      END IF;
    END
    $$
    """)

    replace_decision_checks(~w(start_episode continue_episode reply react ignore))

    drop(constraint(:delivery_routing_responses, :delivery_routing_response_document_valid))

    alter table(:delivery_routing_responses) do
      remove(:kind)
    end

    create(
      constraint(:delivery_routing_responses, :delivery_reaction_document_valid,
        check: """
        jsonb_typeof(document::jsonb) = 'object'
        AND document::jsonb ? 'emoji_name'
        AND (document::jsonb - 'emoji_name') = '{}'::jsonb
        AND jsonb_typeof(document::jsonb -> 'emoji_name') = 'string'
        AND char_length(document::jsonb ->> 'emoji_name') > 0
        """
      )
    )

    rename_index(
      "delivery_routing_responses_input_id_index",
      "delivery_reactions_input_id_index"
    )

    rename_index(
      "delivery_routing_responses_delivery_ref_index",
      "delivery_reactions_delivery_ref_index"
    )

    rename_index("delivery_routing_responses_claimable", "delivery_reactions_claimable")

    rename_constraint(
      "delivery_routing_responses_retry_generation_check",
      "delivery_reactions_retry_generation_check"
    )

    rename_constraint(
      "delivery_routing_response_identity_valid",
      "delivery_reaction_identity_valid"
    )

    rename_constraint(
      "delivery_routing_response_custody_valid",
      "delivery_reaction_custody_valid"
    )

    rename_constraint(
      "delivery_routing_responses_input_id_fkey",
      "delivery_reactions_input_id_fkey"
    )

    rename_constraint("delivery_routing_responses_pkey", "delivery_reactions_pkey")

    rename(table(:delivery_routing_responses), to: table(:delivery_reactions))
  end

  # The decision checks name every action routing may take; a quick reply,
  # like a reaction, is decided without an episode.
  defp replace_decision_checks(actions) do
    without_episode = Enum.filter(actions, &(&1 in ~w(quick_reply react ignore)))
    with_episode = actions -- without_episode

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_decision_matches_status))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_decision_matches_status,
        check: """
        (
          status = 'pending'
          AND decision_ref IS NULL AND decision_fingerprint IS NULL
          AND decision_action IS NULL AND decision_document IS NULL AND episode_id IS NULL
        )
        OR
        (
          status = 'blocked'
          AND decision_ref IS NULL AND decision_fingerprint IS NULL
          AND decision_action IS NULL AND decision_document IS NULL AND episode_id IS NULL
          AND char_length(last_error_code) > 0 AND char_length(last_error_detail) > 0
        )
        OR
        (
          status = 'decided'
          AND char_length(decision_ref) > 0 AND char_length(decision_fingerprint) = 64
          AND decision_action IN (#{list(actions)})
          AND decision_document IS NOT NULL
          AND (
            (decision_action IN (#{list(without_episode)}) AND episode_id IS NULL)
            OR
            (decision_action IN (#{list(with_episode)}) AND episode_id IS NOT NULL)
          )
        )
        OR
        (
          status = 'superseded'
          AND char_length(decision_ref) > 0 AND char_length(decision_fingerprint) = 64
          AND decision_action IN ('start_episode', 'continue_episode', 'reply', 'react', 'ignore')
          AND decision_document IS NOT NULL AND episode_id IS NOT NULL
          AND last_error_code = 'stale_input_revision'
          AND char_length(last_error_detail) > 0
        )
        """
      )
    )

    drop(constraint(:standing_assignment_runs, :standing_assignment_run_valid))

    create(
      constraint(:standing_assignment_runs, :standing_assignment_run_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256
        AND char_length(source_input_ref) BETWEEN 1 AND 1024
        AND char_length(source_event_ref) BETWEEN 1 AND 1024
        AND outcome IN ('pending', 'decided', 'superseded')
        AND (
          (outcome = 'pending' AND decision_action IS NULL AND decision_ref IS NULL AND episode_id IS NULL)
          OR
          (
            outcome IN ('decided', 'superseded')
            AND decision_action IN (#{list(actions)})
            AND char_length(decision_ref) BETWEEN 1 AND 1024
            AND (
              (decision_action IN (#{list(with_episode)}) AND episode_id IS NOT NULL)
              OR
              (decision_action IN (#{list(without_episode)}) AND episode_id IS NULL)
            )
          )
        )
        """
      )
    )
  end

  defp list(actions), do: Enum.map_join(actions, ", ", &"'#{&1}'")

  defp rename_constraint(from, to) do
    execute(
      "ALTER TABLE #{qualified("delivery_routing_responses")} RENAME CONSTRAINT #{from} TO #{to}"
    )
  end

  defp rename_index(from, to), do: execute("ALTER INDEX #{qualified(from)} RENAME TO #{to}")

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
