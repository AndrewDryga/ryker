defmodule Ryker.ControlPlane.MemoryPageTest do
  @moduledoc """
  The Memory pages as the shell renders them (2026-09-24 redesign): Facts,
  Learned and Learning, each a list of rows on the page with state in words,
  every action behind its existing confirmation, and no help disclosure or
  hidden settings. The old /memory stacked all of this into one page with a
  "How memory works" disclosure and a "Learning settings" drawer at the end.
  Deterministic views; no database.
  """
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{CSRF, FactsPage, LearnedPage, LearningActivity, LearningPage}
  alias Ryker.ControlPlane.{MemoryFormat, PageHelp, Pages}

  @at ~U[2026-09-10 09:00:00Z]
  @secret String.duplicate("s", 32)
  @topic_id "11111111-1111-4111-8111-111111111111"
  @batch_id "22222222-2222-4222-8222-222222222222"

  @fact %{
    kind: :entity_relationship,
    ref: "memory:one",
    scope: :conversation,
    scope_ref: "slack:T123:C456",
    applicability: nil,
    value: "the payments gateway",
    status: :active,
    subject: "pay-gw",
    recall_count: 9,
    last_recalled_at: nil,
    confirmed_at: @at
  }

  @reviews [
    %{
      "entries" => [
        %{
          "kind" => "entity_relationship",
          "memory_ref" => "memory:one",
          "scope" => "workspace",
          "scope_ref" => "slack:T123",
          "subject" => "checkout-api",
          "value" => "payments",
          "source_type" => "memory"
        },
        %{
          "kind" => "entity_relationship",
          "memory_ref" => "memory:duplicate",
          "scope" => "workspace",
          "scope_ref" => "slack:T123",
          "subject" => "payments-api",
          "value" => "payments",
          "source_type" => "memory"
        }
      ],
      "kind" => "duplicate",
      "reason" => "These entries have the same meaning in the same scope.",
      "review_ref" => "memory-review:one",
      "status" => "pending"
    },
    %{
      "entries" => [
        %{
          "kind" => "repository_binding",
          "memory_ref" => "memory:two",
          "scope" => "repository",
          "scope_ref" => "ryker",
          "subject" => "primary_repository",
          "value" => "password=review-secret-value",
          "recall_count" => 0,
          "confirmed_at" => "2026-06-01T09:00:00Z",
          "source_type" => "memory"
        }
      ],
      "kind" => "stale",
      "reason" => "This memory has not been recalled or reviewed recently.",
      "review_ref" => "memory-review:two",
      "status" => "pending"
    }
  ]

  @topic %{
    id: @topic_id,
    title: "Deploy window decision",
    conversation: "#infra",
    conversation_path: "/activity?conversation=slack:T123:C456",
    workspace: nil,
    at: @at,
    changed_at: @at,
    source_at: @at,
    repository: "ryker",
    text: "Deploys happen after **15:00 UTC** on weekdays.\n\n- Freeze on Fridays",
    groups: [],
    source: nil,
    available: true,
    source_count: 2,
    source_path: "/memory/learned?kind=sources&related_to=knowledge:#{@topic_id}",
    version: 3,
    request_path: nil,
    expires_at: nil
  }

  @learned %{
    counts: %{context: 2, knowledge: 3},
    kind: "knowledge",
    q: "",
    page: 1,
    pages: 1,
    total: 1,
    related_to: nil,
    source_parent: nil,
    selected: nil,
    rebuild: nil,
    history: [],
    history_page: 1,
    history_pages: 1,
    items: [@topic]
  }

  @summary %{
    id: "summary-1",
    title: "Validation schedule",
    conversation: "#infra",
    conversation_path: "/activity?conversation=slack:T123:C456",
    workspace: nil,
    at: @at,
    changed_at: @at,
    source_at: nil,
    repository: nil,
    text: "Validating the nightly schedule.",
    groups: [{"Decisions", ["Run at 02:00 UTC"]}, {"Open work", ["Verify the first run"]}],
    source: nil,
    source_count: 0,
    source_path: nil,
    request_path: "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e",
    expires_at: DateTime.add(@at, 30 * 86_400),
    recall_warning: nil,
    maintenance_error: nil,
    maintenance_retry_at: nil
  }

  @deferred %{
    id: @batch_id,
    status: :deferred,
    label: "Needs attention",
    conversation: "#infra",
    conversation_path: "/activity?conversation=slack:T123:C456",
    repository: "ryker",
    mode: :live,
    input_count: 1,
    start_count: 3,
    start_limit: 3,
    budget_version: 0,
    at: @at,
    completed_at: nil,
    next_check: nil,
    error: "Ryker used every try it had. Look at the attempts before you give it one more.",
    error_code: "learning_retry_exhausted",
    path: "/memory/learning?batch=#{@batch_id}"
  }

  @applied %{
    @deferred
    | id: "33333333-3333-4333-8333-333333333333",
      status: :applied,
      label: "Knowledge updated",
      error: nil,
      error_code: nil,
      path: "/memory/learning?batch=33333333-3333-4333-8333-333333333333"
  }

  @activity %{
    state: :on,
    enabled: true,
    worker_running: true,
    counts: %{queued: 0, running: 0, applied: 1, no_change: 0, deferred: 1, superseded: 0},
    waiting_inputs: 25,
    oldest_waiting_at: nil,
    attention: %{items: [@deferred], page: 1, pages: 1, total: 1},
    recent: %{items: [@applied], page: 1, pages: 1, total: 1, outcome: ""},
    handover_failures: %{total: 0, items: [], page: 1, pages: 1},
    selected: nil
  }

  describe "Facts" do
    test "a fact reads as its name, what it says and where it applies, and forgetting it asks first" do
      document = facts(%{memories: [@fact], reviews: [], memory_total: 1, q: ""})
      row = LazyHTML.query(document, "article.entity-row#fact-memory-one")

      assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() |> String.trim() ==
               "pay-gw"

      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() == "the payments gateway"
      meta = LazyHTML.query(row, ".entity-meta") |> LazyHTML.text()
      assert meta =~ "In Slack channel C456"
      assert meta =~ "Used 9 times"
      assert meta =~ "Saved"
      refute meta =~ "slack:T123:C456"

      assert Enum.count(LazyHTML.query(row, ".entity-meta time[datetime='2026-09-10T09:00:00Z']")) ==
               1

      forget =
        LazyHTML.query(
          row,
          "form.action-control[method=get][action='/actions/memory/one/forget'] button.ui-button.secondary"
        )

      assert LazyHTML.text(forget) == "Forget"

      # How to add a fact is the page's help, not a line under the list.
      assert Enum.empty?(
               LazyHTML.query(document, "form[method=post], table, .ask-hint, .page-help")
             )

      help = PageHelp.for_path("/memory")

      assert Enum.map_join(help.sections, " ", &Enum.join(&1.paragraphs, " ")) =~
               ~s("Remember that pay-gw is the payments gateway.")
    end

    test "a global fact says it applies everywhere and what for, never its internal scope" do
      global = %{
        @fact
        | scope: :global,
          scope_ref: "installation:0123456789abcdef",
          applicability: "Production portal in acme/portal",
          recall_count: 0
      }

      meta =
        facts(%{memories: [global], reviews: []})
        |> LazyHTML.query(".entity-meta")
        |> LazyHTML.text()

      assert meta =~ "Everywhere"
      assert meta =~ "Applies to Production portal in acme/portal"
      assert meta =~ "Not used yet"
      refute meta =~ "installation:"
    end

    # Manual test, 2026-10-09: a fact confirmed in Chat "for everyone" read "Across the
    # workspace", and no other chat could recall it: a Chat conversation is its own workspace.
    test "a fact saved in Chat for the workspace says it holds in that conversation" do
      chat = %{@fact | scope: :workspace, scope_ref: "control-plane:lab:6d7364ad-1a45-45b8"}

      meta =
        facts(%{memories: [chat], reviews: []})
        |> LazyHTML.query(".entity-meta")
        |> LazyHTML.text()

      assert meta =~ "In Direct conversation"
      refute meta =~ "Across the workspace"
      refute meta =~ "control-plane:"
    end

    test "facts that may be out of date or saved twice are called out once and settled in their own section" do
      # Before 2026-09-24 reviews were a table of raw enums ("Duplicate"),
      # scope refs and ISO stamps under a heading nobody could act on first.
      document = facts(%{memories: [@fact], reviews: @reviews, memory_total: 1, q: ""})

      callout = LazyHTML.query(document, ".memory-callout")

      assert LazyHTML.text(callout) =~
               "3 facts may be out of date or saved more than once."

      assert LazyHTML.query(callout, "a[href='#review']") |> LazyHTML.text() == "Review"

      section = LazyHTML.query(document, "section#review")
      assert LazyHTML.query(section, ".section-head h2") |> LazyHTML.text() == "Needs review"

      duplicate = LazyHTML.query(section, "article#review-memory-review-one")

      assert LazyHTML.query(duplicate, "h3.entity-name") |> LazyHTML.text() =~
               "checkout-api and payments-api"

      assert LazyHTML.query(duplicate, ".state-word[data-tone=warn]") |> LazyHTML.text() ==
               "Saved more than once"

      assert actions(duplicate) == [
               {"Keep separate", "/actions/memory-review/memory-review:one/keep"},
               {"Merge", "/actions/memory-review/memory-review:one/merge"},
               {"Forget", "/actions/memory-review/memory-review:one/forget"}
             ]

      stale = LazyHTML.query(section, "article#review-memory-review-two")

      assert LazyHTML.query(stale, ".state-word[data-tone=warn]") |> LazyHTML.text() ==
               "May be out of date"

      assert LazyHTML.query(stale, ".entity-meta") |> LazyHTML.text() =~ "Repository link"

      assert actions(stale) == [
               {"Keep", "/actions/memory-review/memory-review:two/keep"},
               {"Edit", "/actions/memory-review/memory-review:two/edit"},
               {"Forget", "/actions/memory-review/memory-review:two/forget"}
             ]

      # A reviewed value is a person's own words and is redacted like a fact.
      refute LazyHTML.text(document) =~ "review-secret-value"
      assert Enum.empty?(LazyHTML.query(document, "form[method=post]"))
    end

    test "a search keeps its words, and a miss is told apart from having no facts" do
      miss = facts(%{memories: [], reviews: [], memory_total: 3, q: "deploy"})
      toolbar = LazyHTML.query(miss, "form.filter-toolbar[action='/memory'][method=get]")
      assert LazyHTML.query(toolbar, "input[name=q]") |> LazyHTML.attribute("value") == ["deploy"]

      assert LazyHTML.query(toolbar, "a.filter-clear") |> LazyHTML.attribute("href") == [
               "/memory"
             ]

      assert LazyHTML.text(miss) =~ ~s(No facts match "deploy")
      refute LazyHTML.text(miss) =~ "No facts yet"

      none = facts(%{memories: [], reviews: [], memory_total: 0, q: ""})
      assert LazyHTML.text(none) =~ "No facts yet"
      assert Enum.empty?(LazyHTML.query(none, "form.filter-toolbar, .memory-callout, .ask-hint"))
    end

    test "a stale fact is corrected in a labelled form that says what it is for" do
      [_duplicate, stale] = @reviews

      document =
        FactsPage.edit_form(stale, "/actions/memory-review/memory-review:two/edit", "token")
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      form = LazyHTML.query(document, "form.memory-edit[method=post]")

      assert LazyHTML.attribute(form, "action") == [
               "/actions/memory-review/memory-review:two/edit"
             ]

      assert LazyHTML.query(form, "label[for=memory-edit-subject]") |> LazyHTML.text() =~
               "What it is about"

      assert LazyHTML.query(form, "label[for=memory-edit-value]") |> LazyHTML.text() =~
               "What to remember"

      assert LazyHTML.query(form, "input[name=subject]") |> LazyHTML.attribute("value") == [
               "primary_repository"
             ]

      assert LazyHTML.query(form, "button[type=submit]") |> LazyHTML.text() == "Save changes"
      assert LazyHTML.query(form, "a[href='/memory#review']") |> LazyHTML.text() == "Cancel"
    end
  end

  describe "Learned" do
    test "topics open with one search and two views, and each row says where it came from and what backs it" do
      document = learned(@learned)

      toolbar =
        LazyHTML.query(document, ".kit-toolbar form.filter-toolbar[action='/memory/learned']")

      assert LazyHTML.query(toolbar, "input[name=q]") |> LazyHTML.attribute("placeholder") == [
               "Search topics"
             ]

      assert views(document) == [
               {"Topics", "/memory/learned", true},
               {"Conversation summaries", "/memory/learned?kind=context", false}
             ]

      row = LazyHTML.query(document, "article#topic-#{@topic_id}")

      assert LazyHTML.query(row, "h3.entity-name a") |> LazyHTML.attribute("href") == [
               "/memory/learned?item=#{@topic_id}"
             ]

      # A clamped excerpt in plain words: no Markdown marks, no list bullets.
      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() ==
               "Deploys happen after 15:00 UTC on weekdays. Freeze on Fridays"

      links = LazyHTML.query(row, ".entity-meta a")

      assert Enum.zip(Enum.map(links, &LazyHTML.text/1), LazyHTML.attribute(links, "href")) == [
               {"#infra", @topic.conversation_path},
               {"2 sources", @topic.source_path},
               {"3 updates", "/memory/learned?item=#{@topic_id}#history"}
             ]

      assert LazyHTML.query(row, ".entity-meta") |> LazyHTML.text() =~ "ryker"
      assert Enum.empty?(LazyHTML.query(row, ".state-word"))
      assert Enum.empty?(LazyHTML.query(document, "details.page-help, .memory-views, table"))
    end

    test "an excerpt keeps list items apart and drops Markdown marks, ending long text at a word" do
      assert MemoryFormat.excerpt(
               "Limits:\n- Raised to *2 GiB*\n- Watch `p99`\n1. Page on-call",
               nil
             ) ==
               "Limits: Raised to 2 GiB. Watch p99. Page on-call"

      long = MemoryFormat.excerpt(String.duplicate("steady words ", 40), nil)
      assert String.ends_with?(long, "words…") or String.ends_with?(long, "steady…")
      assert String.length(long) <= 281
    end

    test "a topic Ryker no longer uses says why on its state, and its whole row opens the topic" do
      # Andrew, 2026-09-27: why Ryker stopped using a topic was a sentence
      # under its row with "Relearn it" as a link in it. The reason is the
      # state's hint now. Andrew, 2026-09-28: a row opens its item from
      # anywhere on the row, and the item's page relearns or forgets it.
      document = learned(%{@learned | items: [%{@topic | available: false}]})
      row = LazyHTML.query(document, "article#topic-#{@topic_id}")

      state = LazyHTML.query(row, ".entity-side .state-word[data-tone=warn]")
      assert LazyHTML.text(state) == "Not used"

      assert LazyHTML.attribute(state, "title") == [
               "Ryker stopped using this in answers because a message it learned from changed, was removed or expired."
             ]

      assert LazyHTML.attribute(state, "tabindex") == ["0"]
      assert Enum.empty?(LazyHTML.query(row, ".memory-note"))

      assert LazyHTML.attribute(row, "class") |> hd() =~ "entity-row-link"

      assert LazyHTML.query(row, ".entity-name a") |> LazyHTML.attribute("href") == [
               "/memory/learned?item=#{@topic_id}"
             ]

      assert Enum.empty?(LazyHTML.query(row, ".entity-actions, .ui-button, form"))
    end

    test "a search that finds nothing is told apart from a list with nothing learned yet" do
      miss = learned(%{@learned | q: "absent", items: [], total: 0})
      assert LazyHTML.text(miss) =~ ~s(Nothing matches "absent")

      assert LazyHTML.query(miss, "form.filter-toolbar a.filter-clear")
             |> LazyHTML.attribute("href") ==
               ["/memory/learned"]

      nothing = learned(%{@learned | items: [], total: 0})
      assert LazyHTML.text(nothing) =~ "Nothing learned yet"

      summaries = learned(%{@learned | kind: "context", items: [], total: 0, q: "x"})

      assert LazyHTML.query(summaries, "form.filter-toolbar input[type=hidden][name=kind]")
             |> LazyHTML.attribute("value") == ["context"]

      assert LazyHTML.query(summaries, "form.filter-toolbar a.filter-clear")
             |> LazyHTML.attribute("href") == ["/memory/learned?kind=context"]

      assert LazyHTML.text(learned(%{@learned | kind: "context", items: [], total: 0})) =~
               "No conversation summaries yet"
    end

    # Andrew, 2026-09-28, of the summaries list: "you forgot about those when
    # working on design?!" Each summary printed whole, with its decisions and
    # open work. The list is one row each; the rest is on the summary's page.
    test "a conversation summary is one row in the list and a page with its decisions and open work" do
      document = learned(%{@learned | kind: "context", items: [@summary]})
      row = LazyHTML.query(document, "article#summary-summary-1")

      assert row |> LazyHTML.query("h3.entity-name a") |> LazyHTML.attribute("href") ==
               ["/memory/learned?item=summary-1&kind=context"]

      assert Enum.empty?(LazyHTML.query(row, ".memory-summary-groups, details, form, button"))
      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() =~ "Validating the nightly"

      page = learned(%{@learned | kind: "context", selected: "summary-1", items: [@summary]})

      assert LazyHTML.query(page, ".memory-summary-label") |> Enum.map(&LazyHTML.text/1) ==
               ["Decisions", "Open work"]

      assert LazyHTML.query(page, ".memory-summary-groups li") |> LazyHTML.text() =~
               "Run at 02:00 UTC"

      facts = page |> LazyHTML.query("#summary-facts")
      assert LazyHTML.text(facts) =~ "Kept until"

      assert LazyHTML.query(facts, "a[href='/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e']")
             |> LazyHTML.text() ==
               "Open request"

      assert LearnedPage.heading(%{kind: "context", selected: "summary-1", items: [@summary]}).back ==
               {"All summaries", "/memory/learned?kind=context"}

      for {warning, words, retention} <- [
            {:missing_source_history, "no complete record", "No automatic expiry"},
            {:invalid_source_history, "is invalid", "Unknown"}
          ] do
        item = %{@summary | recall_warning: warning, expires_at: nil}

        state =
          learned(%{@learned | kind: "context", items: [item]})
          |> LazyHTML.query("article#summary-summary-1 .state-word[data-tone=warn]")

        assert LazyHTML.text(state) == "Not used"

        page = learned(%{@learned | kind: "context", selected: "summary-1", items: [item]})
        assert LazyHTML.query(page, ".memory-note") |> LazyHTML.text() =~ words
        assert LazyHTML.query(page, "#summary-facts") |> LazyHTML.text() =~ retention
      end
    end

    test "one topic is a page of its own: title, state, text, facts, then each update with its source and how it was learned" do
      # Andrew, 2026-09-27, of /memory/learned?item=…: "this page is not
      # properly designed". It opened under the list's title with a smaller
      # heading of its own, its facts in one run-on line, and Forget and the
      # reason it was not used between them and a collapsed relearning form.
      revision = %{
        version: 2,
        at: @at,
        source_at: @at,
        text: "Deploys happen after 15:00 UTC.",
        source_input_id: nil,
        source: "https://slack.com/archives/C456/p1757494800000000",
        learning_path:
          "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#learning-55555555-5555-4555-8555-555555555555-result"
      }

      view = %{@learned | selected: @topic_id, history: [revision], history_pages: 2}

      heading = LearnedPage.heading(view)
      assert heading.title == "Deploy window decision"
      assert heading.back == {"All topics", "/memory/learned"}
      assert heading.action == nil

      document = learned(view)

      # Forgetting it is the page's last card, as removing is on every
      # item's page; it asks first.
      assert LazyHTML.query(
               document,
               "#forget-topic form[action='/actions/knowledge/#{@topic_id}/forget'] button.danger"
             )
             |> LazyHTML.text() == "Forget topic"

      assert document
             |> LazyHTML.query(".memory-learned > *")
             |> Enum.to_list()
             |> List.last()
             |> LazyHTML.attribute("id") == ["forget-topic"]

      assert Enum.empty?(LazyHTML.query(document, "h1, h2.memory-record-title, .memory-back"))

      topic = LazyHTML.query(document, "article.memory-topic#topic-#{@topic_id}")

      assert LazyHTML.query(topic, "p.kit-status-line .state-word[data-tone=on]")
             |> LazyHTML.text() == "In use"

      assert LazyHTML.query(topic, "p.kit-status-line a[href='#history']") |> LazyHTML.text() =~
               "3 updates"

      assert LazyHTML.query(topic, ".memory-topic-text strong") |> LazyHTML.text() == "15:00 UTC"

      facts = kit_facts(topic)

      assert Enum.map(facts, &elem(&1, 0)) == [
               "Learned in",
               "Repository",
               "Latest message",
               "Kept until",
               "Learned from"
             ]

      assert Map.take(Map.new(facts), ["Learned in", "Repository", "Kept until", "Learned from"]) ==
               %{
                 "Learned in" => "#infra",
                 "Repository" => "ryker",
                 "Kept until" => "No automatic expiry",
                 "Learned from" => "2 messages"
               }

      history = LazyHTML.query(document, "section#history")
      assert LazyHTML.query(history, "h3.entity-name") |> LazyHTML.text() =~ "Update 2"
      assert LazyHTML.query(history, ".entity-meta") |> LazyHTML.text() =~ "From a message sent"
      original = LazyHTML.query(history, ".entity-meta a[target=_blank]")
      assert LazyHTML.attribute(original, "rel") == ["noopener noreferrer"]
      assert LazyHTML.attribute(original, "href") == [revision.source]

      assert LazyHTML.query(history, ".entity-meta a[href='#{revision.learning_path}']")
             |> LazyHTML.text() == "How this was learned"

      assert LazyHTML.query(history, "nav.pagination a") |> LazyHTML.attribute("href") == [
               "/memory/learned?history_page=2&item=#{@topic_id}#history"
             ]

      # How an update was learned is its learning card on the Timeline; the
      # topic page no longer carries a receipt of its own.
      assert Enum.empty?(LazyHTML.query(document, "#learning-receipt"))

      assert Enum.empty?(LazyHTML.query(document, ".kit-toolbar, .ui-eyebrow"))
    end

    test "a record's source messages open under the record they support" do
      source = %{
        @topic
        | id: "source-1",
          title: "",
          text: "The original source message.",
          source: "https://slack.com/archives/C456/p1757494800000000"
      }

      document =
        learned(%{
          @learned
          | kind: "sources",
            related_to: "context:summary-1",
            source_parent: %{
              back_label: "Conversation summaries",
              back_path: "/memory/learned?kind=context#summary-summary-1",
              title: "Validation schedule"
            },
            items: [source]
        })

      heading =
        LearnedPage.heading(%{
          @learned
          | kind: "sources",
            source_parent: %{
              back_label: "Conversation summaries",
              back_path: "/memory/learned?kind=context#summary-summary-1",
              title: "Validation schedule"
            }
        })

      assert heading.title == ~s(Messages behind "Validation schedule")

      assert heading.back ==
               {"Conversation summaries", "/memory/learned?kind=context#summary-summary-1"}

      assert Enum.empty?(LazyHTML.query(document, ".memory-back, .section-head, h1"))

      toolbar =
        LazyHTML.query(document, ".kit-toolbar > form.filter-toolbar[action='/memory/learned']")

      assert LazyHTML.query(toolbar, "input[type=hidden]")
             |> LazyHTML.attribute("value") == ["sources", "context:summary-1"]

      row = LazyHTML.query(document, "article#source-source-1")

      assert LazyHTML.query(row, ".markdown-preview") |> LazyHTML.text() =~
               "The original source message."

      assert LazyHTML.query(row, ".entity-meta a[target=_blank]") |> LazyHTML.text() =~
               "Open message"

      assert Enum.empty?(LazyHTML.query(document, "nav.segmented"))
    end
  end

  describe "Learning" do
    test "the status line says whether learning runs, what waits and what needs a person" do
      three_days_ago = DateTime.add(DateTime.utc_now(), -3 * 86_400 - 60)
      document = learning(%{@activity | oldest_waiting_at: three_days_ago})
      status = LazyHTML.query(document, "p.kit-status-line")

      assert LazyHTML.query(status, ".state-word[data-tone=on]") |> LazyHTML.text() ==
               "Learning is on"

      assert LazyHTML.text(status) =~ "25 messages waiting"
      assert LazyHTML.text(status) =~ "oldest waiting 3 days"

      assert LazyHTML.query(status, "a[href='#needs-attention'][data-tone=warn]")
             |> LazyHTML.text()
             |> String.trim() ==
               "1 needs attention"

      for {state, tone, word, note} <- [
            {:off, "off", "Learning is off", "learns nothing from them until learning is on"},
            {:cannot_start, "warn", "Learning can't start", "no worker or model"},
            {:not_running, "warn", "Learning is not running here", "not running in this Ryker"}
          ] do
        document = learning(%{@activity | state: state})

        assert LazyHTML.query(document, "p.kit-status-line .state-word[data-tone=#{tone}]")
               |> LazyHTML.text() == word

        assert LazyHTML.query(document, ".memory-status-note") |> LazyHTML.text() =~ note
      end

      off =
        learning(%{@activity | state: :off, recent: %{@activity.recent | items: [], total: 0}})

      assert LazyHTML.text(off) =~ "Learning is off, so Ryker is not reading new messages."
      assert Enum.empty?(LazyHTML.query(document, "details.area-settings, details.page-help"))
    end

    test "batches that need a person are listed apart from recent learning, each opening its review" do
      document = learning(@activity)
      attention = LazyHTML.query(document, "section#needs-attention")
      row = LazyHTML.query(attention, "article#batch-#{@batch_id}")

      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() =~
               "used every try it had"

      assert LazyHTML.query(row, ".entity-meta") |> LazyHTML.text() =~ "3 model starts used"
      refute LazyHTML.query(row, ".entity-meta") |> LazyHTML.text() =~ "of 3"

      # The whole row opens the batch; a Review button beside it said the
      # same thing twice.
      assert LazyHTML.attribute(row, "class") |> hd() =~ "entity-row-link"

      assert LazyHTML.query(row, ".entity-name a") |> LazyHTML.attribute("href") == [
               @deferred.path
             ]

      assert Enum.empty?(LazyHTML.query(row, ".entity-actions, .ui-button"))

      recent = LazyHTML.query(document, "section#recent")
      assert Enum.empty?(LazyHTML.query(recent, "article#batch-#{@batch_id}"))

      assert LazyHTML.query(recent, "article .state-word[data-tone=on]") |> LazyHTML.text() ==
               "Knowledge updated"

      assert LazyHTML.query(recent, "nav.segmented a") |> LazyHTML.attribute("href") == [
               "/memory/learning",
               "/memory/learning?outcome=updated",
               "/memory/learning?outcome=no_change",
               "/memory/learning?outcome=in_progress",
               "/memory/learning?outcome=sources_changed"
             ]

      filtered =
        learning(%{
          @activity
          | recent: %{@activity.recent | items: [], total: 0, outcome: "no_change"}
        })

      assert LazyHTML.query(filtered, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
               "No change"

      assert LazyHTML.text(filtered) =~ "Nothing with this outcome yet"
    end

    test "a handover that could not be saved is shown without calling the reply failed" do
      failure = %{
        turn_id: "turn-1",
        conversation: "#infra",
        at: @at,
        explanation:
          "Its source history exceeded the safe memory limit, so no conversation context was saved.",
        response_status: "Reply sent",
        request_path:
          "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e?attempt=turn-1#request-turn-1"
      }

      document =
        learning(%{
          @activity
          | handover_failures: %{total: 1, items: [failure], page: 1, pages: 1}
        })

      section = LazyHTML.query(document, "section#context-not-saved")
      assert LazyHTML.text(section) =~ "The replies themselves were not affected"
      assert LazyHTML.query(section, ".entity-meta") |> LazyHTML.text() =~ "Reply sent"

      assert LazyHTML.query(section, ".entity-meta a") |> LazyHTML.attribute("href") == [
               failure.request_path
             ]

      assert Enum.empty?(LazyHTML.query(learning(@activity), "section#context-not-saved"))
    end

    test "learning worker sessions are listed on the learning page, never as working copies" do
      # Until 2026-09-24 these rows sat on the Working copies page as
      # "Background learning", a checkout nobody had asked for. The sessions
      # still open are the ones `WorkspaceProjection.learning_sessions/0` reads.
      retry_at = DateTime.add(DateTime.utc_now(), 1_800)

      sessions = [
        %{
          execution_kind: :learning,
          status: :active,
          learning_state: :retry_scheduled,
          learning_retry_at: retry_at,
          ref: "coop:learning:1",
          updated_at: @at,
          action: nil,
          summary: nil
        },
        %{
          execution_kind: :learning,
          status: :blocked,
          learning_state: :active,
          learning_retry_at: nil,
          ref: "coop:learning:2",
          updated_at: @at,
          action: :rearm,
          summary: "coop_unavailable"
        }
      ]

      section = learning(@activity, sessions) |> LazyHTML.query("section#worker-sessions")
      rows = LazyHTML.query(section, "article.entity-row")
      assert Enum.count(rows) == 2

      retry = LazyHTML.query(section, "article#session-coop-learning-1")

      assert LazyHTML.query(retry, ".state-word[data-tone=warn]") |> LazyHTML.text() ==
               "Retry scheduled"

      assert LazyHTML.query(retry, ".entity-text") |> LazyHTML.text() =~
               "The worker has not confirmed that this session stopped. Ryker checks again in"

      assert LazyHTML.query(retry, "details.memory-details:not([open]) code") |> LazyHTML.text() ==
               "coop:learning:1"

      blocked = LazyHTML.query(section, "article#session-coop-learning-2")
      assert LazyHTML.query(blocked, ".entity-text") |> LazyHTML.text() =~ "could not be reached"

      assert LazyHTML.query(
               blocked,
               "form.action-control[method=get][action='/actions/retention/coop:learning:2/rearm'] button"
             )
             |> LazyHTML.text() == "Resume cleanup"

      refute LazyHTML.text(section) =~ "workspace:one"
    end

    test "one batch opens with its attempts and grants one more start only through its bound form" do
      attempt = %{
        id: "44444444-4444-4444-8444-444444444444",
        number: 1,
        status: :rejected,
        label: "Response rejected",
        at: @at,
        error: "The model's answer wasn't in the form Ryker needs.",
        error_code: "invalid_learning_result",
        pruned_at: nil,
        path:
          "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#learning-44444444-4444-4444-8444-444444444444-result"
      }

      selected =
        Map.merge(@deferred, %{
          attempts: [attempt],
          attempt_page: 1,
          attempt_pages: 1,
          relearn: [],
          retry_available: true,
          retry_blocked: nil,
          drop_available: true
        })

      activity = %{@activity | selected: selected}

      # Andrew, 2026-09-27: "this is poorly designed, especially back button
      # you can't even find clearly". The batch is a page of its own now: the
      # shell titles it and leads back to all learning.
      assert LearningPage.heading(activity, %{"batch" => @batch_id}) == %{
               title: "Learning from #infra",
               description: nil,
               back: {"All learning", "/memory/learning"}
             }

      document = learning(activity)

      assert Enum.empty?(
               LazyHTML.query(
                 document,
                 ".memory-back, section#recent, h1, h2.memory-record-title"
               )
             )

      batch = LazyHTML.query(document, "article.memory-batch")

      assert LazyHTML.query(batch, "p.kit-status-line .state-word[data-tone=warn]")
             |> LazyHTML.text() == "Needs attention"

      assert LazyHTML.query(batch, ".section-head h2") |> LazyHTML.text() == "What happened"

      assert LazyHTML.query(batch, ".memory-prose") |> LazyHTML.text() =~
               "used every try it had"

      options = LazyHTML.query(document, "section#what-you-can-do")
      retry = LazyHTML.query(options, "article#retry")

      # QA re-test, 2026-09-26: this said "using the current learning policy,
      # ryker-learning", a worker's name for its rulebook.
      assert LazyHTML.text(retry) =~
               "Ryker reads these same messages again with one more start, using the learning settings in place now."

      refute LazyHTML.text(retry) =~ "policy"

      assert LazyHTML.query(
               options,
               "article#drop form[method=get][action='/actions/learning/#{@batch_id}/drop'] button"
             )
             |> LazyHTML.text() == "Drop batch"

      form =
        LazyHTML.query(retry, "form[method=post][action='/actions/learning/#{@batch_id}/retry']")

      assert LazyHTML.query(form, "input[name=_token]") |> LazyHTML.attribute("value") == [
               CSRF.token(
                 @secret,
                 "learning:retry",
                 LearningActivity.retry_resource(@batch_id, 0)
               )
             ]

      assert LazyHTML.query(form, "input[name=budget_version]") |> LazyHTML.attribute("value") ==
               ["0"]

      assert LazyHTML.query(form, "button") |> LazyHTML.text() == "Grant one more start"

      attempts = LazyHTML.query(document, "section#attempts")

      # Each attempt opens on its learning card on the Timeline.
      assert LazyHTML.query(attempts, "h3.entity-name a") |> LazyHTML.attribute("href") == [
               attempt.path
             ]

      assert LazyHTML.query(attempts, ".state-word[data-tone=warn]") |> LazyHTML.text() ==
               "Response rejected"

      assert LazyHTML.query(document, "details#batch-technical:not([open]) code")
             |> LazyHTML.text() ==
               "learning_retry_exhausted"

      blocked =
        learning(%{
          @activity
          | selected: %{
              selected
              | retry_available: false,
                retry_blocked: "Another batch is running."
            }
        })

      assert Enum.empty?(LazyHTML.query(blocked, "form[method=post]"))
      assert LazyHTML.text(blocked) =~ "Another batch is running."
    end

    # A stopped batch whose model execution was not yet confirmed stopped can
    # be neither retried nor dropped, and had no topic to relearn: its page
    # still said "What you can do" over a note and an empty list. It says why
    # it waits under what happened, and offers nothing it cannot do.
    test "a stopped batch with nothing to do now offers nothing, and says why under what happened" do
      waiting =
        Map.merge(@deferred, %{
          attempts: [],
          attempt_page: 1,
          attempt_pages: 1,
          relearn: [],
          retry_available: false,
          retry_blocked:
            "An earlier model execution has not been confirmed stopped. Ryker must reconcile it before another start.",
          drop_available: false
        })

      document = learning(%{@activity | selected: waiting})

      assert Enum.empty?(LazyHTML.query(document, "section#what-you-can-do"))
      refute LazyHTML.text(document) =~ "What you can do"

      assert LazyHTML.query(document, "article.memory-batch .memory-prose") |> LazyHTML.text() =~
               "An earlier model execution has not been confirmed stopped."

      # With one thing it can do, the section is back, and the reason one more
      # start waits stays with what happened.
      droppable = learning(%{@activity | selected: %{waiting | drop_available: true}})
      options = LazyHTML.query(droppable, "section#what-you-can-do")
      assert LazyHTML.query(options, "article#drop") |> Enum.count() == 1
      refute LazyHTML.text(options) =~ "not been confirmed stopped"

      assert LazyHTML.query(droppable, "article.memory-batch .memory-prose") |> LazyHTML.text() =~
               "An earlier model execution has not been confirmed stopped."
    end
  end

  test "each memory page carries its own title and plain description and reads only its own query" do
    parent = self()

    options = %{
      csrf_secret: @secret,
      projection: %{
        memory: fn params ->
          send(parent, {:memory, params})
          %{memories: [], reviews: []}
        end,
        learned: fn params ->
          send(parent, {:learned, params})
          @learned
        end,
        learning: fn params ->
          send(parent, {:learning, params})
          @activity
        end,
        learning_sessions: fn -> [] end,
        findings: fn params ->
          send(parent, {:findings, params})
          %{items: [], total: 0, page: 1, pages: 1}
        end
      }
    }

    query = %{"q" => "deploy", "kind" => "context", "page" => "2", "other" => "x"}

    for {segments, title, description} <- [
          {["memory"], "Facts",
           "Things people told Ryker to remember. It uses them as context, and they don't give it permission to act."},
          {["memory", "learned"], "Learned",
           "What Ryker learned by reading conversations, with the messages it learned from."},
          {["memory", "learning"], "Learning",
           "Ryker reads conversations in the background and keeps what it learned up to date."},
          {["memory", "findings"], "Findings",
           "Conclusions Ryker reached in investigations, with the evidence behind them."}
        ] do
      page = Pages.page(segments, query, options)
      assert page.status == 200
      assert page.title == title
      assert page.description == description
      document = LazyHTML.from_fragment(page.body)
      assert Enum.empty?(LazyHTML.query(document, "details.page-help, details.area-settings, h1"))
    end

    assert_received {:memory, facts}
    assert facts == %{"q" => "deploy", "page" => "2"}
    assert_received {:learned, %{"q" => "deploy", "kind" => "context", "page" => "2"} = learned}
    assert map_size(learned) == 3
    assert_received {:learning, %{"page" => "2"} = learning}
    assert map_size(learning) == 1

    # A batch that does not exist is not found, never the list in its place.
    assert Pages.page(["memory", "learning"], %{"batch" => "b"}, options).status == 404
    assert_received {:learning, %{"batch" => "b"}}
    assert_received {:findings, %{"page" => "2", "q" => "deploy"} = findings}
    assert map_size(findings) == 2
  end

  defp facts(snapshot) do
    snapshot |> FactsPage.html() |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
  end

  defp learned(view) do
    view |> LearnedPage.html(@secret) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
  end

  defp learning(activity, sessions \\ []) do
    activity
    |> LearningPage.html(sessions, @secret)
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  # A Kit facts list as {label, value text} pairs, in order.
  defp kit_facts(node) do
    Enum.zip(
      LazyHTML.query(node, ".kit-facts dt") |> Enum.map(&LazyHTML.text/1),
      LazyHTML.query(node, ".kit-facts dd") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    )
  end

  defp actions(row) do
    forms = LazyHTML.query(row, "form.action-control[method=get]")

    Enum.zip(
      Enum.map(forms, &(LazyHTML.query(&1, "button") |> LazyHTML.text())),
      LazyHTML.attribute(forms, "action")
    )
  end

  defp views(document) do
    links = LazyHTML.query(document, "nav.segmented a")

    Enum.zip([
      Enum.map(links, &LazyHTML.text/1),
      LazyHTML.attribute(links, "href"),
      Enum.map(links, &(LazyHTML.attribute(&1, "aria-current") == ["page"]))
    ])
  end
end
