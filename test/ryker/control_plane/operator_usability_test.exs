defmodule Ryker.ControlPlane.OperatorUsabilityTest do
  alias Ryker.ControlPlane.UsageChart
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ryker.ControlPlane.{
    BehaviorPage,
    FailureExplanation,
    FailuresPage,
    FindingsPage,
    RepositoriesPage,
    SubscriptionsPage
  }

  alias Ryker.Work.FailureCause

  @now ~U[2026-09-24 12:00:00Z]
  # The requests the failures belong to, by the ids their pages are addressed by, and the message
  # whose reading failed.
  @request_one "0193a5d2-7c1e-7b8a-9f00-00000000e01e"
  @request_two "0193a5d2-7c1e-7b8a-9f00-00000000e02e"
  @input_one "0193a5d2-7c1e-7b8a-9f00-0000000000a1"

  test "a timer follow-up says when work continues without pretending to watch any source" do
    now = ~U[2026-09-07 12:00:00Z]

    document =
      [
        %{
          title: "Timer",
          condition: nil,
          place: nil,
          repository: nil,
          episode_title: "Follow up on the deployment",
          episode_href: "/timeline/#{@request_two}",
          source_label: "Timer",
          target_url: nil,
          cursor_digest: nil,
          deadline_at: ~U[2026-09-07 12:15:00Z],
          episode_ref: "episode:timer",
          last_observed_at: nil,
          last_observation_digest: nil,
          matcher_digest: "matcher-digest",
          poll_after: ~U[2026-09-07 12:10:00Z],
          ref: "subscription:timer",
          revision: 1,
          resolution_kind: nil,
          source_kind: nil,
          status: :active,
          trigger_type: "after",
          updated_at: ~U[2026-09-07 12:00:00Z]
        }
      ]
      |> SubscriptionsPage.list(%{"q" => "", "view" => "current"}, now)
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    row = LazyHTML.query(document, ".entity-row")
    assert LazyHTML.query(row, ".entity-name") |> LazyHTML.text() =~ "Timer"

    assert LazyHTML.query(row, ".entity-meta time[datetime='2026-09-07T12:10:00Z']")
           |> LazyHTML.text() == "in 10 minutes"

    text = LazyHTML.text(row)
    refute text =~ "matching update"
    refute text =~ "stops waiting"
    refute text =~ ~r/\bany\b/
    refute text =~ "External event subscriptions"
  end

  test "an entry's overflow control says which entry it acts on and never hides the ordinary action" do
    # A "⋯" glyph is not a name. A screen reader user tabbing through twenty
    # rules hears "More actions for Triage deployment alerts", not "button"
    # twenty times, and the ordinary Pause or Resume stays visible beside it
    # rather than folded into the same menu as Delete. Entries that can no
    # longer change carry their state in words, not only in a colour.
    entry = fn status ->
      render_component(&BehaviorPage.rules/1,
        view: %{
          kinds: [:standing_assignment],
          items: [
            %{
              kind: :standing_assignment,
              ref: "behavior:one",
              payload: %{
                "source_kind" => "webhook",
                "task" => "Triage the alert.",
                "title" => "Triage deployment alerts"
              },
              status: status,
              scope_kind: :workspace,
              scope_ref: "slack:T123",
              workspace_ref: "slack:T123",
              confirmed_at: ~U[2026-09-06 12:00:00Z],
              use_count: 0,
              last_used_at: nil,
              expires_at: nil,
              source_conversation_ref: "slack:T123:C456",
              source_message_ref: "1787832000.000100"
            }
          ],
          counts: %{},
          total: 1,
          page: 1,
          pages: 1,
          runs: [],
          params: %{"q" => "", "view" => "current", "show" => "all"}
        }
      )
      |> LazyHTML.from_fragment()
    end

    for {status, ordinary} <- [{"active", "Pause"}, {"disabled", "Resume"}] do
      document = entry.(status)
      actions = LazyHTML.query(document, "article .entity-actions")

      assert LazyHTML.query(document, "article .entity-actions > form.action-control button")
             |> LazyHTML.text() == ordinary

      summary = LazyHTML.query(actions, "details.behavior-menu > summary")
      assert LazyHTML.text(summary) =~ "More actions for Triage deployment alerts"
      assert LazyHTML.query(summary, ".sr-only") |> LazyHTML.text() =~ "More actions"

      delete = LazyHTML.query(actions, "details.behavior-menu button")
      assert LazyHTML.text(delete) == "Delete"
      assert LazyHTML.attribute(delete, "class") == ["ui-button danger"]
      assert LazyHTML.text(LazyHTML.query(document, "article .entity-meta")) =~ "not used yet"
    end

    for {status, word} <- [
          {"expired", "Expired"},
          {"deleted", "Deleted"},
          {"superseded", "Replaced"}
        ] do
      document = entry.(status)
      assert Enum.empty?(LazyHTML.query(document, "form.action-control"))

      # Its menu still opens the original conversation, so its state sits
      # beside its name rather than against the menu.
      assert LazyHTML.query(document, "article h3.entity-name .state-word") |> LazyHTML.text() ==
               word
    end
  end

  test "findings say what puts one there and never offer to create one" do
    html =
      FindingsPage.html(%{items: [], total: 0, page: 1, pages: 1}) |> IO.iodata_to_binary()

    assert html =~ "No findings yet"
    assert html =~ "When Ryker investigates a problem, it saves what it concluded here"
    refute html =~ "Create finding"
  end

  # The September 2 failure was displayed as coop_error and a hash.
  test "a cleanup the worker refused says what the worker answered, never a digest" do
    row = %{
      kind: "retention",
      ref: "session:one",
      episode_ref: "episode:one",
      episode_id: @request_one,
      status: :blocked,
      summary: "coop_error",
      updated_at: ~U[2026-09-02 13:56:40Z],
      request_title: "Hi",
      request_state: :complete,
      source: "ryker",
      action: :rearm,
      attempt_count: 2,
      cleanup_phase: :plan_pending,
      closed_at: ~U[2026-09-02 13:56:40Z],
      discarded_at: nil,
      diagnosis: %{http_status: 409, code: "invalid_session_state"},
      detail: "stored diagnostic sha256:abc"
    }

    detail = row |> FailuresPage.detail(@now) |> IO.iodata_to_binary()
    document = LazyHTML.from_fragment(detail)

    assert detail =~ "The worker refused this cleanup step (invalid session state)."

    assert LazyHTML.query(document, ".failure-status a[href='/timeline/#{@request_one}']")
           |> LazyHTML.text() == "Hi"

    # What the worker answered is part of what happened; the stored diagnostic's digest is on no
    # page.
    assert document |> LazyHTML.query("#failure-summary") |> LazyHTML.text() =~
             ~r/Worker response:\s+HTTP 409/

    refute detail =~ "stored diagnostic sha256"
    refute [row] |> FailuresPage.list(@now) |> IO.iodata_to_binary() =~ "stored diagnostic"

    pending =
      %{row | request_state: :working} |> FailuresPage.detail(@now) |> IO.iodata_to_binary()

    refute pending =~ "the request finished"

    one_attempt = %{row | attempt_count: 1}

    for rendered <- [
          FailuresPage.detail(one_attempt, @now),
          FailuresPage.list([one_attempt], @now)
        ] do
      text = rendered |> IO.iodata_to_binary() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert text =~ "1 attempt"
      refute text =~ "1 attempts"
    end
  end

  # Operators could not tell what recovery would do; internal queue terms were
  # the labels, and "Resume cleanup" said nothing about whether it would work.
  test "a failure says what its action will do before it is taken" do
    rows = [
      %{
        kind: "delivery",
        ref: "delivery:one",
        action: :rearm,
        attempt_count: 8,
        delivery_kind: :message,
        status: :blocked,
        summary: "delivery_rate_limited",
        updated_at: ~U[2026-09-24 11:00:00Z]
      },
      %{
        kind: "slack_interaction",
        ref: "interaction:one",
        action: :rearm,
        action_id: "ryker_confirm_memory",
        attempt_count: 8,
        outcome: :confirmed,
        status: :blocked,
        summary: "slack_interaction_repaint_error",
        updated_at: ~U[2026-09-24 11:00:00Z]
      }
    ]

    document =
      rows |> FailuresPage.list(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    refute LazyHTML.text(document) =~ "Rearm"

    # Each action is addressed by its record's id; a kind with no prefix keeps the reference.
    paths = ["/actions/delivery/one/rearm", "/actions/slack_interaction/interaction:one/rearm"]
    articles = LazyHTML.query(document, "article.failure-row")

    for {row, article, path} <- Enum.zip([rows, articles, paths]) do
      explanation = FailureExplanation.explain(row, @now)
      next = LazyHTML.query(article, ".failure-next") |> LazyHTML.text()

      # The line under the facts names the step and says what it does. The
      # whole row opens the failure's page (Andrew, 2026-09-28: a row that
      # opens something carries no buttons), where the step is the one
      # primary button.
      assert Enum.empty?(LazyHTML.query(article, "form, .ui-button"))
      assert next =~ explanation.button.label
      [_label, effect] = String.split(next, ":", parts: 2)
      assert String.trim(effect) == hd(Enum.filter(explanation.options, & &1[:path])).effect

      button = row |> detail() |> LazyHTML.query("form[method='get'][action='#{path}'] button")
      assert LazyHTML.text(button) == explanation.button.label
      assert LazyHTML.attribute(button, "class") == ["ui-button primary"]
    end

    assert LazyHTML.text(document) =~ "Post the reply again"
    assert LazyHTML.text(document) =~ "never appears twice"
    assert LazyHTML.text(document) =~ "Update the message again"
  end

  test "an action that cannot work yet is not offered as the primary step" do
    # Ryker is out of the channel: pressing retry would be refused again, so
    # the row offers the change that has to come first, and where to make it.
    row = %{
      kind: "delivery",
      ref: "delivery:one",
      action: :rearm,
      attempt_count: 1,
      delivery_kind: :message,
      destination: "slack:T123:C456 / 1787832000.001",
      provider_error: "not_in_channel",
      slack: %{connection: :ready, membership: :left, renewed_at: nil},
      status: :blocked,
      summary: "delivery_reconciliation_failed",
      updated_at: ~U[2026-09-24 11:00:00Z]
    }

    list = [row] |> FailuresPage.list(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
    assert LazyHTML.query(list, ".state-word") |> LazyHTML.text() == "Fix needed first"
    assert Enum.empty?(LazyHTML.query(list, "form[action^='/actions/']"))
    assert LazyHTML.query(list, ".failure-next") |> LazyHTML.text() =~ "invite Ryker"

    # On the failure's page, the change that has to come first is the
    # primary step, and the retry that would fail is not.
    detail = detail(row)

    assert LazyHTML.query(
             detail,
             "a.ui-button.primary[href='https://slack.com/app_redirect?team=T123&channel=C456']"
           )
           |> Enum.count() == 1

    retry = LazyHTML.query(detail, "form[action='/actions/delivery/one/rearm'] button")
    assert LazyHTML.attribute(retry, "class") == ["ui-button secondary"]
    assert LazyHTML.text(detail) =~ "Fails until fixed"

    # Once Ryker is back in the channel, the same failure offers the retry.
    rejoined = put_in(row, [:slack, :membership], :joined)

    list =
      [rejoined] |> FailuresPage.list(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    assert LazyHTML.query(list, ".state-word") |> LazyHTML.text() == "Retry should work"

    retry =
      rejoined
      |> detail()
      |> LazyHTML.query("form[action='/actions/delivery/one/rearm'] button")

    assert LazyHTML.attribute(retry, "class") == ["ui-button primary"]
  end

  test "a stuck publication says why it is stuck" do
    # The first screenshot of the new Publishing rows showed three of them
    # reading "No recognized error explanation is available in the saved
    # record." while the host held the exact code for each.
    rows = [
      %{
        kind: "publication",
        ref: "publication:one",
        episode_ref: "episode:one",
        episode_id: @request_one,
        action: nil,
        attempt_count: 3_127,
        source: "ryker",
        status: :review_pending,
        summary: "publication_coop_protocol_error",
        updated_at: nil
      },
      %{
        kind: "publication",
        ref: "publication:two",
        episode_ref: "episode:two",
        episode_id: @request_two,
        action: nil,
        attempt_count: 1_330,
        source: "ryker",
        status: :publish_pending,
        summary: "publication_repository_not_configured",
        updated_at: nil
      }
    ]

    html = rows |> FailuresPage.list(@now) |> IO.iodata_to_binary()

    assert html =~ "Opening a pull request stopped"
    # A closed session ends its publication on its own and never reaches this
    # page; the protocol error left here is an answer Ryker could not read.
    assert html =~ "did not match what Ryker expected"
    refute html =~ "no longer open"
    assert html =~ "Pull requests are not set up for the ryker repository"
    refute html =~ "/actions/publication/"
    refute html =~ "No recognized error explanation"

    # Where to fix it is on the failure's own page, which the row opens.
    assert rows
           |> Enum.at(1)
           |> detail()
           |> LazyHTML.query("a[href='/integrations/github']")
           |> Enum.count() >= 1
  end

  # 2026-09-26: the model account behind routing ran out of usage for three
  # days, and every message stopped with "The saved error does not name a
  # cause Ryker recognises" while the saved error held the provider's own
  # sentence saying so and when it would run again.
  test "a model account out of usage says so, when it comes back, and what to do" do
    detail =
      ~s({:coop_turn_failed, "failed", "rate_limited", "provider rate limited the turn: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 29th, 2026 8:59 PM."})

    assert %{cause: cause, next_step: next_step} = FailureCause.explain(detail)
    assert cause =~ "usage limit"
    assert cause =~ "Sep 29th, 2026 8:59 PM"
    assert next_step =~ "credits"

    # The same limit as Coop worded it on 2026-09-09.
    earlier =
      ~s({:coop_turn_failed, "failed", "acp_protocol_error", "provider limit prevented the turn: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 15th, 2026 4:32 PM."})

    assert %{cause: "The model provider limited the worker's account: " <> _} =
             FailureCause.explain(earlier)

    row = %{
      kind: "admission",
      ref: "ingress-input:one",
      action: :rearm,
      attempt_count: 1,
      cause: cause,
      destination: "control_plane:local / conversation",
      status: :blocked,
      summary: "rate_limited",
      updated_at: @now
    }

    explained = FailureExplanation.explain(row, @now)
    assert explained.summary =~ "usage limit"
    # The recovery page's Why row, not only the list's summary, carries the
    # provider's words with when it runs again.
    assert Enum.any?(explained.cause, &(&1 =~ "Sep 29th, 2026 8:59 PM"))
    assert explained.outlook == :fix_first
    assert %{href: "/settings/models", recommended: true} = hd(explained.options)

    assert %{note: note} = Enum.find(explained.options, &(&1.label == "Read the message again"))
    assert note =~ "can run again"
    refute inspect(explained) =~ "does not name a cause"
  end

  # A message whose reading run stopped is read again by a fresh run on its
  # own now, so only one whose runs kept stopping through the whole retry
  # budget reaches this page. The page offered to ask the person to send it
  # again; its retry reads the message again, and the page has to say so,
  # and that Ryker already did that by itself.
  test "a message whose reading runs kept stopping offers another reading, never a note" do
    row = %{
      kind: "admission",
      ref: "ingress-input:one",
      action: :rearm,
      attempt_count: 8,
      destination: "slack:T123:C456 / 1787832000.000100",
      status: :blocked,
      summary: "coop_turn_stopped",
      updated_at: @now
    }

    stopped = FailureExplanation.explain(row, @now)
    assert stopped.outlook == :unknown
    assert stopped.summary =~ "kept stopping"
    assert Enum.any?(stopped.tried, &(&1 =~ "fresh run"))

    assert %{effect: effect} = Enum.find(stopped.options, &(&1.label == "Read the message again"))
    assert effect =~ "decides again how to respond"

    assert {:ok, "Read this message again?", _sentence} =
             FailureExplanation.confirmation(row, "rearm")

    refute inspect(stopped) =~ "send it again"
    refute inspect(stopped) =~ "send this message again"
  end

  # A deleted incident-room channel used to leave the room blocked with a
  # refused retry, counting against the room limit. It closes on its own now.
  test "a half-set-up incident room says its channel's deletion closes it" do
    row = %{
      kind: "slack_incident",
      ref: "incident-room:one",
      action: :rearm,
      attempt_count: 8,
      channel_state: :active,
      setup_step: :topic,
      status: :blocked,
      summary: "slack_incident_room_error",
      title: "Checkout errors",
      updated_at: @now
    }

    explained = FailureExplanation.explain(row, @now)
    assert %{effect: left} = Enum.find(explained.options, &(&1.label == "Leave it"))
    assert left =~ "If its channel is deleted in Slack, Ryker closes the room"
    assert Enum.any?(explained.affects, &(&1 =~ "until its channel is deleted in Slack"))
  end

  test "a stuck task on the Failures list says why, in its recovery brief's words" do
    # On 2026-09-18 a task blocked by a stalled worker read "No recognized
    # error explanation" on this list while its own recovery brief, one click
    # away, named the cause. Two surfaces describing one failure differently
    # is the defect FailureCause exists to prevent.
    row = %{
      kind: "work",
      ref: "episode:one",
      episode_ref: "episode:one",
      episode_id: @request_one,
      action: :retry,
      attempt_count: 1,
      status: :blocked,
      summary: "work_execution_blocked",
      updated_at: nil,
      work_recovery: %{
        action: :retry,
        action_label: "Run the task again",
        cause: "The worker did not take or finish one of this task's commands in time.",
        explained: true,
        retry_effect: "Ryker starts the task again as a new run."
      }
    }

    html = [row] |> FailuresPage.list(@now) |> IO.iodata_to_binary()
    assert html =~ "The worker did not take or finish one of this task"
    refute html =~ "No recognized error explanation"

    # A brief that names nothing leaves this list its own plain sentence.
    unexplained = put_in(row, [:work_recovery, :explained], false)
    html = [unexplained] |> FailuresPage.list(@now) |> IO.iodata_to_binary()
    assert html =~ "The task stopped before Ryker could confirm why."
  end

  test "a stalled worker is named as the cause of any stopped operation" do
    # Three learning cleanups stopped on 2026-09-18 when the only worker quit
    # polling for ninety seconds, and each read "No recognized error
    # explanation" here while the saved code said exactly what happened.
    row = %{
      kind: "retention",
      ref: "ryker-learning:one",
      action: :rearm,
      attempt_count: 1,
      execution_kind: :learning,
      status: :blocked,
      summary: "coop_worker_command_timeout",
      updated_at: nil
    }

    html = [row] |> FailuresPage.list(@now) |> IO.iodata_to_binary()
    assert html =~ "The worker did not take or finish the cleanup step in time."
    assert html =~ "Background learning"

    # A learning cleanup from before a policy re-pin could not be placed back
    # on its worker, and read as unexplained too.
    unplaceable = %{row | summary: "coop_session_replacement_required"}
    html = [unplaceable] |> FailuresPage.list(@now) |> IO.iodata_to_binary()
    assert html =~ "could not take it back then"
  end

  # The old summary led with "4 failures · 2 affected requests" and an eight
  # cell breakdown by internal area, which told an operator nothing about
  # whether anyone was waiting.
  test "the counts say who is affected before how many, and housekeeping comes last" do
    cleanup = %{
      kind: "retention",
      ref: "session:one",
      episode_ref: "episode:one",
      episode_id: @request_one,
      action: :rearm,
      status: :blocked,
      summary: "coop_error",
      updated_at: ~U[2026-09-23 12:00:00Z]
    }

    rows = [
      cleanup,
      %{cleanup | ref: "session:two"},
      %{
        cleanup
        | kind: "delivery",
          ref: "delivery:one",
          episode_ref: "episode:two",
          episode_id: @request_two
      },
      %{
        cleanup
        | kind: "admission",
          ref: "ingress-input:" <> @input_one,
          episode_ref: nil,
          episode_id: nil
      }
    ]

    document =
      rows |> FailuresPage.list(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    counts =
      document
      |> LazyHTML.query(".kit-counts .kit-count")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert counts == ["2 affect people", "2 housekeeping", "1 d since the oldest stopped"]

    assert LazyHTML.query(document, ".kit-counts .kit-count[data-tone=warn]")
           |> LazyHTML.text() =~ "affect people"

    assert LazyHTML.query(document, ".section-head h2") |> Enum.map(&LazyHTML.text/1) == [
             "Affects people",
             "Housekeeping"
           ]

    assert Enum.count(LazyHTML.query(document, "#affects-people ~ .entity-list article")) == 2
    assert Enum.count(LazyHTML.query(document, "article.failure-row")) == 4

    # Cleanup alone has no people section at all.
    only_cleanup = [cleanup] |> FailuresPage.list(@now) |> IO.iodata_to_binary()
    refute only_cleanup =~ "Affects people"
  end

  test "Housekeeping never says nobody waits over rows that need the reader" do
    # QA, 2026-09-25: Housekeeping said "Nobody is waiting on these" while each
    # of its rows was tagged "Needs you". No reply waits on them, but a person
    # still has to decide, as stopped learning does.
    learning = %{
      kind: "learning",
      ref: "batch:one",
      action: nil,
      attempt_count: 3,
      execution_kind: :learning,
      input_count: 2,
      learning_path: "/memory/learning?batch=one",
      status: :deferred,
      summary: "learning_retry_exhausted",
      updated_at: ~U[2026-09-23 12:00:00Z]
    }

    document =
      [learning]
      |> FailuresPage.list(@now)
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "#housekeeping ~ .entity-list .state-word")
           |> LazyHTML.text() == "Needs you"

    lede = document |> LazyHTML.query(".section-head p") |> LazyHTML.text()
    refute lede =~ "Nobody is waiting"
    assert lede =~ "No reply, update or result depends on these"
  end

  test "a reply moved out of a deleted incident room says where it went, in one line" do
    # The line said the reply went to "the alert thread the room was opened
    # from", which names no place a person can open.
    row = %{
      kind: "delivery",
      ref: "delivery:moved",
      action: :retry,
      delivery_kind: :message,
      destination: "slack:T123:C0ALERTS / 1787832000.000100",
      incident_room: %{channel_name: "inc-checkout", channel_state: :deleted, reply: :moved},
      status: :blocked,
      summary: "slack_transport_error",
      updated_at: ~U[2026-09-24 11:00:00Z]
    }

    place = FailureExplanation.place(row)
    explained = FailureExplanation.explain(row, @now)

    assert Enum.filter(explained.happened, &(&1 =~ "inc-checkout")) == [
             "Moved from the incident room #inc-checkout, which was deleted in Slack, to the alert thread in #{place}."
           ]
  end

  test "an empty Failures page says nothing needs you and what would put something here" do
    document = [] |> FailuresPage.list(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".kit-empty-title") |> LazyHTML.text() ==
             "Nothing needs you"

    assert LazyHTML.text(document) =~ "When Ryker can't finish something by itself"
    assert Enum.empty?(LazyHTML.query(document, ".kit-counts"))
  end

  # Andrew, 2026-10-03, of a failure's Technical details: ""Technical details" can be dropped?"
  # The fold under every failure held its references, a digest of its stored diagnostic and its
  # conversation's raw reference, with copy buttons drawn as green squares. What its sources said
  # is a row of what happened now, and no reference is on the page.
  test "a failure's page says what happened and what to do, and shows no references" do
    html =
      FailuresPage.detail(
        %{
          kind: "retention",
          ref: "session:one",
          episode_ref: "episode:one",
          episode_id: @request_one,
          status: :blocked,
          summary: "coop_error",
          detail: "stored diagnostic sha256:" <> String.duplicate("a", 64),
          destination: "control_plane:control-plane:lab:one / control-plane:lab:one",
          updated_at: ~U[2026-09-05 12:00:00Z]
        },
        @now
      )
      |> IO.iodata_to_binary()

    document = LazyHTML.from_fragment(html)

    # Andrew, 2026-09-28: four headed runs of prose were "not usable". Two
    # cards: what happened in labelled rows, then what a person can do.
    assert LazyHTML.query(document, ".section-head h2") |> Enum.map(&LazyHTML.text/1) == [
             "What happened",
             "What you can do"
           ]

    assert LazyHTML.query(document, "#failure-summary .failure-rows dt")
           |> Enum.map(&LazyHTML.text/1) == [
             "What stopped",
             "Why",
             "Who is waiting",
             "What Ryker tried"
           ]

    assert html =~ "Open the request"
    assert html =~ "Direct conversation"
    refute html =~ "Conversation Lab"

    assert LazyHTML.query(document, "details#failure-technical") |> Enum.empty?()
    refute html =~ "data-copy-value"
    words = LazyHTML.text(document)

    for reference <- ["session:one", "sha256", "control-plane:lab:one"],
        do: refute(words =~ reference, reference)

    # An error Ryker has no words for is shown as it was saved, once, in the
    # sentence that says so (Andrew, 2026-10-03: "show an error").
    assert words =~ ~s(The saved error is "coop_error".)
    assert length(String.split(words, "coop_error")) == 2
  end

  test "a stopped task's page says the cause the worker gave, not only that it stopped" do
    # The page's Cause row read "The task stopped before the worker finished
    # it." while the worker's actual refusal (a repository had moved) reached
    # only the Failures list, so the one page meant to explain the failure
    # explained nothing.
    cause =
      "The worker refused to set up the task's code: a repository it reads has moved since the task began."

    document =
      %{
        kind: "work",
        ref: "task-offer:record:task_offer:one",
        episode_ref: "task-offer:record:task_offer:one",
        episode_id: @request_one,
        action: :retry,
        attempt_count: 8,
        status: :blocked,
        summary: "work_execution_blocked",
        destination: "slack:T1:C1",
        updated_at: ~U[2026-09-05 12:00:00Z],
        work_recovery: %{action: :retry, cause: cause, explained: true}
      }
      |> FailuresPage.detail(@now)
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    rows =
      document
      |> LazyHTML.query("#failure-summary .failure-rows > div")
      |> Enum.map(fn row ->
        {LazyHTML.query(row, "dt") |> LazyHTML.text(),
         LazyHTML.query(row, "dd") |> LazyHTML.text()}
      end)
      |> Map.new()

    assert rows["Why"] =~ cause

    assert LazyHTML.query(document, "#failure-options .section-head") |> LazyHTML.text() =~
             "depends on the cause above"
  end

  test "search keeps an accessible label bound to its input instead of an extra column" do
    # The label once sat in its own grid column; it then became a visible
    # caption above the field. The shared toolbar groups the icon, label and
    # input in one search-field while retaining the explicit label binding.
    document =
      %{items: [], total: 0, view: RepositoriesPage.view(%{}), now: nil}
      |> RepositoriesPage.html()
      |> LazyHTML.from_fragment()

    assert outline(document, "form.filter-toolbar > *") |> List.first() == "div.search-field"

    assert LazyHTML.query(document, "form.filter-toolbar label[for=operator-search]")
           |> LazyHTML.text() == "Search repositories"

    assert LazyHTML.query(document, "form.filter-toolbar input#operator-search[name=q]")
           |> LazyHTML.attribute("placeholder") == ["Search repositories"]
  end

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end

  test "daily graph keeps calendar spacing and accessible values without an extra table" do
    days = [
      %{date: ~D[2026-09-01], tokens: 1000, attempts: 2, measured: 2},
      %{date: ~D[2026-09-03], tokens: 2000, attempts: 3, measured: 2}
    ]

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    assert html =~ "<svg"
    assert html =~ "2026-09-02"
    assert html =~ "1,000"
    refute html =~ "Daily values"
    refute html =~ "<table"
    assert html =~ "02 Sep: 0 tokens"
    assert html =~ "tabindex=\"0\""
  end

  # Four bars for 2-5 September were labelled 2, 4, 5: the operator read the
  # unlabelled third day as missing data, even though it had executions.
  test "short daily charts label every day without a standing disclaimer" do
    days =
      for day <- 2..5,
          do: %{date: Date.new!(2026, 9, day), tokens: 1000, attempts: 1, measured: 1}

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    labels = Regex.scan(~r/<text class="chart-axis"[^>]*>([^<]+)<\/text>/, html)
    assert Enum.any?(labels, fn [_, label] -> label == "03 Sep" end)
    refute html =~ "empty days remain on the axis"
  end

  test "sparse multi-year usage cannot expand into an unbounded daily chart" do
    days = [
      %{date: ~D[2000-01-01], tokens: 1000, attempts: 2, measured: 2},
      %{date: ~D[2026-09-05], tokens: 2000, attempts: 3, measured: 2}
    ]

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    assert length(Regex.scan(~r/<rect /, html)) <= 366
    assert html =~ "latest 366 calendar days"
  end

  defp detail(row),
    do: row |> FailuresPage.detail(@now) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
end
