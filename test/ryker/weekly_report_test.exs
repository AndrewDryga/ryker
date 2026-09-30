defmodule Ryker.WeeklyReportTest do
  @moduledoc """
  The weekly report says how Ryker's week went, the way a teammate writes a
  weekly update in Slack, from the database alone. Every number and name in it comes
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
  alias Ryker.Publication.Followup
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

  # A part with nothing to say is left out, so a quiet week is two lines.
  # Saying "Nothing." under three headings read like a form, not a person
  # (Andrew, 2026-09-30: "how a real human would send something like this
  # to Slack?").
  test "a quiet week says so in one line after the greeting" do
    week = %{
      from: ~U[2026-09-14 09:00:00.000000Z],
      to: ~U[2026-09-21 09:00:00.000000Z],
      timezone: "Etc/UTC"
    }

    report = WeeklyReport.compose(week, now: week.to, base_url: @base)

    assert report.text == """
           Hey everyone 👋 Here's my weekly report for 14–21 Sep.

           It was a quiet week: nobody asked me for anything.\
           """

    across = %{week | from: ~U[2026-09-28 09:00:00.000000Z], to: ~U[2026-10-05 09:00:00.000000Z]}

    assert WeeklyReport.compose(across, now: across.to, base_url: @base, preview: true).text =~
             "Hey everyone 👋 Here's a preview of my weekly report for 28 Sep – 5 Oct.\n\n"
  end

  # Andrew, 2026-09-30, sketching the report he would write: "during last
  # week I've handled X messages (on average reply took X, Y/X were answered
  # on the spot while other needed a deeper work)". The report before said
  # how many requests but never how many messages or how fast.
  test "the report says how many messages Ryker handled and how fast, what it got done and what is still open, naming only requests from a public channel",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CWORKPUBLIC")
    private = private_channel!(workspace, "CWORKPRIVATE")

    # Finished this week, the one with a PR first.
    checkout =
      PublicationFixture.published!("weekly-#{workspace}",
        conversation_ref: public,
        github_repository: "acme/checkout",
        pull_request_number: 4
      )

    title!(checkout.episode.id, "Fix the checkout alert")

    # Each asked five minutes ago and answered now.
    asked = DateTime.add(now, -300)

    staging = work_request!(workspace, public, "1790100001.000100", "Is staging healthy?", asked)
    title!(staging.id, "Check staging health")

    # The same title twice in one channel is one line; the other is one more.
    again =
      work_request!(workspace, public, "1790100002.000100", "Is staging healthy now?", asked)

    title!(again.id, "Check staging health")

    payroll =
      work_request!(
        workspace,
        private,
        "1790100003.000100",
        "What are the payroll totals?",
        asked
      )

    title!(payroll.id, "Payroll totals")

    # Asked two weeks ago and answered again this week: this week's work.
    older = work_request!(workspace, public, "1790100004.000100", "Rotate the API key", asked)
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

    # Answered on the spot in half a minute: a reply without a request behind it.
    quick =
      message!(workspace, "CWORKPUBLIC", "1790100009.000100", "What time is it?",
        at: DateTime.add(now, -45)
      )

    Answers.quick_reply!(quick, "It is noon.", "1790100009.000200", DateTime.add(now, -15))

    report = compose(now)

    # Five messages, four of them answered five minutes after they were
    # asked: the typical reply is the middle one.
    assert part(report, :work) == [
             "This past week I handled 5 messages, and a typical reply took about 5 minutes. " <>
               "I answered 1 of them on the spot; the rest needed deeper work. " <>
               "I worked on 8 requests and finished 5 of them."
           ]

    where = Names.destination(public)

    # The one with a PR first, then the newest; the second "Check staging
    # health" and the private request are the other two.
    assert part(report, :done) == [
             "Here's what I got done:",
             "- [Fix the checkout alert](#{@base}#{timeline(checkout.episode.key)}) in #{where} · " <>
               "[PR #4](https://github.com/acme/checkout/pull/4)",
             "- [Rotate the API key](#{@base}#{timeline(older.key)}) in #{where}",
             "- [Check staging health](#{@base}#{timeline(again.key)}) in #{where}",
             "",
             "You can see the other 2 [here](#{@base}/activity?filter=done)."
           ]

    assert part(report, :pull_requests) == [
             "I also opened 1 PR; it isn't merged yet. Still waiting for review:",
             "- [#4 Implement weekly-#{workspace}](https://github.com/acme/checkout/pull/4) in #{where}"
           ]

    assert part(report, :open) == [
             "2 requests are still open:",
             "- [Add a smoke test](#{@base}#{timeline(waiting.key)}) in #{where}, waiting for an answer",
             "- [Track Terraform run 42](#{@base}#{timeline(watching.key)}) in #{where}, " <>
               "watching for an update"
           ]

    # Nothing is stuck and nobody said anything about the answers.
    assert Enum.map(report.parts, & &1.key) == [:greeting, :work, :done, :pull_requests, :open]
  end

  # Andrew asked for how long a reply took "on average". In the week to 30
  # Sep the live install's quick replies averaged half an hour, because one
  # was delivered 28 hours after it was asked, while the middle one took 15
  # seconds: an average would have told the channel Ryker was slow.
  test "a typical reply is the middle one, so one late answer does not make the week look slow",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CREPLYTIME")

    for {seconds, index} <- Enum.with_index([10, 20, 30, 28 * 3_600], 1) do
      asked =
        message!(workspace, "CREPLYTIME", "179030000#{index}.000100", "Question #{index}",
          at: DateTime.add(now, -seconds - 5)
        )

      Answers.quick_reply!(
        asked,
        "Answer #{index}.",
        "179030000#{index}.000200",
        DateTime.add(now, -5)
      )
    end

    # A request answered two minutes after it was asked.
    work_request!(
      workspace,
      public,
      "1790300009.000100",
      "Is the queue draining?",
      DateTime.add(now, -120)
    )

    assert part(compose(now), :work) == [
             "This past week I handled 5 messages, and a typical reply took about 30 seconds. " <>
               "I answered 4 of them on the spot; the rest needed deeper work. " <>
               "I worked on 1 request and finished it."
           ]
  end

  # Andrew, 2026-09-30: "I also created X PRs (X already merged) ... Some PRs
  # are still open and waiting for the review". The report counted the week's
  # draft PRs and said nothing of merges or of the reviews people owed.
  test "the report counts the PRs opened this week and merged since, and lists every PR still waiting for review",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CPULLS")
    private = private_channel!(workspace, "CPULLSPRIVATE")

    merged = pull_request!(workspace, "merged", public, 11)
    set_pull_request!(merged, pr_state: "merged", merged_at: now)
    closed = pull_request!(workspace, "closed", public, 12)
    set_pull_request!(closed, pr_state: "closed")
    fresh = pull_request!(workspace, "fresh", public, 13)
    secret = pull_request!(workspace, "secret", private, 14)
    # Opened two weeks ago and still open: not this week's, still owed a review.
    stale = pull_request!(workspace, "stale", public, 15)
    set_pull_request!(stale, inserted_at: DateTime.add(now, -14, :day))

    report = compose(now)
    where = Names.destination(public)

    assert part(report, :pull_requests) == [
             "I also opened 4 PRs, and 1 is already merged. Still waiting for review:",
             "- [#13 Implement weekly-#{workspace}-fresh](#{pr_url(fresh)}) in #{where}",
             "- [#15 Implement weekly-#{workspace}-stale](#{pr_url(stale)}) in #{where}",
             "- and 1 more"
           ]

    refute report.text =~ "weekly-#{workspace}-secret"
    assert secret.publication.pull_request_number == 14
  end

  test "a week whose every request is private says how many, and names none",
       %{now: now, workspace: workspace} do
    private = private_channel!(workspace, "CONLYPRIVATE")
    payroll = work_request!(workspace, private, "1790110001.000100", "Payroll totals?")
    title!(payroll.id, "Payroll totals")
    request!(private, :waiting_for_input, "Salary bands", now)

    report = compose(now)

    assert part(report, :done) == [
             "The request I finished was in a private conversation, so I'm not naming it here."
           ]

    assert part(report, :open) == ["1 request is still open, in a private conversation."]
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

    assert part(compose(now), :stuck) ==
             [
               "4 things need someone to look at them:"
               | Enum.map(newest, fn entry ->
                   path = FailureExplanation.path(%{kind: "admission", ref: Inbox.ref(entry)})
                   "- [Reading a message stopped](#{@base}#{path})"
                 end)
             ] ++ ["- and 1 more on [Failures](#{@base}/failures)"]
  end

  # How people took the answers, in a word a person would use for it, and
  # what Ryker learned close the report, and only when there is something to
  # say. A topic is named only from a public channel.
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

    assert part(compose(now), :closing) == [
             "Overall, feedback was mostly positive: 2 positive and 1 negative. " <>
               "I also learned 3 new things, most recently about “Release process”."
           ]
  end

  test "feedback all one way, or evenly split, says so plainly",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CMOOD")
    request = work_request!(workspace, public, "1790210001.000100", "Is the cache warm?")

    signal!(request, :reaction_added, "+1", "first", DateTime.add(now, -600))
    assert part(compose(now), :closing) == ["The one piece of feedback I got was positive."]

    signal!(request, :reaction_added, "tada", "second", DateTime.add(now, -500))
    assert part(compose(now), :closing) == ["All 2 pieces of feedback I got were positive."]

    signal!(request, :asked_again, nil, "third", DateTime.add(now, -400))
    signal!(request, :asked_again, nil, "fourth", DateTime.add(now, -300))
    assert part(compose(now), :closing) == ["Feedback was mixed: 2 positive and 2 negative."]
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

  defp part(report, key) do
    case Enum.find(report.parts, &(&1.key == key)) do
      nil -> nil
      part -> part.lines
    end
  end

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

  # A request Ryker answered now, asked at `at` when given.
  defp work_request!(workspace, "slack:" <> _ = conversation, ts, question, at \\ nil) do
    channel = conversation |> String.split(":") |> List.last()
    asked = message!(workspace, channel, ts, question, if(at, do: [at: at], else: []))

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

  # -- Pull requests -------------------------------------------------------------------

  # A PR Ryker opened now for a request in `conversation`.
  defp pull_request!(workspace, name, conversation, number) do
    PublicationFixture.published!("weekly-#{workspace}-#{name}",
      conversation_ref: conversation,
      github_repository: "acme/#{name}",
      pull_request_number: number
    )
  end

  defp set_pull_request!(%{publication: publication}, changes) do
    {1, _} =
      Repo.update_all(from(f in Followup, where: f.publication_id == ^publication.id),
        set: changes
      )
  end

  defp pr_url(%{publication: publication}), do: publication.pull_request_url

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
