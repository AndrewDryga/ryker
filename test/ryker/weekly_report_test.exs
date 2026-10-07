defmodule Ryker.WeeklyReportTest do
  @moduledoc """
  The weekly report says how Ryker's week went, the way a teammate writes a
  weekly update in Slack, from the database alone. Every number and name in it comes
  from rows, so each test seeds known rows for this week and the weeks
  before, and holds the report to the exact words it must say. The model
  never writes a word of it.
  """
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [clocks_past!: 2]
  alias Ryker.Accounting.Execution
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Publication.Followup
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelMembership, Names}
  alias Ryker.WeeklyReport

  @actor "control-plane:local"
  @base "http://ryker.test"
  # A work request in these tests records its model call without usage, as
  # a call does until its turn reports it, so no cost can be worked out for
  # its week; the closing line ends by saying so.
  @no_cost "I couldn't work out what this week's work cost."

  setup do
    {:ok, _settings} = Settings.initialize(@actor)
    now = DateTime.utc_now(:second) |> Map.put(:microsecond, {0, 6})
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

  # Messages are stamped by the database's clock, and the preview's week ended at the host's.
  # After the Mac restarted on 2026-10-03 the database ran a quarter of a second ahead, and a
  # message answered just before the preview fell outside its week: the Weekly report page
  # said "nobody asked me for anything" whenever its test ran right after the others.
  test "a message answered just before the preview is counted in its week", %{
    workspace: workspace
  } do
    asked =
      Answers.slack_message!(
        workspace: workspace,
        channel: "CPREVIEW",
        text: "Is staging healthy?",
        ts: "1790700001.000100"
      )

    Answers.quick_reply!(asked, "Yes, it is.", "1790700001.000200", DateTime.utc_now())

    # The answer as the database stamped it, a moment ahead of the host's clock.
    stamped = DateTime.add(Repo.now!(), 300, :millisecond)

    Repo.update_all(from(entry in Entry, where: entry.id == ^asked.id),
      set: [inserted_at: stamped]
    )

    clocks_past!(stamped, [:database])

    assert WeeklyReport.preview(base_url: @base).text =~ "This past week I handled 1 message"
  end

  # Andrew, 2026-09-30, of a report that listed the Slack requests Ryker
  # finished: "those are random tasks in slack, they are irrelevant compared
  # to value that PRs deliver". The PRs lead; the messages are one sentence;
  # after that only what needs people. A request Ryker merely answered is
  # counted in that sentence and never named.
  test "the report leads with the PRs and names no Slack request Ryker merely answered",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CWORKPUBLIC")
    private = private_channel!(workspace, "CWORKPRIVATE")

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

    payroll =
      work_request!(workspace, private, "1790100003.000100", "Payroll totals?", asked)

    title!(payroll.id, "Payroll totals")

    older = work_request!(workspace, public, "1790100004.000100", "Rotate the API key", asked)
    title!(older.id, "Rotate the API key")
    backdate!(Episode, older.id, DateTime.add(now, -14, :day))

    # Waiting for someone's answer is named; watching and stopped are not.
    waiting = request!(public, :waiting_for_input, "Add a smoke test", now)
    request!(public, :waiting_for_event, "Track Terraform run 42", DateTime.add(now, -60))
    request!(public, :cancelled, "Deploy on Friday", now)

    # A shadow replay is not Ryker's week.
    shadow = request!(public, :waiting_for_input, "Replayed question", now)
    Repo.update_all(from(e in Episode, where: e.id == ^shadow.id), set: [execution_mode: :shadow])

    # Answered on the spot in half a minute.
    quick =
      message!(workspace, "CWORKPUBLIC", "1790100009.000100", "What time is it?",
        at: DateTime.add(now, -45)
      )

    Answers.quick_reply!(quick, "It is noon.", "1790100009.000200", DateTime.add(now, -15))

    report = compose(now)
    where = Names.destination(public)

    assert Enum.map(report.parts, & &1.key) == [
             :greeting,
             :pull_requests,
             :work,
             :questions,
             :closing
           ]

    assert part(report, :pull_requests) == [
             "I opened 1 PR this week, and it's waiting for review:",
             "- [Implement weekly-#{workspace}](https://github.com/acme/checkout/pull/4) · " <>
               "checkout#4, open for less than a day"
           ]

    # Four messages, three of them answered five minutes after they were
    # asked: the typical reply is the middle one.
    assert part(report, :work) == [
             "I also handled 4 messages, and a typical reply took about 5 minutes. " <>
               "1 was a quick answer; the other 3 needed deeper work."
           ]

    assert part(report, :questions) == [
             "I'm waiting for an answer to 1 question:",
             "- [Add a smoke test](#{@base}#{timeline(waiting)}) in #{where}"
           ]

    for title <- [
          "Fix the checkout alert",
          "Check staging health",
          "Rotate the API key",
          "Track Terraform run 42",
          "Deploy on Friday",
          "Replayed question"
        ] do
      refute report.text =~ title
    end
  end

  # Andrew, 2026-09-30, of "I worked on 45 requests and finished 35 of
  # them.": "why we need this? it should not fail at all". Nothing had
  # failed: six were closed by a person as no longer needed, five of them
  # after Ryker had answered, and four were waiting for an answer or an
  # update. A completion rate read as ten failures; what got done, what is
  # still open and what is stuck say it without one.
  test "the report states no completion rate, so work closed as no longer needed or still open does not read as failed",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CNORATE")

    answered =
      work_request!(
        workspace,
        public,
        "1790400001.000100",
        "Is the API up?",
        DateTime.add(now, -60)
      )

    title!(answered.id, "Check the API")
    request!(public, :cancelled, "Deploy on Friday", now)
    request!(public, :waiting_for_input, "Add a smoke test", now)

    report = compose(now)

    assert part(report, :work) == [
             "This past week I handled 1 message, and my reply took about a minute. " <>
               "It needed deeper work."
           ]

    refute report.text =~ "worked on"
    refute report.text =~ "finished"
  end

  # Andrew, 2026-09-30: "can we add total cost of work for the week too?"
  # Every call that week ran on a ChatGPT sign-in, which reports no price, so
  # the only cost Ryker has is its estimate at API prices (Usage showed
  # $6.52); the report says so rather than passing it off as a bill.
  test "the report says what the week's work cost, as an estimate at API prices when the provider reported none",
       %{now: now, workspace: workspace} do
    public_channel!(workspace, "CCOST")

    quick =
      message!(workspace, "CCOST", "1790600001.000100", "Is it up?", at: DateTime.add(now, -45))

    Answers.quick_reply!(quick, "Yes.", "1790600001.000200", DateTime.add(now, -15))

    # 100,000 fresh × $4 + 900,000 cached × $0.40 + 10,000 out × $20 a million.
    execution!("live", DateTime.add(now, -3_600))
    # Last week's and a shadow replay's are not this week's work.
    execution!("live", DateTime.add(now, -8, :day))
    execution!("shadow", DateTime.add(now, -600))

    report = compose(now)

    assert part(report, :work) == [
             "This past week I handled 1 message, and my reply took about 30 seconds. " <>
               "It was a quick answer."
           ]

    # At the end of the closing line, not a paragraph of its own.
    assert part(report, :closing) == [
             "In total, this week's work cost about $0.96 at API prices."
           ]

    assert Enum.map(report.parts, & &1.key) == [:greeting, :work, :closing]
  end

  test "a cost the provider reported is stated as it is, and work nobody could price says so",
       %{now: now} do
    reported = execution!("live", DateTime.add(now, -3_600))

    Repo.update_all(from(e in Execution, where: e.id == ^reported.id),
      set: [usage_cost_recorded: true, usage_cost_usd: Decimal.new("1234.5")]
    )

    # Nobody asked anything, and yet something ran: a schedule or learning.
    assert part(compose(now), :work) == ["It was a quiet week: nobody asked me for anything."]
    assert part(compose(now), :closing) == ["In total, this week's work cost $1,234.50."]

    Repo.update_all(from(e in Execution, where: e.id == ^reported.id),
      set: [usage_cost_recorded: false, usage_cost_usd: nil, usage_recorded: false]
    )

    assert part(compose(now), :closing) == [@no_cost]
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
               "4 were quick answers; the other one needed deeper work."
           ]
  end

  # Andrew, 2026-09-30: "I also created X PRs (X already merged), here are
  # the most impactful ones ... Some PRs are still open and waiting for the
  # review". Merged PRs are the value delivered and are named; every PR still
  # open is owed a review, however old, and says how long it has waited.
  test "the report names the week's merged PRs and every PR still waiting for review, with how long it has waited",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CPULLS")
    private = private_channel!(workspace, "CPULLSPRIVATE")

    merged = pull_request!(workspace, "merged", public, 11)
    set_pull_request!(merged, pr_state: :merged, merged_at: now)
    closed = pull_request!(workspace, "closed", public, 12)
    set_pull_request!(closed, pr_state: :closed)
    fresh = pull_request!(workspace, "fresh", public, 13)
    _secret = pull_request!(workspace, "secret", private, 14)
    # Opened two weeks ago and still open: not this week's, still owed a review.
    stale = pull_request!(workspace, "stale", public, 15)
    set_pull_request!(stale, inserted_at: DateTime.add(now, -14, :day))

    report = compose(now)

    assert part(report, :pull_requests) == [
             "I opened 4 PRs this week, and 1 is already merged:",
             "- [Implement weekly-#{workspace}-merged](#{pr_url(merged)}) · merged#11",
             "",
             "Still waiting for review:",
             "- [Implement weekly-#{workspace}-fresh](#{pr_url(fresh)}) · fresh#13, " <>
               "open for less than a day",
             "- [Implement weekly-#{workspace}-stale](#{pr_url(stale)}) · stale#15, " <>
               "open for 14 days",
             "- and 1 more"
           ]

    refute report.text =~ "weekly-#{workspace}-secret"
    refute report.text =~ "weekly-#{workspace}-closed"
  end

  test "a week whose every question is private says how many, and names none",
       %{now: now, workspace: workspace} do
    private = private_channel!(workspace, "CONLYPRIVATE")
    payroll = work_request!(workspace, private, "1790110001.000100", "Payroll totals?")
    title!(payroll.id, "Payroll totals")
    request!(private, :waiting_for_input, "Salary bands", now)

    report = compose(now)

    assert part(report, :questions) == [
             "I'm waiting for an answer to 1 question, in a private conversation."
           ]

    refute report.text =~ "Payroll totals"
    refute report.text =~ "Salary bands"
  end

  test "stuck says how many failures leave someone waiting now, with a link to them",
       %{now: now, workspace: workspace} do
    for index <- 1..4 do
      entry = message!(workspace, "CPEOPLE", "179050000#{index}.000100", "Question #{index}")
      block!(entry)
    end

    assert part(compose(now), :stuck) == [
             "4 things are stuck and need someone to look at them: [Failures](#{@base}/failures)"
           ]
  end

  # How people took the answers, in a word a person would use for it, and
  # what Ryker learned close the report, and only when there is something to
  # say. A topic is named only from a public channel. Andrew, 2026-09-30, of
  # "Feedback was": "Feedback I have received was".
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
             "Feedback I have received was mostly positive: 2 positive and 1 negative. " <>
               ~s(I also learned 3 new things, most recently about "Release process". ) <>
               @no_cost
           ]
  end

  test "feedback all one way, or evenly split, says so plainly",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CMOOD")
    request = work_request!(workspace, public, "1790210001.000100", "Is the cache warm?")

    signal!(request, :reaction_added, "+1", "first", DateTime.add(now, -600))
    assert part(compose(now), :closing) == ["Feedback I have received was positive. " <> @no_cost]

    signal!(request, :reaction_added, "tada", "second", DateTime.add(now, -500))

    assert part(compose(now), :closing) == [
             "Both pieces of feedback I have received were positive. " <> @no_cost
           ]

    signal!(request, :reaction_added, "rocket", "third", DateTime.add(now, -450))

    assert part(compose(now), :closing) == [
             "All 3 pieces of feedback I have received were positive. " <> @no_cost
           ]

    for event <- ~w(fourth fifth sixth) do
      signal!(request, :asked_again, nil, event, DateTime.add(now, -400))
    end

    assert part(compose(now), :closing) == [
             "Feedback I have received was mixed: 3 positive and 3 negative. " <> @no_cost
           ]
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

  defp timeline(request), do: "/timeline/" <> request.id

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

  # -- Cost ----------------------------------------------------------------------------

  # One model call at `at`: 100,000 fresh input, 900,000 cached input and
  # 10,000 output tokens on the default Sol price, with no provider cost.
  defp execution!(mode, at) do
    Repo.insert!(%Execution{
      kind: "work",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      transport: "slack",
      conversation_ref: "slack:TCOST:CCOST",
      status: "succeeded",
      execution_mode: mode,
      recorded_at: at,
      execution_target: "codex:gpt-5.6-sol/medium@default",
      usage_recorded: true,
      usage_input_tokens: 100_000,
      usage_cached_input_tokens: 900_000,
      usage_output_tokens: 10_000,
      usage_reasoning_tokens: 0
    })
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
