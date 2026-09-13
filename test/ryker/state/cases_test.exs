defmodule Ryker.State.CasesTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Origin}
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.State.{CaseLesson, CaseRecord, Cases}

  @now ~U[2026-09-11 12:00:00.000000Z]
  @outage "Postgres primary pgsql-prod-01 is unreachable and replication is stalled"

  test "a matching outage a year later recalls the old case and its reviewed fix" do
    # Everything learned from an incident used to expire with the transcript
    # that produced it, so the same outage twelve months later started from
    # nothing and rediscovered the same fix from scratch.
    old = finished!("case:last-year", @outage)
    assert {:ok, record} = Cases.capture(old.id)
    approve!(record, "The primary is unreachable and the replica is healthy")
    age!(record, 365)

    current = finished!("case:this-year", "The #{@outage} again on pgsql-prod-01")

    assert [recalled] = Cases.recall(current)
    assert recalled["case_ref"] == record.case_ref
    assert [lesson] = recalled["lessons"]
    assert lesson["steps"] =~ "Promote the healthy replica"

    # Recall is history, not a reopening: the year-old work stays finished.
    assert Repo.get!(Episode, old.id).state == :complete
  end

  test "an unreviewed lesson is never presented as a reusable procedure" do
    # A draft is an extraction, not guidance. Presenting it as approved would
    # make an unreviewed command list look like a proven fix.
    case_record = finished!("case:draft", @outage) |> capture!()

    assert {:ok, _draft} =
             Cases.draft_lesson(%{
               case_ref: case_record.case_ref,
               conditions: "Primary unreachable",
               revision: 1,
               steps: "Promote the healthy replica after confirming its lag"
             })

    assert Cases.approved_lessons(case_record.id) == []
  end

  test "explicit deletion erases the case and its lessons beyond recall" do
    # A governed deletion must reach every derived record. Leaving the text in
    # a lesson or a search row would resurrect exactly what was deleted.
    record = finished!("case:deleted", @outage) |> capture!()
    approve!(record, "Promote the healthy replica")

    assert {:ok, 2} = Cases.delete(record.case_ref)

    current = finished!("case:after-deletion", "The #{@outage} again")
    assert Cases.recall(current) == []

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)

    assert [%CaseLesson{status: :removed, steps: "(removed)"}] =
             Repo.all(CaseLesson) |> Enum.filter(&(&1.case_id == record.id))
  end

  test "deleting the original message redacts the case built from it" do
    # Routine expiry of a transcript is exactly what a case is meant to outlive.
    # Somebody removing their message is not: no durable record may keep
    # quoting text that was explicitly withdrawn.
    episode = finished!("case:withdrawn", @outage)
    record = capture!(episode)
    approve!(record, "Primary unreachable")

    withdraw!(episode)

    assert %CaseRecord{status: :deleted, problem: "(deleted)"} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)

    assert Cases.recall(finished!("case:after-withdrawal", "The #{@outage} again")) == []
  end

  test "repeated capture keeps one case per intended revision" do
    # Close, reopen, cleanup and restart events all reach capture. Appending a
    # row for each would grow a record that feeds on its own output.
    episode = finished!("case:repeat", @outage)

    assert {:ok, first} = Cases.capture(episode.id)
    assert {:ok, again} = Cases.capture(episode.id)

    assert again.id == first.id
    assert again.content_fingerprint == first.content_fingerprint
    assert Repo.aggregate(CaseRecord, :count) == 1
  end

  test "a deleted case is not rebuilt by the next capture" do
    # Otherwise ordinary retention would resurrect a governed deletion the very
    # next time it ran over the same finished episode.
    record = finished!("case:deleted-then-captured", @outage) |> capture!()
    assert {:ok, _count} = Cases.delete(record.case_ref)

    assert {:ok, %CaseRecord{status: :deleted}} = Cases.capture(record.episode_id)
  end

  defp withdraw!(%Episode{} = episode) do
    [native_input_id] =
      Repo.all(
        from(origin in Origin,
          where: origin.episode_id == ^episode.id,
          select: origin.native_input_id
        )
      )

    {:ok, deletion} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CDEVOPS",
        content: %{},
        event_kind: :delete,
        event_ref: "Ev-delete-#{System.unique_integer([:positive])}",
        message_ref: episode.destination_thread_ref,
        occurred_at: DateTime.add(@now, 120, :second),
        revision: 2,
        thread_ref: episode.destination_thread_ref,
        workspace_ref: "TROUTE"
      })

    {:ok, _transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(deletion),
        destination: deletion.destination,
        episode_id: episode.id,
        episode_key: episode.key,
        linked_episode_id: nil,
        native_input_id: native_input_id,
        occurred_at: deletion.occurred_at,
        payload: deletion |> Input.document() |> Map.put("native_input_id", native_input_id),
        revision: 2,
        turn_ref: "turn:#{episode.id}"
      })
  end

  defp capture!(%Episode{} = episode) do
    {:ok, record} = Cases.capture(episode.id)
    record
  end

  defp approve!(%CaseRecord{} = record, conditions) do
    {:ok, draft} =
      Cases.draft_lesson(%{
        case_ref: record.case_ref,
        conditions: conditions,
        revision: 1,
        steps: "Promote the healthy replica after confirming its replication lag",
        verification: "Read traffic recovers and the new primary accepts writes"
      })

    {:ok, approved} =
      Cases.approve_lesson(draft.lesson_ref, "slack:user:UOPERATOR", "review:#{record.case_ref}")

    approved
  end

  defp age!(%CaseRecord{} = record, days) do
    at = DateTime.add(@now, -days * 24 * 60 * 60, :second)
    record |> Ecto.Changeset.change(closed_at: at, updated_at: at) |> Repo.update!()
  end

  defp finished!(key, text) do
    input = slack_input!(text)
    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    episode = transition.episode

    {:ok, settled} =
      Episodes.apply(%Command.AcceptResult{
        decision_reason: "The replica was promoted and reads recovered.",
        delivery: :none,
        delivery_ref: nil,
        episode_key: episode.key,
        expected_turn_ref: episode.owner_ref,
        next_turn_ref: nil,
        occurred_at: DateTime.add(@now, 60, :second),
        result_ref: "result:#{id}"
      })

    settled.episode
  end

  defp slack_input!(text) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CDEVOPS",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{unique}",
        message_ref: "#{1_789_000_000 + unique}.000200",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TROUTE"
      })

    input
  end
end
