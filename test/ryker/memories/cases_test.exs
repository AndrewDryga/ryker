defmodule Ryker.Memories.CasesTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Origin}
  alias Ryker.Ingress.Input
  alias Ryker.Memories.CaseRecord
  alias Ryker.Memories.Cases
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Custody

  @now ~U[2026-09-11 12:00:00.000000Z]
  @outage "Postgres primary pgsql-prod-01 is unreachable and replication is stalled"

  test "a matching outage a year later recalls the old case" do
    # Everything learned from an incident used to expire with the transcript
    # that produced it, so the same outage twelve months later started from
    # nothing and rediscovered the same fix from scratch.
    old = finished!("case:last-year", @outage)
    assert {:ok, record} = Cases.capture(old.id)
    age!(record, 365)

    current = finished!("case:this-year", "The #{@outage} again on pgsql-prod-01")

    assert [recalled] = Cases.recall(current)
    assert recalled["case_ref"] == record.case_ref
    assert recalled["problem"] =~ "pgsql-prod-01"

    # Recall is history, not a reopening: the year-old work stays finished.
    assert Repo.get!(Episode, old.id).state == :complete
  end

  # Every "Search saved knowledge" call failed on 2026-09-26: the cases lane
  # put its scope filter inside a boolean where Ecto refuses a dynamic
  # expression, so the query raised, the tool answered nothing, and every
  # answer told the person earlier saved context could not be checked.
  # QA, 2026-09-26: every saved case kept its problem and outcome but never
  # its cause or what was tried. Capture read a "summary" field that neither
  # a finding ("what") nor evidence ("observation") has, so a year-old case
  # recalled the outage without the fix it had found.
  test "a saved case keeps what was found to cause it and what was checked" do
    {old, turn} = finished_with_turn!("case:with-findings", @outage)

    record!(old, turn, "finding", %{
      "status" => "explained",
      "what" => "Replication stalled because the WAL volume on pgsql-prod-01 filled up.",
      "reason" => "Disk usage reached 100% at 08:02, the minute replication stopped."
    })

    record!(old, turn, "evidence", %{
      "claim_id" => "wal-disk",
      "observation" => "The WAL volume on pgsql-prod-01 was 100% full at 08:02.",
      "source_name" => "Node exporter",
      "source_type" => "monitoring"
    })

    assert {:ok, record} = Cases.capture(old.id)
    assert record.cause =~ "WAL volume on pgsql-prod-01 filled up"
    assert Enum.any?(record.attempted_actions, &(&1 =~ "was 100% full at 08:02"))

    current = finished!("case:recall-cause", "The #{@outage} again on pgsql-prod-01")
    assert [recalled] = Cases.recall(current)
    assert recalled["cause"] =~ "WAL volume"
  end

  # The gate on 2026-09-26 also found nothing here once: the case was stamped
  # by the host clock and the search's cutoff by the database clock, so a
  # case captured a moment before could fall after the cutoff.
  test "memory search finds a retained case in every scope" do
    old = finished!("case:searchable", @outage)
    assert {:ok, record} = Cases.capture(old.id)

    context = %{
      conversation_ref: old.destination_conversation_ref,
      repository: nil,
      workspace_ref: record.workspace_ref
    }

    for scope <- ~w(workspace global current_channel) do
      {:ok, found} =
        Repo.transaction(fn ->
          MemorySearchPage.read(
            MemorySearchPage.first("pgsql-prod-01", scope),
            5,
            &Cases.search_page(context, &1)
          )
        end)

      assert [%{"case_ref" => case_ref}] = found, scope
      assert case_ref == record.case_ref
    end
  end

  test "explicit deletion erases the case beyond recall" do
    # A governed deletion must reach the search row too. Leaving the text there
    # would resurrect exactly what was deleted.
    record = finished!("case:deleted", @outage) |> capture!()

    assert {:ok, %CaseRecord{status: :deleted}} = Cases.delete(record.case_ref)

    current = finished!("case:after-deletion", "The #{@outage} again")
    assert Cases.recall(current) == []

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)
  end

  test "deleting the original message redacts the case built from it" do
    # Routine expiry of a transcript is exactly what a case is meant to outlive.
    # Somebody removing their message is not: no durable record may keep
    # quoting text that was explicitly withdrawn.
    episode = finished!("case:withdrawn", @outage)
    record = capture!(episode)

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
    assert {:ok, %CaseRecord{status: :deleted}} = Cases.delete(record.case_ref)

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
        workspace_ref: "TCASES"
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

  # A finished episode whose work turn exists, for records written during it.
  defp finished_with_turn!(key, text) do
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
    {:ok, _session} = Custody.pin_episode(id, "cases", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("cases:#{id}", 60, :work)

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

    {settled.episode, claim.turn}
  end

  defp record!(%Episode{} = episode, turn, kind, payload) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Record{
      id: id,
      episode_id: episode.id,
      turn_id: turn.id,
      ref: "#{kind}:#{id}",
      operation_id: "operation:#{id}",
      kind: kind,
      status: :open,
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload)
    })
  end

  defp capture!(%Episode{} = episode) do
    {:ok, record} = Cases.capture(episode.id)
    record
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
        workspace_ref: "TCASES"
      })

    input
  end
end
