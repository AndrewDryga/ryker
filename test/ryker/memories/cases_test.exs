defmodule Ryker.Memories.CasesTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Event, Origin}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Memories.CaseRecord
  alias Ryker.Memories.Cases
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.ChannelConfigurations
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

  # Correlation claims gather per GitHub item or deployment run, and a case
  # kept all of them, past the 64 its row allows: capture raised inside
  # history retention, which then stopped on the same episode every pass
  # (2026-10-04 review).
  test "work with more occurrence claims than a case holds still keeps its case" do
    {old, _turn} = finished_with_turn!("case:many-claims", @outage)

    for index <- 1..70 do
      Repo.insert!(%Ryker.Episodes.CorrelationClaim{
        episode_id: old.id,
        input_ref: "input:claim-#{index}",
        scope_ref: "slack:TCASES",
        namespace: "deployment",
        occurrence_ref: "deployment:run-#{String.pad_leading("#{index}", 3, "0")}",
        lifecycle_state: :terminal,
        status: :retired,
        established_at: DateTime.add(@now, index, :second)
      })
    end

    assert {:ok, record} = Cases.capture(old.id)
    assert length(record.occurrence_refs) == 64
    assert "deployment:run-070" in record.occurrence_refs
  end

  # Thirty-two checked sources of four and a half kilobytes each made one case
  # larger than a search page may hold, so every search reaching it rolled
  # back, and three such cases overflowed Work's context (2026-10-04 review).
  test "a case of long evidence stays within what one search answer holds" do
    {old, turn} = finished_with_turn!("case:long-evidence", @outage)

    for index <- 1..40 do
      record!(old, turn, "evidence", %{
        "claim_id" => "long-#{index}",
        "observation" => String.duplicate("The replica lag grew again. ", 140),
        "source_name" => "Node exporter #{index}",
        "source_type" => "monitoring"
      })
    end

    assert {:ok, record} = Cases.capture(old.id)
    assert byte_size(Ryker.CanonicalJSON.encode!(record.attempted_actions)) <= 16_384
    assert Enum.all?(record.attempted_actions, &(byte_size(&1) <= 1_024))
  end

  # The gate on 2026-09-26 also found nothing here once: the case was stamped
  # by the host clock and the search's cutoff by the database clock, so a
  # case captured a moment before could fall after the cutoff.
  test "memory search finds a retained case in every scope" do
    old = finished!("case:searchable", @outage)
    assert {:ok, record} = Cases.capture(old.id)

    for scope <- ~w(workspace global current_channel) do
      assert found(old, scope) == [record.case_ref], scope
    end
  end

  # Recall and search matched cases by workspace alone, so work in a DM or a private channel
  # reached every public and Slack Connect channel of the workspace, which notes and topics
  # never do (2026-10-04 review). A case travels from one public channel to another, never
  # out of a private, shared or direct conversation.
  test "a case from a private, shared or direct conversation is recalled only where it happened" do
    channels!(public: ~w(CDEVOPS CPUBLIC), private: ~w(CPRIVATE), shared: ~w(CSHARED))

    public = capture!(finished!("case:public", @outage, channel: "CPUBLIC"))
    private = capture!(finished!("case:private", @outage, channel: "CPRIVATE"))
    _shared = capture!(finished!("case:shared", @outage, channel: "CSHARED"))
    _direct = capture!(finished!("case:direct", @outage, channel: "DALICE"))

    asking = finished!("case:asking", "The #{@outage} again on pgsql-prod-01")
    assert Enum.map(Cases.recall(asking), & &1["case_ref"]) == [public.case_ref]
    assert found(asking, "workspace") == [public.case_ref]

    in_private = finished!("case:asking-private", "The #{@outage} again", channel: "CPRIVATE")
    assert private.case_ref in Enum.map(Cases.recall(in_private), & &1["case_ref"])
    assert private.case_ref in found(in_private, "workspace")
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

  # Routine expiry of a transcript is exactly what a case is meant to
  # outlive; somebody removing their message is not, and no durable record may
  # keep quoting what they withdrew. A case is kept only once its work's
  # history is reclaimed, so a message deleted while its work still ran was
  # quoted by the case kept after it: the deletion found no case to withdraw,
  # and the work's history still held the words (found in review, 2026-09-28).
  test "a message deleted while its work runs is never quoted by the case kept after it" do
    episode = started!("case:deleted-early", @outage)

    revise!(episode, :delete, %{})
    finished = finish!(episode)

    assert {:ok, %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""}} =
             Cases.capture(finished.id)

    assert Cases.recall(finished!("case:after-deletion", "The #{@outage} again")) == []
  end

  # Editing a message takes back the words it replaced, as deleting it takes
  # back all of them: a typo fixed while the work runs gives up its case.
  test "a message edited to say something else while its work runs is never quoted by the case kept after it" do
    episode = started!("case:edited-early", @outage)

    revise!(episode, :edit, %{"text" => "Postgres replica pgsql-prod-02 is lagging"})
    finished = finish!(episode)

    assert {:ok, %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""}} =
             Cases.capture(finished.id)
  end

  # A case outlives its work's history, and with it the record of which work
  # the message joined, so routing no longer takes a later deletion to that
  # work. The case is found by the message identities it keeps.
  test "a message deleted after its work's history was reclaimed withdraws the case kept from it" do
    episode = finished!("case:deleted-late", @outage)
    record = capture!(episode)
    reclaim_history!(episode)

    revise!(episode, :delete, %{})

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)

    assert Cases.recall(finished!("case:after-late-deletion", "The #{@outage} again")) == []
  end

  test "a message edited to say something else after its work's history was reclaimed withdraws the case kept from it" do
    episode = finished!("case:edited-late", @outage)
    record = capture!(episode)
    reclaim_history!(episode)

    revise!(episode, :edit, %{"text" => "Postgres replica pgsql-prod-02 is lagging"})

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)
  end

  # Slack reports a link's preview arriving as an edit with the words
  # untouched; that takes nothing back.
  test "an edit that leaves the words as they were, such as a link preview, withdraws nothing" do
    episode = started!("case:previewed", @outage)

    preview = %{"title" => "pgsql-prod-01", "from_url" => "https://grafana.example.com/d/pg"}
    revise!(episode, :edit, %{"text" => @outage, "attachments" => [preview]})
    finished = finish!(episode)

    assert {:ok, %CaseRecord{status: :active, problem: @outage}} = Cases.capture(finished.id)
  end

  # An alerting app updates its own message as the incident moves on. That is
  # not a person taking back their words, and withdrawing on it would lose the
  # case of nearly every alert.
  test "an app updating its own message withdraws nothing" do
    alerting = %{kind: :app, ref: "AALERTS"}
    episode = started!("case:alert-updated", @outage, actor: alerting)

    revise!(episode, :edit, %{"text" => "RESOLVED: #{@outage}"}, actor: alerting)
    finished = finish!(episode)

    assert {:ok, %CaseRecord{status: :active, problem: @outage}} = Cases.capture(finished.id)
  end

  # Deleting a Slack channel takes back every message in it, as it erases the
  # routing examples that quoted them. The cases built from those messages
  # stayed, quoting a channel that no longer exists (found in review,
  # 2026-09-28).
  test "deleting a Slack channel withdraws the case kept of work there, and no other" do
    episode = finished!("case:channel-deleted", @outage)
    record = capture!(episode)
    reclaim_history!(episode)

    elsewhere = finished!("case:channel-kept", @outage, channel: "CKEPT")
    kept = capture!(elsewhere)
    reclaim_history!(elsewhere)

    delete_channel!("CDEVOPS")

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)

    assert %CaseRecord{status: :active, problem: @outage} =
             Repo.get_by!(CaseRecord, case_ref: kept.case_ref)
  end

  # Work can gather messages from more than one conversation. The case it
  # left is withdrawn when any of them is deleted, not only the one it lived
  # in, long after the work's own record of them is gone.
  test "deleting a Slack channel withdraws the case kept of work one of its messages joined" do
    episode = finished!("case:channel-joined", @outage)

    episode
    |> joined!(
      slack_input!("pgsql-prod-01 also paged in the incident channel", channel: "CPAGES")
    )
    |> finish!()

    record = capture!(episode)
    reclaim_history!(episode)

    delete_channel!("CPAGES")

    assert %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""} =
             Repo.get_by!(CaseRecord, case_ref: record.case_ref)
  end

  test "deleting a Slack channel withdraws the case of work still running there, so it is never built" do
    episode = started!("case:channel-running", @outage)

    delete_channel!("CDEVOPS")
    finished = finish!(episode)

    assert {:ok, %CaseRecord{status: :deleted, problem: "(deleted)", search_text: ""}} =
             Cases.capture(finished.id)
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

  # The person, or the `actor` given, edits or deletes the message the work
  # started from, and Ryker receives it as it receives every message.
  defp revise!(%Episode{} = episode, kind, content, options \\ []) do
    {:ok, revision} =
      SlackInput.new(%{
        actor: Keyword.get(options, :actor, %{kind: :user, ref: "UALICE"}),
        channel_ref: "CDEVOPS",
        content: content,
        event_kind: kind,
        event_ref: "Ev-#{kind}-#{System.unique_integer([:positive])}",
        message_ref: episode.destination_thread_ref,
        occurred_at: DateTime.add(@now, 120, :second),
        revision: 2,
        thread_ref: nil,
        workspace_ref: "TCASES"
      })

    {:ok, %{status: :recorded}} = Inbox.record(revision)
  end

  # Retention reclaims a finished episode's history as it keeps its case: the
  # record of which messages joined it goes.
  defp reclaim_history!(%Episode{} = episode) do
    Repo.delete_all(from(origin in Origin, where: origin.episode_id == ^episode.id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^episode.id))
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

  defp finished!(key, text, options \\ []), do: key |> started!(text, options) |> finish!()

  # Work a message started, a person's unless another `actor` sent it,
  # received as Ryker receives every message and still running.
  defp started!(key, text, options \\ []) do
    input = slack_input!(text, options)
    {:ok, %{status: :recorded}} = Inbox.record(input)
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

    transition.episode
  end

  defp finish!(%Episode{} = episode) do
    {:ok, settled} =
      Episodes.apply(%Command.AcceptResult{
        decision_reason: "The replica was promoted and reads recovered.",
        delivery: :none,
        delivery_ref: nil,
        episode_key: episode.key,
        expected_turn_ref: episode.owner_ref,
        next_turn_ref: nil,
        occurred_at: DateTime.add(@now, 60, :second),
        result_ref: "result:#{episode.id}:#{System.unique_integer([:positive])}"
      })

    settled.episode
  end

  # Another message, received as Ryker receives every message, joins the
  # work, which takes it up again where it lives.
  defp joined!(%Episode{} = episode, input) do
    {:ok, %{status: :recorded}} = Inbox.record(input)

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        episode_id: episode.id,
        episode_key: episode.key,
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{episode.id}:#{System.unique_integer([:positive])}"
      })

    transition.episode
  end

  defp channels!(kinds) do
    channels =
      for {kind, refs} <- kinds, channel_ref <- refs do
        %{channel_ref: channel_ref, private: kind == :private, external_shared: kind == :shared}
      end

    {:ok, _joined} =
      ChannelConfigurations.reconcile_joined("TCASES", channels, %{
        default_environment: nil,
        environments: []
      })
  end

  # The case refs a workspace-wide `search_memory` page finds for `episode`.
  defp found(episode, scope) do
    {:ok, documents} =
      Repo.transaction(fn ->
        MemorySearchPage.read(
          MemorySearchPage.first("pgsql-prod-01", scope),
          5,
          &Cases.search_page(episode, nil, &1)
        )
      end)

    Enum.map(documents, & &1["case_ref"])
  end

  # Slack deletes the channel, as the membership event reports it.
  defp delete_channel!(channel_ref) do
    {:ok, _deleted} =
      ChannelConfigurations.observe_membership(
        %{
          actor_ref: nil,
          channel_ref: channel_ref,
          event_ref: "event:case-channel:#{System.unique_integer([:positive])}",
          kind: :deleted,
          occurred_at: Repo.now!(),
          workspace_ref: "TCASES"
        },
        %{default_environment: nil, environments: []}
      )
  end

  defp slack_input!(text, options \\ []) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      SlackInput.new(%{
        actor: Keyword.get(options, :actor, %{kind: :user, ref: "UALICE"}),
        channel_ref: Keyword.get(options, :channel, "CDEVOPS"),
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
