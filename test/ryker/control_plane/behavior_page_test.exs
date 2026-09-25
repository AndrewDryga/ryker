defmodule Ryker.ControlPlane.BehaviorPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.BehaviorPage

  @now ~U[2026-09-24 12:00:00Z]

  test "a typed rule is named by what it does and says when it acts and who can set it off" do
    # Trigger-based rules have no title. The row names the job ("Triage
    # alerts"), says the event in a sentence, and prints the stored task once,
    # never the trigger enum or the sender filter value.
    for {source, words} <- [
          {"human", "people only"},
          {"app", "apps only"},
          {"any", "people and apps"}
        ] do
      rule = %{
        item(:standing_assignment)
        | payload: %{
            "action" => "triage_alert",
            "trigger" => "operational_alert",
            "source_filter" => source,
            "task" => "Check recent deploys and say whether it looks like a real incident."
          }
      }

      document = rules_document(view(:standing_assignment, [rule]))
      row = LazyHTML.query(document, "article#behavior-behavior\\:one")
      assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "Triage alerts"

      meta = row |> LazyHTML.query(".entity-meta") |> LazyHTML.text()
      assert meta =~ "When an alert arrives in Slack channel C456"
      assert meta =~ words

      html = LazyHTML.to_html(document)
      assert html |> String.split(rule.payload["task"]) |> length() == 2
      refute html =~ "operational_alert"
      refute html =~ "triage_alert"
      refute html =~ ">#{source}<"
    end
  end

  test "states read as words people use, and only a current rule offers Pause or Resume" do
    # "disabled" and "superseded" are storage words. A past rule keeps its
    # state in words and offers no lifecycle control.
    for {status, tone, word, control} <- [
          {"active", "on", "On", "Pause"},
          {"disabled", "off", "Paused", "Resume"},
          {"expired", "off", "Expired", nil},
          {"deleted", "off", "Deleted", nil},
          {"superseded", "off", "Replaced", nil}
        ] do
      document =
        rules_document(
          view(:standing_assignment, [%{item(:standing_assignment) | status: status}])
        )

      state = LazyHTML.query(document, "article .entity-side .state-word")
      assert LazyHTML.text(state) == word, status
      assert LazyHTML.attribute(state, "data-tone") == [tone], status

      buttons =
        document |> LazyHTML.query("form.action-control button") |> Enum.map(&LazyHTML.text/1)

      if control,
        do: assert(buttons == [control, "Delete"], status),
        else: assert(buttons == [], status)
    end
  end

  test "a row reads name and state, what it does, then one line of facts, with its controls last" do
    # The Kit row: no cards, no definition lists, no raw scope refs. Pause is
    # the one visible control; Delete sits behind a named overflow menu.
    document = rules_document(view(:standing_assignment, [item(:standing_assignment)]))
    row = LazyHTML.query(document, "article.entity-row#behavior-behavior\\:one")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "<unsafe>"
    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() == "Review the plan"

    meta = LazyHTML.query(row, "p.entity-meta")
    assert LazyHTML.text(meta) =~ "When a matching GitHub event arrives in Slack channel C456"
    assert LazyHTML.text(meta) =~ "uses emisar"
    assert LazyHTML.text(meta) =~ "used 3 times"

    assert LazyHTML.query(meta, "strong") |> Enum.map(&LazyHTML.text/1) == [
             "Slack channel C456",
             "emisar"
           ]

    refute LazyHTML.text(meta) =~ "slack:T123:C456"

    actions = LazyHTML.query(row, ".entity-actions")

    assert LazyHTML.query(row, ".entity-actions > form.action-control button")
           |> LazyHTML.text() == "Pause"

    menu = LazyHTML.query(actions, "details.behavior-menu")
    assert LazyHTML.attribute(menu, "open") == []
    assert LazyHTML.query(menu, "summary") |> LazyHTML.text() =~ "More actions for <unsafe>"

    assert LazyHTML.query(menu, "form.action-control") |> LazyHTML.attribute("action") == [
             "/actions/behavior/behavior%3Aone/deleted"
           ]

    assert LazyHTML.query(menu, "a[href^='https://slack.com/']") |> LazyHTML.text() =~
             "Open original conversation"

    assert Enum.empty?(LazyHTML.query(document, "dl, .behavior-entry, .ui-status"))
    html = LazyHTML.to_html(document)
    refute html =~ "<unsafe>"
  end

  test "an instruction confirmed in a direct conversation links its original conversation" do
    # Standing rules confirmed from the control plane store
    # control-plane:lab:<uuid>; the stored ref did not change with the
    # 2026-09-13 URL rename, and the link it produces must be the renamed route.
    id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    item = %{
      item(:standing_assignment)
      | source_conversation_ref: "control-plane:lab:#{id}",
        source_message_ref: nil
    }

    document = rules_document(view(item.kind, [item]))

    assert document |> LazyHTML.query("a[href='/conversations/#{id}']") |> LazyHTML.text() =~
             "Open original conversation"

    refute LazyHTML.to_html(document) =~ "/lab/"

    broken = %{item | source_conversation_ref: "control-plane:lab:not-a-uuid"}

    refute rules_document(view(item.kind, [broken])) |> LazyHTML.to_html() =~
             "original conversation"
  end

  test "creation is one ask hint with a real example, not a help disclosure" do
    # Rules are created only by asking Ryker and confirming. The page says so
    # in one sentence with an example instead of a "How to create" disclosure,
    # and never links to the retired Card Lab or /lab surfaces.
    document = rules_document(view(:standing_assignment, []))
    hint = LazyHTML.query(document, "p.ask-hint")
    assert LazyHTML.text(hint) =~ "To add a rule, tell Ryker in the channel:"

    assert LazyHTML.query(hint, "q") |> LazyHTML.text() ==
             "When someone posts a Terraform plan here, review it for risky changes."

    assert LazyHTML.text(hint) =~ "saves it only after you confirm"
    assert Enum.empty?(LazyHTML.query(document, "details.page-help, .configuration-help"))

    for href <- document |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href") do
      refute String.starts_with?(href, "/card-lab"), href
      refute String.starts_with?(href, "/lab"), href
    end
  end

  test "an empty list says what would put a rule there, and tells nothing yet from nothing current" do
    for {snapshot, title, text} <- [
          {view(:standing_assignment, []), "No rules yet", "once someone asks Ryker"},
          {%{view(:standing_assignment, []) | counts: %{"expired" => 2}},
           "No rules are on or paused", "under Past"},
          {%{
             view(:standing_assignment, [])
             | counts: %{"active" => 2},
               params: %{"q" => "", "status" => "past", "show" => "all"}
           }, "No past rules", "after they expire"}
        ] do
      empty = rules_document(snapshot) |> LazyHTML.query(".entity-empty")
      assert LazyHTML.query(empty, ".entity-empty-title") |> LazyHTML.text() == title
      assert LazyHTML.text(empty) =~ text
    end

    searched = %{
      view(:standing_assignment, [])
      | counts: %{"active" => 9},
        params: %{"q" => "missing", "status" => "past", "show" => "all"}
    }

    document = rules_document(searched)
    empty = LazyHTML.query(document, ".entity-empty")

    assert LazyHTML.query(empty, ".entity-empty-title") |> LazyHTML.text() ==
             "No rules match “missing”"

    # Clearing the search keeps the view the reader chose.
    assert LazyHTML.query(empty, "a") |> LazyHTML.attribute("href") == ["/rules?status=past"]
    assert Enum.empty?(LazyHTML.query(document, "section.behavior-matches"))
  end

  test "the filters are shareable addresses: views keep the search and paging keeps both" do
    # The address is the only filter state, so Back, a pasted link and a
    # reconcile all show the same rows. Changing a view starts at page one.
    snapshot = %{
      view(:standing_assignment, [item(:standing_assignment)])
      | params: %{"q" => "terraform", "status" => "past", "show" => "all"},
        page: 2,
        pages: 3,
        total: 60
    }

    document = rules_document(snapshot)
    search = LazyHTML.query(document, ".behavior-page > .kit-toolbar > form.filter-toolbar")
    assert LazyHTML.attribute(search, "method") == ["get"]
    assert LazyHTML.attribute(search, "action") == ["/rules"]
    assert LazyHTML.query(search, "input[name=q]") |> LazyHTML.attribute("value") == ["terraform"]

    assert LazyHTML.query(search, "input[type=hidden][name=status]")
           |> LazyHTML.attribute("value") ==
             ["past"]

    # The search submits on Enter; its only button is the shared toolbar's
    # Apply for browsers without JavaScript.
    assert Enum.empty?(LazyHTML.query(search, "select"))
    assert LazyHTML.query(search, "button") |> Enum.count() == 1
    assert LazyHTML.query(search, "noscript button") |> LazyHTML.text() == "Apply"

    segments = LazyHTML.query(document, "nav.segmented a")

    assert segments |> Enum.map(&{LazyHTML.text(&1), LazyHTML.attribute(&1, "href")}) == [
             {"Current", ["/rules?q=terraform"]},
             {"Past", ["/rules?q=terraform&status=past"]}
           ]

    assert LazyHTML.query(document, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
             "Past"

    assert LazyHTML.query(document, ".kit-toolbar a.filter-clear") |> LazyHTML.attribute("href") ==
             [
               "/rules?status=past"
             ]

    assert LazyHTML.query(document, "nav.pagination a") |> LazyHTML.attribute("href") == [
             "/rules?q=terraform&status=past",
             "/rules?page=3&q=terraform&status=past"
           ]

    assert LazyHTML.query(document, "nav.pagination") |> LazyHTML.text() =~ "60 rules"
  end

  test "recent matches say what Ryker did in plain words and open the work it started" do
    item = item(:standing_assignment)

    snapshot = %{
      view(:standing_assignment, [item])
      | runs: [
          %{
            rule_ref: item.ref,
            episode_ref: "episode:one",
            at: ~U[2026-09-24 10:00:00Z],
            outcome: :decided,
            action: :ignore
          },
          %{
            rule_ref: item.ref,
            episode_ref: nil,
            at: ~U[2026-09-24 11:59:30Z],
            outcome: :pending,
            action: nil
          }
        ]
    }

    section = rules_document(snapshot) |> LazyHTML.query("section.behavior-matches")

    assert LazyHTML.query(section, "header.section-head h2") |> LazyHTML.text() ==
             "Recent matches"

    rows = LazyHTML.query(section, "article.entity-row")
    assert Enum.count(rows) == 2

    assert rows |> LazyHTML.query("h3 a") |> LazyHTML.attribute("href") |> Enum.uniq() == [
             "#behavior-behavior:one"
           ]

    [ignored, pending] = Enum.map(rows, &(LazyHTML.query(&1, ".entity-meta") |> LazyHTML.text()))
    assert ignored =~ "No reply needed"
    assert ignored =~ "2 h ago"
    assert pending =~ "Waiting for Ryker"
    assert pending =~ "just now"

    assert LazyHTML.query(section, "a.ui-button") |> LazyHTML.attribute("href") == [
             "/timeline/episode%3Aone"
           ]

    refute LazyHTML.text(section) =~ "decided"
  end

  test "usage and expiry are short times with the full UTC time kept for hovering" do
    rule = %{
      item(:standing_assignment)
      | use_count: 12,
        last_used_at: ~U[2026-09-24 10:00:00Z],
        expires_at: ~U[2026-09-30 09:00:00Z]
    }

    meta = rules_document(view(:standing_assignment, [rule])) |> LazyHTML.query(".entity-meta")
    assert LazyHTML.text(meta) =~ "stops 30 Sep"
    assert LazyHTML.text(meta) =~ "used 12 times, last 2 h ago"

    assert LazyHTML.query(meta, "time") |> LazyHTML.attribute("title") == [
             "30 Sep 2026, 09:00 UTC",
             "24 Sep 2026, 10:00 UTC"
           ]

    once = %{rule | use_count: 1, last_used_at: ~U[2026-09-01 10:00:00Z], expires_at: nil}

    text =
      rules_document(view(:standing_assignment, [once]))
      |> LazyHTML.query(".entity-meta")
      |> LazyHTML.text()

    assert text =~ "used once, 1 Sep"
    refute text =~ "stops"

    expired = %{rule | status: "expired", expires_at: ~U[2026-09-12 09:00:00Z], use_count: 0}

    text =
      rules_document(view(:standing_assignment, [expired]))
      |> LazyHTML.query(".entity-meta")
      |> LazyHTML.text()

    assert text =~ "stopped 12 Sep"
    assert text =~ "not used yet"
  end

  test "event conditions stay out of the row and read as field-is-value lines behind a closed disclosure" do
    # A source-event rule matches event fields exactly. The JSON filter is a
    # detail for the person checking why a rule fired; it never sits in the
    # row as braces and quotes.
    rule = %{
      item(:standing_assignment)
      | payload: %{
          "title" => "Summarize merged pull requests",
          "task" => "Post a two-line summary.",
          "source_kind" => "github",
          "filter" => %{"action" => "closed", "pull_request" => %{"merged" => true}}
        }
    }

    document = rules_document(view(:standing_assignment, [rule]))
    row = LazyHTML.query(document, "article.entity-row")
    conditions = LazyHTML.query(row, "details.behavior-conditions")
    assert LazyHTML.attribute(conditions, "open") == []
    assert LazyHTML.attribute(conditions, "id") == ["behavior-behavior:one-conditions"]
    assert LazyHTML.query(conditions, "summary") |> LazyHTML.text() == "Conditions"

    assert LazyHTML.query(conditions, "li") |> Enum.map(&LazyHTML.text/1) == [
             "action is closed",
             "pull_request.merged is true"
           ]

    for part <- [".entity-text", ".entity-meta", "h3"] do
      refute LazyHTML.query(row, part) |> LazyHTML.text() =~ "{", part
    end

    plain = %{rule | payload: Map.put(rule.payload, "filter", %{})}
    document = rules_document(view(:standing_assignment, [plain]))
    assert Enum.empty?(LazyHTML.query(document, "details.behavior-conditions"))

    assert LazyHTML.query(document, ".entity-meta") |> LazyHTML.text() =~
             "When a GitHub event arrives"
  end

  test "a two-thousand-character instruction is reachable whole, and a short one is not padded with an empty control" do
    # The stored task is the rule. A preview that cannot be expanded is a
    # truncation with no way to read the rest, and an empty "Show all" on a
    # one-line rule is noise. The full stored text must be present verbatim
    # inside a disclosure whose id survives a live refresh.
    long =
      1..40
      |> Enum.map_join(
        "\n",
        &"Step #{&1}: compare the posted plan against the last apply and say so."
      )
      |> String.slice(0, 2_000)
      |> String.pad_trailing(2_000, "x")

    assert String.length(long) == 2_000
    rule = %{item(:standing_assignment) | payload: %{"title" => "Long rule", "task" => long}}
    document = rules_document(view(:standing_assignment, [rule]))

    full = LazyHTML.query(document, "article .entity-body > details.behavior-full")
    assert Enum.count(full) == 1
    assert LazyHTML.attribute(full, "id") == ["behavior-behavior:one-full"]
    assert LazyHTML.attribute(full, "open") == []
    assert LazyHTML.query(full, "summary .behavior-closed") |> LazyHTML.text() == "Show all"
    assert LazyHTML.query(full, "p.behavior-full-text") |> LazyHTML.text() == long

    preview = LazyHTML.query(document, "article p.entity-text") |> LazyHTML.text()
    assert String.length(preview) < 400
    assert preview =~ "Step 1: compare the posted plan"
    assert String.ends_with?(preview, "…")

    short = %{item(:standing_assignment) | payload: %{"title" => "Short", "task" => "Say hi."}}
    document = rules_document(view(:standing_assignment, [short]))
    assert Enum.empty?(LazyHTML.query(document, "details.behavior-full"))
    assert LazyHTML.query(document, "article p.entity-text") |> LazyHTML.text() == "Say hi."
  end

  test "every disclosure in an entry carries a stable id so an open one survives a live refresh" do
    # PreserveReadingState keys a <details> by its id and falls back to its
    # position plus summary text. Two rules with the same "Show all" summary
    # would swap open states whenever the list reorders after a reconcile, so
    # each disclosure is named by the entry it belongs to.
    long = String.duplicate("Watch the queue and say what changed. ", 20)

    rules = [
      %{
        item(:standing_assignment)
        | ref: "behavior:a",
          payload: %{"title" => "A", "task" => long}
      },
      %{
        item(:standing_assignment)
        | ref: "behavior:b",
          payload: %{
            "title" => "B",
            "task" => long,
            "source_kind" => "github",
            "filter" => %{"branch" => "main"}
          }
      }
    ]

    ids =
      rules_document(view(:standing_assignment, rules))
      |> LazyHTML.query("article details")
      |> LazyHTML.attribute("id")

    assert ids == [
             "behavior-behavior:a-full",
             "behavior-behavior:a-menu",
             "behavior-behavior:b-full",
             "behavior-behavior:b-conditions",
             "behavior-behavior:b-menu"
           ]
  end

  test "opening the action menu or a disclosure performs nothing: every control is a GET to its confirmation" do
    # Moving Delete behind an overflow control is not permission to skip its
    # confirmation page. Nothing inside an entry may POST, carry a phx-click,
    # or point anywhere but the existing /actions/behavior confirmation, so
    # opening the menu, or a disclosure, cannot change a row.
    for kind <- [:standing_assignment, :preference, :guidance],
        status <- ["active", "disabled"] do
      document =
        case kind do
          :standing_assignment ->
            rules_document(view(kind, [%{item(kind) | status: status}]))

          _saved ->
            instructions_document([], view(kind, [%{item(kind) | status: status}]))
        end

      forms = LazyHTML.query(document, "article.entity-row form")
      assert Enum.count(forms) == 2
      assert LazyHTML.attribute(forms, "method") |> Enum.uniq() == ["get"]

      for action <- LazyHTML.attribute(forms, "action") do
        assert String.starts_with?(action, "/actions/behavior/behavior%3Aone/"), action
      end

      assert Enum.count(
               LazyHTML.query(
                 document,
                 "details.behavior-menu:not([open]) > :not(summary) form[action$='/deleted']"
               )
             ) == 1

      assert Enum.empty?(LazyHTML.query(document, "details.behavior-menu > summary form"))
      assert Enum.empty?(LazyHTML.query(document, "[phx-click], [phx-submit], form[method=post]"))
      assert Enum.empty?(LazyHTML.query(document, "article button:not(form button)"))
    end
  end

  test "preferences and guidance read as names people use, with where they apply" do
    # response_detail/concise and a scope enum were the row before. A person
    # recognises "Reply length: Concise" in #payments, not the stored key.
    for {key, value, name} <- [
          {"response_detail", "concise", "Reply length: Concise"},
          {"health_check_depth", "quick", "Health checks: Quick"},
          {"response_location", "prefer_thread", "Where to reply: In the thread"},
          {"response_location", "follow_context", "Where to reply: Where the conversation is"}
        ] do
      preference = %{item(:preference) | payload: %{"key" => key, "value" => value}}

      row =
        instructions_document([], view(:preference, [preference])) |> LazyHTML.query("article")

      assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ name
      assert Enum.empty?(LazyHTML.query(row, ".entity-text"))
      refute LazyHTML.text(row) =~ key
    end

    for {scope_kind, scope_ref, where} <- [
          {:workspace, "slack:T123", "everywhere"},
          {:conversation, "slack:T123:C456", "in Slack channel C456"},
          {:repository, "acme/checkout-api", "for acme/checkout-api"},
          {:operator, "slack:user:U123", "for one person"}
        ] do
      guidance = %{
        item(:guidance)
        | payload: %{
            "subject" => "Check the migrations folder before approving a deploy",
            "summary" => "Migrations first",
            "text" => "Any change under db/migrations needs a rollback note."
          },
          scope_kind: scope_kind,
          scope_ref: scope_ref
      }

      row = instructions_document([], view(:guidance, [guidance])) |> LazyHTML.query("article")

      assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~
               "Check the migrations folder before approving a deploy"

      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() ==
               "Any change under db/migrations needs a rollback note."

      meta = row |> LazyHTML.query(".entity-meta") |> LazyHTML.text() |> squish()
      assert meta =~ "Guidance · #{where}", "#{scope_kind}: #{meta}"
      refute meta =~ "slack:", "#{scope_kind}"
    end
  end

  test "saved entries are filtered by kind and status through linkable segments that keep each other" do
    saved = %{
      view(:guidance, [item(:guidance)])
      | kinds: [:preference, :guidance],
        params: %{"q" => "", "status" => "past", "show" => "guidance"},
        page: 1,
        pages: 2,
        total: 26
    }

    document = instructions_document([], saved)
    section = LazyHTML.query(document, "section.instructions-saved")

    assert LazyHTML.query(section, "header.section-head#saved h2") |> LazyHTML.text() ==
             "Saved from conversations"

    assert section
           |> LazyHTML.query("nav.segmented a")
           |> Enum.map(&{LazyHTML.text(&1), LazyHTML.attribute(&1, "href")}) == [
             {"All", ["/instructions?status=past#saved"]},
             {"Preferences", ["/instructions?show=preferences&status=past#saved"]},
             {"Guidance", ["/instructions?show=guidance&status=past#saved"]},
             {"Current", ["/instructions?show=guidance#saved"]},
             {"Past", ["/instructions?show=guidance&status=past#saved"]}
           ]

    assert section
           |> LazyHTML.query("nav.segmented a[aria-current=page]")
           |> Enum.map(&LazyHTML.text/1) ==
             ["Guidance", "Past"]

    assert LazyHTML.query(section, "nav.pagination a") |> LazyHTML.attribute("href") == [
             "/instructions?page=2&show=guidance&status=past#saved"
           ]

    assert LazyHTML.query(section, "p.ask-hint q") |> LazyHTML.text() ==
             "Remember to keep incident updates short."

    empty = instructions_document([], %{view(:preference, []) | kinds: [:preference, :guidance]})

    assert LazyHTML.query(empty, "section.instructions-saved .entity-empty-title")
           |> LazyHTML.text() ==
             "Nothing saved yet"
  end

  test "channel instructions list each channel with its words and an edit link to that channel's editor" do
    channels = [
      %{
        workspace_ref: "T123",
        channel_ref: "C999",
        text: "Always link the Grafana dashboard you looked at."
      },
      %{
        workspace_ref: "T123",
        channel_ref: "C456",
        text:
          "Include the affected service\nand time window. " <>
            String.duplicate("More detail. ", 30)
      }
    ]

    section =
      instructions_document(channels, saved([]))
      |> LazyHTML.query("section.instructions-channels")

    assert LazyHTML.query(section, "header.section-head#channels h2") |> LazyHTML.text() ==
             "For specific channels"

    rows = LazyHTML.query(section, "article.entity-row")

    assert rows |> LazyHTML.query("h3") |> Enum.map(&LazyHTML.text/1) |> Enum.map(&String.trim/1) ==
             ["Slack channel C456", "Slack channel C999"]

    [long, short] = rows |> LazyHTML.query(".entity-text") |> Enum.map(&LazyHTML.text/1)
    assert short == "“Always link the Grafana dashboard you looked at.”"
    assert long =~ ~r/\A“Include the affected service and time window\. More detail\./
    assert String.ends_with?(long, "…”")
    assert String.length(long) < 200

    assert rows |> LazyHTML.query("h3 a") |> LazyHTML.attribute("href") == [
             "/channels/T123/C456",
             "/channels/T123/C999"
           ]

    assert rows |> LazyHTML.query(".entity-actions a") |> LazyHTML.attribute("href") == [
             "/channels/T123/C456#instructions-slack:T123:C456",
             "/channels/T123/C999#instructions-slack:T123:C999"
           ]

    empty =
      instructions_document([], saved([])) |> LazyHTML.query("section.instructions-channels")

    assert LazyHTML.query(empty, ".entity-empty-title") |> LazyHTML.text() ==
             "No channel has its own instructions yet"

    assert LazyHTML.query(empty, "a.behavior-add") |> LazyHTML.attribute("href") == ["/channels"]
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp rules_document(view),
    do:
      render_component(&BehaviorPage.rules/1, view: view, now: @now)
      |> LazyHTML.from_fragment()

  defp instructions_document(channels, saved),
    do:
      render_component(&BehaviorPage.instructions/1, channels: channels, saved: saved, now: @now)
      |> LazyHTML.from_fragment()

  defp saved(items), do: %{view(:guidance, items) | kinds: [:preference, :guidance]}

  defp view(kind, items),
    do: %{
      kinds: [kind],
      items: items,
      counts: if(items == [], do: %{}, else: %{"active" => length(items)}),
      total: length(items),
      page: 1,
      pages: 1,
      runs: [],
      params: %{"q" => "", "status" => "current", "show" => "all"}
    }

  defp item(kind),
    do: %{
      kind: kind,
      ref: "behavior:one",
      payload: %{
        "title" => "<unsafe>",
        "task" => "Review the plan",
        "filter" => %{"action" => "submitted"},
        "source_kind" => "github",
        "repository" => "emisar"
      },
      status: "active",
      scope_kind: :conversation,
      scope_ref: "slack:T123:C456",
      workspace_ref: "slack:T123",
      confirmed_at: ~U[2026-09-06 12:00:00Z],
      use_count: 3,
      last_used_at: nil,
      expires_at: nil,
      source_conversation_ref: "slack:T123:C456",
      source_message_ref: "1787832000.000100"
    }
end
