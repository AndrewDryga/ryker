defmodule Ryker.WeeklyReportTest do
  @moduledoc """
  The weekly report says how Ryker's week went, from the database alone.
  Every number in it is a count of rows, so each test seeds known rows for
  this week, last week and the weeks before, and holds each section to the
  exact words it must say. The model never writes a word of it.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Accounting.Execution
  alias Ryker.Admission.{Attempt, Decision}
  alias Ryker.ControlPlane.FailureExplanation
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.{Entry, EntryChangeset}
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Settings
  alias Ryker.Settings.PricingRate
  alias Ryker.Slack.{ChannelMembership, Names}
  alias Ryker.WeeklyReport
  alias Ryker.Work.{Custody, Turn}

  @actor "control-plane:local"
  @base "http://ryker.test"

  setup do
    {:ok, _settings} = Settings.initialize(@actor)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:microsecond, {0, 6})
    workspace = "TREPORT#{System.unique_integer([:positive])}"
    %{now: now, workspace: workspace}
  end

  # "Empty sections say none rather than vanishing": a section that is left
  # out reads as a good week, and a quiet week is exactly when a missing
  # instrument goes unnoticed.
  test "a quiet week says None in every section rather than leaving one out" do
    week = %{
      from: ~U[2026-09-14 09:00:00.000000Z],
      to: ~U[2026-09-21 09:00:00.000000Z],
      previous_from: ~U[2026-09-07 09:00:00.000000Z],
      timezone: "Etc/UTC"
    }

    report = WeeklyReport.compose(week, now: week.to, base_url: @base)

    assert report.text == """
           **Weekly report**
           How my week went, from Mon 14 Sep 09:00 to Mon 21 Sep 09:00 UTC.

           **Requests**
           None.
           Open [Activity](http://ryker.test/activity).

           **Feedback**
           None.
           Open [Feedback](http://ryker.test/feedback).

           **What to fix**
           None.
           Open [What to fix](http://ryker.test/feedback/fix).

           **Corrections**
           None.
           Open [Usage & cost](http://ryker.test/usage).

           **Learned**
           None.
           Open [Facts](http://ryker.test/memory) or [Learned](http://ryker.test/memory/learned).

           **Needs a person**
           None.
           Open [Failures](http://ryker.test/failures).

           **Cost**
           None.
           Open [Usage & cost](http://ryker.test/usage).\
           """

    assert Enum.map(report.sections, & &1.title) == [
             "Requests",
             "Feedback",
             "What to fix",
             "Corrections",
             "Learned",
             "Needs a person",
             "Cost"
           ]

    assert Enum.all?(report.sections, &(hd(&1.lines) == "None."))
  end

  test "requests count each message by where it went, and each request Work took on by where it stands",
       %{now: now, workspace: workspace} do
    channel = "CREQUESTS"

    quick = message!(workspace, channel, "1790100001.000100", "What time is it?")
    Answers.quick_reply!(quick, "It is noon.", "1790100001.000200", now)

    ignored = message!(workspace, channel, "1790100002.000100", "Thanks, all")
    decide!(ignored, "ignore")

    # An edit is a revision of a message already counted, not a message.
    _edit =
      message!(workspace, channel, "1790100002.000100", "Thanks, everyone",
        kind: :edit,
        revision: 2
      )

    asked = message!(workspace, channel, "1790100003.000100", "Is staging healthy?")
    Answers.work_reply!(asked, "Staging is healthy.", "1790100003.000200", now)

    stopped_before = message!(workspace, channel, "1790100004.000100", "Deploy the fix")
    block!(stopped_before)

    _reading = message!(workspace, channel, "1790100005.000100", "Hello?")

    # A shadow deployment's replay is not Ryker's week.
    shadow = message!(workspace, channel, "1790100006.000100", "Replayed")
    Repo.update_all(from(e in Entry, where: e.id == ^shadow.id), set: [execution_mode: :shadow])

    last_week = message!(workspace, channel, "1790100007.000100", "Last week's question")
    backdate!(Entry, last_week.id, DateTime.add(now, -8, :day))
    long_ago = message!(workspace, channel, "1790100008.000100", "Three weeks ago")
    backdate!(Entry, long_ago.id, DateTime.add(now, -20, :day))

    # The requests Work took on this week, one in every state it can be in:
    # done (the reply above), waiting, blocked, stopped and still going.
    blocked_work!(workspace)
    episode!(workspace, :waiting_for_input)
    episode!(workspace, :cancelled)
    episode!(workspace, :working)
    shadow_episode = episode!(workspace, :complete)

    Repo.update_all(from(e in Episode, where: e.id == ^shadow_episode.id),
      set: [execution_mode: :shadow]
    )

    backdate!(Episode, episode!(workspace, :complete).id, DateTime.add(now, -8, :day))

    assert lines(now, :requests) == [
             "I read 5 messages (last week 1): 1 answered right away, 1 needed no response, " <>
               "1 started or continued a request, 1 is blocked before routing and 1 is still being read.",
             "I took on 5 requests (last week 1): 1 is done, 1 is waiting for a person, " <>
               "1 is blocked, 1 was stopped and 1 is still going.",
             "Open [Activity](http://ryker.test/activity)."
           ]
  end

  # The report goes to one channel. A request from a private channel names
  # nothing there beyond the fact that it happened: its words stay where they
  # were said, one link away for someone who can read them.
  test "feedback counts positive and negative by kind, naming a frustrated request only from a public channel",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CFEEDBACKPUBLIC")
    private = private_channel!(workspace, "CFEEDBACKPRIVATE")

    open =
      work_request!(workspace, public, "1790200001.000100", "Is the staging database healthy?")

    closed =
      work_request!(workspace, private, "1790200002.000100", "What are the payroll totals?")

    signal!(open, :sentiment, "frustrated", "open-angry", DateTime.add(now, -3_600))
    signal!(closed, :reaction_added, "-1", "closed-down", DateTime.add(now, -1_800))
    signal!(open, :reaction_added, "+1", "open-up", DateTime.add(now, -600))
    signal!(closed, :sentiment, "satisfied", "closed-happy", DateTime.add(now, -500))
    signal!(open, :asked_again, nil, "open-again", DateTime.add(now, -400))
    signal!(open, :message_edited, nil, "open-edited", DateTime.add(now, -300))
    signal!(open, :reaction_added, "eyes", "open-eyes", DateTime.add(now, -200))
    signal!(open, :reviewed, "complete", "open-reviewed", DateTime.add(now, -100))
    signal!(open, :reaction_added, "heart", "last-week", DateTime.add(now, -8, :day))
    signal!(open, :reaction_added, "tada", "long-ago", DateTime.add(now, -20, :day))

    %{episode: {:episode, open_id}, key: open_key} = open
    %{key: closed_key} = closed
    assert Repo.get!(Episode, open_id).key == open_key

    assert lines(now, :feedback) == [
             "2 positive and 4 negative (last week 1 and 0).",
             "Negative: 2 frustrated, 1 asked again and 1 edited or deleted their message.",
             "Also 1 neutral and 1 review.",
             "Frustrated:",
             "- A request in a private conversation · [Timeline](#{@base}#{timeline(closed_key)})",
             "- “Is the staging database healthy?” in #{Names.destination(public)} · " <>
               "[Timeline](#{@base}#{timeline(open_key)})",
             "Open [Feedback](http://ryker.test/feedback)."
           ]
  end

  test "what to fix counts the week's requests by diagnosis and decision, quoting the newest sure diagnosis only from a public channel",
       %{now: now, workspace: workspace} do
    public = public_channel!(workspace, "CFIXPUBLIC")
    private = private_channel!(workspace, "CFIXPRIVATE")

    access =
      unhappy!(workspace, public, "1790300001.000100",
        category: :host_bug,
        confidence: :high,
        what_went_wrong: "Ryker asked for access it had: no Emisar tool reached the Work turn.",
        analyzed_at: DateTime.add(now, -2 * 3_600)
      )

    staging =
      unhappy!(workspace, public, "1790300002.000100",
        category: :prompt_bug,
        confidence: :medium,
        what_went_wrong: "It answered about production when asked about staging.",
        analyzed_at: DateTime.add(now, -3_600)
      )

    payroll =
      unhappy!(workspace, private, "1790300003.000100",
        category: :model_mistake,
        confidence: :high,
        what_went_wrong: "It added the payroll totals wrong.",
        analyzed_at: DateTime.add(now, -3 * 3_600)
      )

    _waiting = unhappy!(workspace, public, "1790300004.000100", nil)

    noise =
      unhappy!(workspace, public, "1790300005.000100",
        category: :not_a_problem,
        confidence: :high,
        what_went_wrong: "Nothing went wrong; they reacted to the news.",
        analyzed_at: DateTime.add(now, -30)
      )

    # Found and dismissed a week before: neither counts this week.
    old = unhappy!(workspace, public, "1790300006.000100", nil)
    assert {:ok, _dismissed} = Improvement.dismiss(old.id, @actor)
    eight_days_ago = DateTime.add(now, -8, :day)

    Repo.update_all(from(c in Candidate, where: c.id == ^old.id),
      set: [inserted_at: eight_days_ago, decided_at: eight_days_ago]
    )

    assert {:ok, _accepted} = Improvement.accept(staging.id, @actor)
    assert {:ok, _dismissed} = Improvement.dismiss(noise.id, @actor)
    assert access.status == :open

    # "Not a problem" names no fault, so it is never the diagnosis quoted.
    assert lines(now, :fix) == [
             "5 new: 1 host bug, 1 prompt bug, 1 model mistake, 1 not a problem and 1 still to analyze. " <>
               "1 accepted as an eval case and 1 dismissed.",
             "Newest sure diagnosis: “Ryker asked for access it had: no Emisar tool reached the Work turn.”",
             "Open [What to fix](http://ryker.test/feedback/fix)."
           ]

    # The newest sure diagnosis from a private channel is not quoted at all.
    Repo.update_all(from(c in Candidate, where: c.id == ^payroll.id),
      set: [analyzed_at: DateTime.add(now, -60)]
    )

    assert Enum.at(lines(now, :fix), 1) ==
             "The newest sure diagnosis is about a private conversation; What to fix has it."
  end

  test "corrections count the routing and Work answers that needed correcting, and the correction given most often",
       %{now: now, workspace: workspace} do
    channel = "CCORRECTIONS"

    # Routing records the attempt its answer passed on.
    routing!(workspace, channel, "1790400001.000100", %{"validation_attempt" => 1}, now)
    routing!(workspace, channel, "1790400002.000100", %{"validation_attempt" => 3}, now)
    routing!(workspace, channel, "1790400003.000100", %{"state" => "failed"}, now)

    routing!(
      workspace,
      channel,
      "1790400004.000100",
      %{"validation_attempt" => 2},
      DateTime.add(now, -8, :day)
    )

    # Work keeps each check of each answer, and what it was told to fix.
    checked!(workspace, channel, "1790400005.000100", [
      reject(["outcome.state must be complete", "message must not be empty"], now, -7_200),
      accept(now, -7_000)
    ])

    checked!(workspace, channel, "1790400006.000100", [
      reject(["outcome.state must be complete"], now, -3_600),
      accept(now, -3_500)
    ])

    checked!(workspace, channel, "1790400007.000100", [accept(now, -60)])

    checked!(workspace, channel, "1790400008.000100", [
      reject(["title is too long", "title is too long"], DateTime.add(now, -8, :day), 0),
      accept(DateTime.add(now, -8, :day), 60)
    ])

    assert lines(now, :corrections) == [
             "Routing: 1 of 2 answers needed a correction (last week 1 of 1).",
             "Work: 2 of 3 answers were sent back to be fixed (last week 1 of 1).",
             "Most repeated: “outcome.state must be complete” (twice).",
             "Open [Usage & cost](http://ryker.test/usage)."
           ]
  end

  test "learned counts new facts and topics, naming the newest only where the whole workspace may read them",
       %{now: now, workspace: workspace} do
    fact!("Payments repository", DateTime.add(now, -3_600))
    fact!("Deploy window", DateTime.add(now, -8, :day))
    topic!(workspace, "Release process", :public, DateTime.add(now, -1_800))
    topic!(workspace, "Salary bands", :private, DateTime.add(now, -600))
    topic!(workspace, "On-call rotation", :public, DateTime.add(now, -7_200))
    topic!(workspace, "Old outage", :public, DateTime.add(now, -8, :day))
    forgotten = topic!(workspace, "Forgotten", :public, DateTime.add(now, -300))

    Repo.update_all(from(k in ConversationKnowledge, where: k.id == ^forgotten.id),
      set: [forgotten_at: now]
    )

    release = Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == "release-process"))

    assert lines(now, :learned) == [
             "1 new fact (last week 1) and 3 new topics (last week 1).",
             "Newest:",
             "- Topic: “Release process” · [Open](#{@base}/memory/learned?item=#{release.id})",
             "- Fact: “Payments repository”",
             "- Topic: “On-call rotation” · " <>
               "[Open](#{@base}/memory/learned?item=#{topic_id("on-call-rotation")})",
             "Open [Facts](http://ryker.test/memory) or [Learned](http://ryker.test/memory/learned)."
           ]
  end

  test "needs a person lists the failures open now that leave someone waiting, newest first",
       %{now: now, workspace: workspace} do
    entries =
      for index <- 1..4 do
        entry = message!(workspace, "CPEOPLE", "179050000#{index}.000100", "Question #{index}")
        block!(entry)
        backdate!(Entry, entry.id, :updated_at, DateTime.add(now, index * 60))
        entry
      end

    newest = entries |> Enum.reverse() |> Enum.take(3)

    assert lines(now, :people) ==
             [
               "4 failures leave someone without a reply, an update or a result:"
               | Enum.map(newest, fn entry ->
                   path = FailureExplanation.path(%{kind: "admission", ref: Inbox.ref(entry)})
                   "- [Reading a message stopped](#{@base}#{path})"
                 end)
             ] ++ ["- and 1 more", "Open [Failures](http://ryker.test/failures)."]
  end

  test "cost adds what the week's model calls reported and what their prices estimate, beside last week's",
       %{now: now} do
    Repo.insert!(%PricingRate{
      id: Ecto.UUID.generate(),
      execution_target: "test:model",
      input_usd_per_million: Decimal.new("0.50"),
      cached_input_usd_per_million: Decimal.new("0.05"),
      output_usd_per_million: Decimal.new("2"),
      effective_from: ~D[2020-01-01],
      revision: 1,
      provenance: "test",
      inserted_at: now
    })

    execution!(now, cost: "1.25")
    execution!(now, target: "test:model", input_tokens: 1_000_000)
    execution!(now, cost: "5", mode: "shadow")
    execution!(DateTime.add(now, -8, :day), cost: "1")
    execution!(DateTime.add(now, -20, :day), cost: "9")

    assert lines(now, :cost) == [
             "Model calls cost $1.75 (last week $1.00), partly estimated from Model prices.",
             "Open [Usage & cost](http://ryker.test/usage)."
           ]
  end

  # -- The week ------------------------------------------------------------------------

  # This week ends a minute from now, so whatever the seeds write now is in it.
  defp lines(now, key) do
    to = DateTime.add(now, 60)

    %{from: DateTime.add(to, -7, :day), to: to, previous_from: DateTime.add(to, -14, :day)}
    |> Map.put(:timezone, "Etc/UTC")
    |> WeeklyReport.compose(now: now, base_url: @base)
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:lines)
  end

  defp backdate!(schema, id, field \\ :inserted_at, at) do
    {1, _} = Repo.update_all(from(row in schema, where: row.id == ^id), set: [{field, at}])
  end

  # -- Requests ------------------------------------------------------------------------

  defp message!(workspace, channel, ts, text, options \\ []) do
    Answers.slack_message!(
      [workspace: workspace, channel: channel, ts: ts, text: text] ++ options
    )
  end

  defp decide!(entry, action) do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => action,
               "episode_ref" => nil,
               "messages" => nil,
               "reactions" => nil,
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Recorded for a weekly report test.",
               "work_class" => nil
             })

    Repo.update!(EntryChangeset.decide(entry, decision, "decision:#{entry.id}", nil))
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

  defp episode!(workspace, state) do
    id = Ecto.UUID.generate()

    {owner_kind, owner_ref} =
      case state do
        finished when finished in [:complete, :cancelled] -> {nil, nil}
        :waiting_for_input -> {:input, "input:#{id}"}
        :working -> {:turn, "turn:#{id}"}
      end

    Repo.insert!(%Episode{
      id: id,
      key: "weekly-report:#{id}",
      execution_mode: :live,
      state: state,
      owner_kind: owner_kind,
      owner_ref: owner_ref,
      destination_transport: "slack",
      destination_conversation_ref: "slack:#{workspace}:CREQUESTS"
    })
  end

  # A request whose Work turn stopped and waits on Failures.
  defp blocked_work!(workspace) do
    id = Ecto.UUID.generate()
    key = "weekly-blocked:#{id}"

    assert {:ok, _admitted} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:#{workspace}:CREQUESTS",
                   thread_ref: "1790100009.000100",
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "slack:event:#{id}",
                 turn_ref: "turn:#{key}"
               })
             )

    assert {:ok, _session} = Custody.pin_episode(id, "weekly", String.duplicate("a", 64))
    assert {:ok, %{episode: %{id: ^id}, turn: turn}} = Custody.claim_next("weekly", 60, :work)

    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [
        status: :blocked,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil,
        last_error_code: "coop_turn_failed",
        last_error_detail: "the turn failed"
      ]
    )
  end

  # -- Feedback and what to fix ----------------------------------------------------------

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

    %{episode: {:episode, reply.episode.id}, key: reply.episode.key}
  end

  defp signal!(%{episode: request}, kind, value, event, at) do
    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: kind,
               value: value,
               note: if(kind == :reviewed, do: "Checked."),
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:#{event}",
               occurred_at: at,
               request: request
             })
  end

  defp timeline(key), do: "/timeline/" <> URI.encode_www_form(key)

  # A request someone reacted to with a thumbs down, diagnosed as `diagnosis`
  # says, or still waiting for its analysis.
  defp unhappy!(workspace, conversation, ts, diagnosis) do
    request = work_request!(workspace, conversation, ts, "Question #{ts}")
    signal!(request, :reaction_added, "-1", "unhappy-#{ts}", DateTime.utc_now())
    candidate = Improvement.for_request(request.episode)

    if diagnosis do
      Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
        set:
          Keyword.merge(
            [step: :work, expected: "Answers what was asked.", analysis: :done],
            diagnosis
          )
      )
    end

    Repo.get!(Candidate, candidate.id)
  end

  # -- Corrections ---------------------------------------------------------------------

  defp routing!(workspace, channel, ts, response, at) do
    entry = message!(workspace, channel, ts, "Routed #{ts}")

    attempt =
      Repo.insert!(%Attempt{
        input_id: entry.id,
        generation: 1,
        policy: "ryker-admission",
        policy_digest: String.duplicate("b", 64),
        response: Map.put_new(response, "state", "completed")
      })

    backdate!(Attempt, attempt.id, at)
    backdate!(Entry, entry.id, at)
  end

  defp checked!(workspace, channel, ts, history) do
    asked = message!(workspace, channel, ts, "Checked #{ts}")

    reply =
      Answers.work_reply!(
        asked,
        "Checked.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.utc_now()
      )

    Repo.update_all(from(t in Turn, where: t.id == ^reply.turn.id),
      set: [validation_history: history]
    )
  end

  defp reject(violations, at, offset),
    do: %{
      "candidate_attempt" => 1,
      "recorded_at" => at |> DateTime.add(offset) |> DateTime.to_iso8601(),
      "verdict" => "reject",
      "violations" => violations
    }

  defp accept(at, offset),
    do: %{
      "candidate_attempt" => 2,
      "recorded_at" => at |> DateTime.add(offset) |> DateTime.to_iso8601(),
      "verdict" => "accept",
      "violations" => []
    }

  # -- Learned -------------------------------------------------------------------------

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

  defp topic!(workspace, title, visibility, at) do
    key = title |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%ConversationKnowledge{
      id: Ecto.UUID.generate(),
      scope_key: "slack:#{workspace}:CTOPICS",
      topic_key: key,
      transport: "slack",
      workspace_ref: workspace,
      conversation_ref: "slack:#{workspace}:CTOPICS",
      visibility: visibility,
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

  defp topic_id(key),
    do: Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == ^key, select: k.id))

  # -- Cost ----------------------------------------------------------------------------

  defp execution!(at, options) do
    cost = Keyword.get(options, :cost)
    tokens = Keyword.get(options, :input_tokens)

    Repo.insert!(%Execution{
      kind: "work",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      transport: "slack",
      conversation_ref: "slack:TREPORT:CCOST",
      execution_mode: Keyword.get(options, :mode, "live"),
      status: "completed",
      execution_target: Keyword.get(options, :target, "codex:gpt-5.6-terra"),
      usage_recorded: not is_nil(tokens),
      usage_cost_recorded: not is_nil(cost),
      usage_cost_usd: cost && Decimal.new(cost),
      usage_input_tokens: tokens,
      usage_cached_input_tokens: tokens && 0,
      usage_output_tokens: tokens && 0,
      recorded_at: at
    })
  end
end
