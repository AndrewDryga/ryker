defmodule Ryker.WorkExamples.ReactionsMigrationTest do
  # A reaction was copied onto every training example of its request: one on
  # the third turn's reply labelled every turn and every routing decision
  # (2026-10-04 review; 10 of the 14 reaction copies on 2026-10-07). The
  # copies made before stay only with the turn or decision that sent the
  # message the reaction is on.
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.RoutingExamples.Example, as: RoutingExample
  alias Ryker.RoutingExamples.Feedback, as: RoutingCopy
  alias Ryker.WorkExamples.Example, as: WorkExample
  alias Ryker.WorkExamples.Feedback, as: WorkCopy

  @version 20_261_007_220_000
  @workspace "TREACTIONCOPIES"
  @now ~U[2026-10-01 12:00:00.000000Z]

  test "a reaction copied before stays only with the turn or decision that sent its message" do
    question = message!("1790600100.000100", "Is the staging database healthy?")
    reply = Answers.work_reply!(question, "Production is healthy.", "1790600100.000200", @now)
    work_example = work_example!(reply)
    started = routing_example!(question)

    on_reply = reaction!({:episode, reply.episode.id}, "on-reply", "1790600100.000200")
    elsewhere = reaction!({:episode, reply.episode.id}, "elsewhere", "1790600999.000200")
    rated = rating!({:episode, reply.episode.id})

    for signal <- [on_reply, elsewhere, rated], do: copy!(WorkCopy, work_example, signal)
    for signal <- [on_reply, rated], do: copy!(RoutingCopy, started, signal)

    quick = message!("1790600200.000100", "Count to three")
    Answers.quick_reply!(quick, "1, 2, 3", "1790600200.000200", @now)
    answered = routing_example!(quick)
    on_quick = reaction!({:input, quick.id}, "on-quick", "1790600200.000200")
    off_quick = reaction!({:input, quick.id}, "off-quick", "1790600888.000200")
    for signal <- [on_quick, off_quick], do: copy!(RoutingCopy, answered, signal)

    assert :ok = migrate_down(@version)
    assert :ok = migrate_up(@version)

    assert copies(WorkCopy, work_example) == Enum.sort([on_reply.id, rated.id])
    assert copies(RoutingCopy, started) == [rated.id]
    assert copies(RoutingCopy, answered) == [on_quick.id]
  end

  defp message!(ts, text) do
    Answers.slack_message!(
      workspace: @workspace,
      channel: "CCOPIES",
      actor: "UALICE",
      text: text,
      ts: ts
    )
  end

  defp reaction!(request, event, message_ref) do
    assert {:ok, %{signal: signal}} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:copies-#{event}",
               occurred_at: @now,
               message_ref: message_ref,
               request: request
             })

    signal
  end

  defp rating!(request) do
    assert {:ok, %{signal: signal}} =
             Feedback.record(%{
               kind: :reviewed,
               value: "needs_work",
               note: "It checked production.",
               actor_ref: "control-plane:local",
               source: "control_plane",
               source_ref: "control-plane-review:copies",
               occurred_at: @now,
               request: request
             })

    signal
  end

  defp work_example!(%{episode: episode, turn: turn}) do
    Repo.insert!(%WorkExample{
      id: Ecto.UUID.generate(),
      turn_id: turn.id,
      episode_id: episode.id,
      episode_ref: episode.key,
      execution_mode: :live,
      briefing: "b",
      context: %{},
      output_schema: %{},
      trajectory: [],
      result: "r",
      rejected_results: [],
      outcome: %{},
      usage: %{},
      settled_at: @now
    })
  end

  defp routing_example!(input) do
    Repo.insert!(%RoutingExample{
      id: Ecto.UUID.generate(),
      input_id: input.id,
      episode_id: input.episode_id,
      source_identity: String.duplicate("a", 64),
      transport: "slack",
      conversation_ref: input.destination_conversation_ref,
      execution_mode: :live,
      policy: "routing",
      policy_digest: String.duplicate("a", 64),
      prompt: "p",
      output_schema: %{},
      answer: "a",
      decision: %{},
      outcome: %{},
      usage: %{},
      rejected_answers: [],
      decided_at: @now
    })
  end

  defp copy!(schema, example, signal) do
    Repo.insert!(
      struct(schema, %{
        id: Ecto.UUID.generate(),
        example_id: example.id,
        signal_id: signal.id,
        kind: Atom.to_string(signal.kind),
        value: signal.value,
        category: Atom.to_string(signal.category),
        occurred_at: signal.occurred_at
      })
    )
  end

  defp copies(schema, example) do
    Repo.all(
      from(copy in schema,
        where: copy.example_id == ^example.id,
        order_by: copy.signal_id,
        select: copy.signal_id
      )
    )
  end
end
