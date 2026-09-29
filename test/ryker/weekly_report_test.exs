defmodule Ryker.WeeklyReportTest do
  @moduledoc """
  The weekly report says how Ryker's week went, the way a teammate says it
  at a standup, from the database alone. Every number and name in it comes
  from rows, so each test seeds known rows for this week and the weeks
  before, and holds the report to the exact words it must say. The model
  never writes a word of it.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.ControlPlane.FailureExplanation
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelMembership, Names}
  alias Ryker.WeeklyReport

  @actor "control-plane:local"
  @base "http://ryker.test"

  setup do
    {:ok, _settings} = Settings.initialize(@actor)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:microsecond, {0, 6})
    workspace = "TREPORT#{System.unique_integer([:positive])}"
    %{now: now, workspace: workspace}
  end

  # "Empty parts say nothing rather than vanishing": a part that is left out
  # reads as a good week, and a quiet week is exactly when a missing
  # instrument goes unnoticed.
  test "a quiet week says so, and Done, Still open and Stuck say Nothing rather than disappear" do
    week = %{
      from: ~U[2026-09-14 09:00:00.000000Z],
      to: ~U[2026-09-21 09:00:00.000000Z],
      timezone: "Etc/UTC"
    }

    report = WeeklyReport.compose(week, now: week.to, base_url: @base)

    assert report.text == """
           **Weekly update**
           Mon 14 Sep to Mon 21 Sep

           It was a quiet week: nobody asked me for anything.

           **Done**
           Nothing.

           **Still open**
           Nothing.

           **Stuck**
           Nothing is stuck.\
           """

    assert Enum.map(report.sections, & &1.title) == ["Done", "Still open", "Stuck"]
    assert report.closing == nil
  end

  # Andrew, 2026-09-28, of the report this replaced: "make it more like a
  # human would say on weekly standup, what work it did, how much work
  # handled, not going too deep into metrics that are not about value
  # delivered". It counted messages read, routing corrections and model
  # cost, and never said what Ryker got done.
  test "the report says how much work Ryker did and what it got done, naming only requests from a public channel",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CWORKPUBLIC")
    private = private_channel!(workspace, "CWORKPRIVATE")

    # Finished this week, the one with a draft PR first.
    checkout =
      PublicationFixture.published!("weekly-#{workspace}",
        conversation_ref: public,
        github_repository: "acme/checkout",
        pull_request_number: 4
      )

    title!(checkout.episode.id, "Fix the checkout alert")

    staging = work_request!(workspace, public, "1790100001.000100", "Is staging healthy?")
    title!(staging.id, "Check staging health")

    # The same title twice in one channel is one line; the other is one more.
    again = work_request!(workspace, public, "1790100002.000100", "Is staging healthy now?")
    title!(again.id, "Check staging health")

    payroll =
      work_request!(workspace, private, "1790100003.000100", "What are the payroll totals?")

    title!(payroll.id, "Payroll totals")

    # Asked two weeks ago and answered again this week: this week's work.
    older = work_request!(workspace, public, "1790100004.000100", "Rotate the API key")
    title!(older.id, "Rotate the API key")
    backdate!(Episode, older.id, DateTime.add(now, -14, :day))

    # Open: waiting for someone and watching for an update; stopped is neither.
    waiting = request!(public, :waiting_for_input, "Add a smoke test", now)

    watching =
      request!(public, :waiting_for_event, "Track Terraform run 42", DateTime.add(now, -60))

    _stopped = request!(public, :cancelled, "Deploy on Friday", now)

    # Not this week's: nothing asked or answered in it, or a shadow replay.
    _long_ago = request!(public, :complete, "Last month's outage", DateTime.add(now, -20, :day))
    shadow = request!(public, :complete, "Replayed", now)
    Repo.update_all(from(e in Episode, where: e.id == ^shadow.id), set: [execution_mode: :shadow])

    # Answered on the spot: a reply without a request behind it.
    quick = message!(workspace, "CWORKPUBLIC", "1790100009.000100", "What time is it?")
    Answers.quick_reply!(quick, "It is noon.", "1790100009.000200", now)

    report = compose(now)

    assert report.summary ==
             "This week I worked on 8 requests and finished 5 of them. " <>
               "I also answered 1 message on the spot and opened 1 draft PR."

    where = Names.destination(public)

    # The one with a draft PR first, then the newest; the second "Check
    # staging health" and the private request are the two more.
    assert lines(report, :done) == [
             "- [Fix the checkout alert](#{@base}#{timeline(checkout.episode.key)}) in #{where} · " <>
               "[draft PR #4](https://github.com/acme/checkout/pull/4)",
             "- [Rotate the API key](#{@base}#{timeline(older.key)}) in #{where}",
             "- [Check staging health](#{@base}#{timeline(again.key)}) in #{where}",
             "- and 2 more"
           ]

    assert lines(report, :open) == [
             "- [Add a smoke test](#{@base}#{timeline(waiting.key)}) in #{where}, waiting for an answer",
             "- [Track Terraform run 42](#{@base}#{timeline(watching.key)}) in #{where}, " <>
               "watching for an update"
           ]
  end

  test "a week whose every request is private says how many, and names none",
       %{now: now, workspace: workspace} do
    private = private_channel!(workspace, "CONLYPRIVATE")
    payroll = work_request!(workspace, private, "1790110001.000100", "Payroll totals?")
    title!(payroll.id, "Payroll totals")
    request!(private, :waiting_for_input, "Salary bands", now)

    report = compose(now)

    assert report.summary == "This week I worked on 2 requests and finished 1 of them."
    assert lines(report, :done) == ["1 request in private conversations."]
    assert lines(report, :open) == ["1 request in private conversations."]
  end

  test "stuck lists the failures open now that leave someone waiting, newest first",
       %{now: now, workspace: workspace} do
    entries =
      for index <- 1..4 do
        entry = message!(workspace, "CPEOPLE", "179050000#{index}.000100", "Question #{index}")
        block!(entry)
        backdate!(Entry, entry.id, :updated_at, DateTime.add(now, index * 60))
        entry
      end

    newest = entries |> Enum.reverse() |> Enum.take(3)

    assert lines(compose(now), :stuck) ==
             [
               "4 things need someone to look at them:"
               | Enum.map(newest, fn entry ->
                   path = FailureExplanation.path(%{kind: "admission", ref: Inbox.ref(entry)})
                   "- [Reading a message stopped](#{@base}#{path})"
                 end)
             ] ++ ["- and 1 more on [Failures](#{@base}/failures)"]
  end

  # How the work landed and what Ryker learned close the report in one line,
  # and only when there is something to say. A topic is named only from a
  # public channel.
  test "feedback and what Ryker learned close the report, naming a topic only from a public channel",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CLEARNED")
    request = work_request!(workspace, public, "1790200001.000100", "Is the database healthy?")

    signal!(request, :reaction_added, "+1", "up", DateTime.add(now, -600))
    signal!(request, :sentiment, "satisfied", "happy", DateTime.add(now, -500))
    signal!(request, :asked_again, nil, "again", DateTime.add(now, -400))
    signal!(request, :reaction_added, "eyes", "eyes", DateTime.add(now, -300))
    signal!(request, :reaction_added, "heart", "last-week", DateTime.add(now, -8, :day))

    fact!("Payments repository", DateTime.add(now, -3_600))
    fact!("Deploy window", DateTime.add(now, -8, :day))
    topic!(workspace, public, "Release process", DateTime.add(now, -1_800))
    topic!(workspace, "slack:#{workspace}:DPRIVATE", "Salary bands", DateTime.add(now, -600))

    assert compose(now).closing ==
             "Feedback this week: 2 positive and 1 negative. " <>
               "I learned 3 new things, most recently about “Release process”."
  end

  # -- The week ------------------------------------------------------------------------

  # This week ends a minute from now, so whatever the seeds write now is in it.
  defp compose(now) do
    to = DateTime.add(now, 60)

    WeeklyReport.compose(%{from: DateTime.add(to, -7, :day), to: to, timezone: "Etc/UTC"},
      now: now,
      base_url: @base
    )
  end

  defp lines(report, key),
    do: report.sections |> Enum.find(&(&1.key == key)) |> Map.fetch!(:lines)

  defp backdate!(schema, id, field \\ :inserted_at, at) do
    {1, _} = Repo.update_all(from(row in schema, where: row.id == ^id), set: [{field, at}])
  end

  defp timeline(key), do: "/timeline/" <> URI.encode_www_form(key)

  # -- Requests ------------------------------------------------------------------------

  defp message!(workspace, channel, ts, text, options \\ []) do
    Answers.slack_message!(
      [workspace: workspace, channel: channel, ts: ts, text: text] ++ options
    )
  end

  defp block!(entry) do
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        status: :blocked,
        last_error_code: "coop_turn_failed",
        last_error_detail: "the routing run failed"
      ]
    )
  end

  # A request Ryker answered this week.
  defp work_request!(workspace, "slack:" <> _ = conversation, ts, question) do
    channel = conversation |> String.split(":") |> List.last()
    asked = message!(workspace, channel, ts, question)

    reply =
      Answers.work_reply!(
        asked,
        "An answer.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.utc_now()
      )

    %{id: reply.episode.id, key: reply.episode.key, episode: {:episode, reply.episode.id}}
  end

  # A request someone asked at `at`, standing in `state` now.
  defp request!(conversation, state, title, at) do
    id = Ecto.UUID.generate()
    key = "weekly-report:#{id}"

    assert {:ok, _admitted} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation,
                   thread_ref: nil,
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "slack:event:#{id}",
                 occurred_at: at,
                 turn_ref: "turn:#{key}"
               })
             )

    {owner_kind, owner_ref} =
      case state do
        finished when finished in [:complete, :cancelled] -> {nil, nil}
        :waiting_for_input -> {:input, "input:#{id}"}
        :waiting_for_event -> {:event, "event:#{id}"}
      end

    Repo.update_all(from(e in Episode, where: e.id == ^id),
      set: [
        state: state,
        owner_kind: owner_kind,
        owner_ref: owner_ref,
        active_input_refs: [],
        queued_input_refs: [],
        queued_input_order_keys: []
      ]
    )

    title!(id, title)
    %{id: id, key: key}
  end

  # The title an accepted answer gave the request.
  defp title!(episode_id, title) do
    {1, _} =
      Repo.update_all(from(digest in RoutingDigest, where: digest.episode_id == ^episode_id),
        set: [
          title: title,
          title_turn_id: Ecto.UUID.generate(),
          title_updated_at: DateTime.utc_now()
        ]
      )
  end

  defp public_channel!(workspace, channel), do: channel!(workspace, channel, false)
  defp private_channel!(workspace, channel), do: channel!(workspace, channel, true)

  defp channel!(workspace, channel, private) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: workspace,
      channel_ref: channel,
      status: :joined,
      generation: 1,
      joined_at: DateTime.utc_now(),
      private: private,
      external_shared: false
    })

    "slack:#{workspace}:#{channel}"
  end

  # -- Feedback and what Ryker learned -------------------------------------------------

  defp signal!(%{episode: request}, kind, value, event, at) do
    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: kind,
               value: value,
               note: nil,
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:#{event}",
               occurred_at: at,
               request: request
             })
  end

  defp fact!(subject, at) do
    id = Ecto.UUID.generate()
    payload = %{"scope" => "global", "subject" => subject, "value" => "Remember it."}

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      kind: :entity_relationship,
      status: :active,
      workspace_ref: "installation",
      scope_ref: "installation:" <> Ryker.CanonicalJSON.digest(subject),
      scope_kind: :global,
      visibility: :global,
      subject: subject,
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      answer_provenance: %{"record_ref" => "answer:#{id}"},
      confirmed_by_actor_ref: "slack:user:UALICE",
      confirmation_ref: "answer:#{id}",
      confirmed_at: at,
      source_transport: "slack",
      source_conversation_ref: "slack:TREPORT:CFACTS",
      source_message_ref: "1790600000.000100"
    })
  end

  defp topic!(workspace, conversation, title, at) do
    key = title |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%ConversationKnowledge{
      id: Ecto.UUID.generate(),
      scope_key: conversation,
      topic_key: key,
      transport: "slack",
      workspace_ref: workspace,
      conversation_ref: conversation,
      visibility: :public,
      state: %{"title" => title, "summary" => "What we know about #{title}."},
      version: 1,
      source_generation: 1,
      source_dependencies: [],
      source_input_id: Ecto.UUID.generate(),
      latest_source_at: at,
      inserted_at: at,
      updated_at: at
    })
  end
end
