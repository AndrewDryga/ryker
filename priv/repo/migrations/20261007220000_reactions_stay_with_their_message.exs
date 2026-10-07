defmodule Ryker.Repo.Migrations.ReactionsStayWithTheirMessage do
  use Ecto.Migration

  # A reaction names the one message of Ryker's it is on, and was copied onto
  # every training example of its request: one on the third turn's reply
  # labelled every turn and every routing decision (2026-10-04 review; 10 of
  # the 14 reaction copies on 2026-10-07). New copies follow the message
  # (`Ryker.WorkExamples.Feedback.Query`, `Ryker.RoutingExamples.Feedback.Query`).
  # A copy made before goes only where the record still shows that the turn
  # or the decision did not send that message; where it no longer shows what
  # they sent, the copy stays.

  def up do
    # A turn sends its reply and the updates it posts.
    execute("""
    DELETE FROM work_example_feedback AS copy
    USING answer_feedback AS signal, work_examples AS example
    WHERE copy.signal_id = signal.id
      AND copy.example_id = example.id
      AND signal.message_ref IS NOT NULL
      AND EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.id = example.turn_id)
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_turns AS turn
        WHERE turn.id = example.turn_id
          AND turn.external_receipt::jsonb->>'message_ref' = signal.message_ref
      )
      AND NOT EXISTS (
        SELECT 1 FROM platform_actions AS action
        WHERE action.turn_id = example.turn_id
          AND action.external_receipt::jsonb->>'message_ref' = signal.message_ref
      )
    """)

    # A decision sends messages of its own only as a quick reply or a
    # reaction; any other sent none to react to.
    execute("""
    DELETE FROM routing_example_feedback AS copy
    USING answer_feedback AS signal, routing_examples AS example, ingress_inbox_entries AS input
    WHERE copy.signal_id = signal.id
      AND copy.example_id = example.id
      AND input.id = example.input_id
      AND signal.message_ref IS NOT NULL
      AND (
        input.decision_action NOT IN ('quick_reply', 'react')
        OR (
          EXISTS (
            SELECT 1 FROM delivery_routing_responses AS response
            WHERE response.input_id = example.input_id
          )
          AND NOT EXISTS (
            SELECT 1 FROM delivery_routing_responses AS response
            WHERE response.input_id = example.input_id
              AND response.external_receipt::jsonb->>'message_ref' = signal.message_ref
          )
        )
      )
    """)
  end

  def down, do: :ok
end
