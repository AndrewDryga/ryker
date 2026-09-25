defmodule Ryker.ControlPlane.ComponentsTest do
  @moduledoc """
  The shared vocabulary every page composes: one status markup, one pager,
  one comparison table. Pages that hand-rolled these drifted apart (a pager
  with no touch targets beside one with them, "Active" in the in-progress tone
  on one page and the settled tone on another), so the contract lives here.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Components, Kit, Pages}
  alias Ryker.Fixtures.ControlPlaneOptions

  test "a status reads the same whether its state arrives as a string or an atom" do
    # Episode states are strings in the projections and atoms in the schemas;
    # an atom used to fall through every clause and render the quiet tone
    # under a bare word, so the channel page had to stringify by hand.
    for state <- ["blocked", :blocked] do
      assert Components.label(state) == "Needs attention"
      assert Components.tone(state) == "attention"
    end

    assert Components.tone(:working) == "active"
    assert Components.label(:complete) == "Completed"

    html = render_component(&Components.status/1, state: :working)
    assert html =~ ~s(class="ui-status status-active")
    assert html =~ "Working"
  end

  test "rules, schedules and memories share one lifecycle vocabulary" do
    assert Components.lifecycle(:active) == {"Active", "done"}
    assert Components.lifecycle("active") == {"Active", "done"}
    assert Components.lifecycle(:paused) == {"Paused", "quiet"}
    assert Components.lifecycle("disabled") == {"Paused", "quiet"}
    assert Components.lifecycle(:completed) == {"Completed", "done"}
    assert Components.lifecycle(:expired) == {"Expired", "quiet"}

    component = render_component(&Components.status/1, lifecycle: "disabled")
    assert component =~ ~s(class="ui-status status-quiet")
    assert component =~ "Paused"

    explicit = render_component(&Components.status/1, label: "Ready", tone: "done")

    assert explicit =~
             ~s(<span class="ui-status status-done"><i aria-hidden="true"></i>Ready</span>)

    # The string pages render through the same function, so the markup cannot drift.
    assert IO.iodata_to_binary(Components.status("Ready", "done")) == String.trim(explicit)
  end

  test "form feedback carries one semantic tone, icon and message target" do
    html =
      render_component(&Components.form_feedback/1,
        message: "The value could not be saved.",
        tone: :error
      )
      |> LazyHTML.from_fragment()

    feedback =
      LazyHTML.query(html, ".form-feedback.form-feedback-error[data-tone=error][role=alert]")

    assert LazyHTML.query(feedback, ".form-feedback-icon") |> LazyHTML.text() == "!"

    assert LazyHTML.query(feedback, ".form-feedback-message") |> LazyHTML.text() ==
             "The value could not be saved."
  end

  test "diagnostic identifiers stay compact while preserving an exact copy target" do
    value = "ingress-input:2b6e9fb1-996b-4eab-bcfd-f448d69bab4e"

    document =
      render_component(&Components.identifier/1, value: value, label: "Input ID")
      |> LazyHTML.from_fragment()

    identifier = LazyHTML.query(document, ".ui-identifier")
    assert LazyHTML.attribute(identifier, "title") == [value]
    assert LazyHTML.text(LazyHTML.query(identifier, "code")) =~ "…"
    refute LazyHTML.text(LazyHTML.query(identifier, "code")) == value

    copy = LazyHTML.query(identifier, "button[data-copy-value]")
    assert LazyHTML.attribute(copy, "data-copy-value") == [value]
    assert LazyHTML.attribute(copy, "aria-label") == ["Copy Input ID"]
  end

  test "a shared disclosure and fact list keep diagnostics in one visual contract" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Components.disclosure id="failure-diagnostics" label="Failure diagnostics" kind={:diagnostic}>
            <Components.fact_list facts={@facts} />
          </Components.disclosure>
          """
        end,
        facts: [
          %{label: "Operation", value: "deliver"},
          %{label: "Record", value: "failure:123", identifier: true}
        ]
      )
      |> LazyHTML.from_fragment()

    assert html
           |> LazyHTML.query("details.ui-disclosure-diagnostic > summary")
           |> LazyHTML.text()
           |> String.trim() == "Failure diagnostics"

    assert LazyHTML.query(html, ".ui-facts > div") |> Enum.count() == 2
    assert LazyHTML.query(html, ".ui-facts .ui-identifier") |> Enum.count() == 1
    assert LazyHTML.query(html, "summary .ui-icon") |> Enum.count() == 1
  end

  test "a source disclosure keeps its title and right-aligned metadata in the shared shell" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Components.disclosure
            id="raw-response"
            label="Raw response"
            kind={:source}
          >
            <:meta>JSON · 147 bytes</:meta>
            <pre>{"retained"}</pre>
          </Components.disclosure>
          """
        end,
        %{}
      )
      |> LazyHTML.from_fragment()

    summary = LazyHTML.query(html, "details.ui-disclosure-source > summary")
    assert LazyHTML.query(summary, ".ui-disclosure-label") |> LazyHTML.text() == "Raw response"
    assert LazyHTML.query(summary, ".ui-disclosure-meta") |> LazyHTML.text() == "JSON · 147 bytes"
    assert LazyHTML.query(summary, ".ui-icon") |> Enum.count() == 1
  end

  test "timeline cards share one title and metadata header anatomy" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Components.card_heading title="Model briefing" meta_layout={:stack_on_narrow}>
            <:leading><span class="test-symbol">◇</span></:leading>
            <:detail>Work request</:detail>
            <:description>What the model received for this call.</:description>
            <:meta>
              <Components.execution_target target="codex:gpt-5.6-sol/medium@default" />
            </:meta>
          </Components.card_heading>
          """
        end,
        %{}
      )
      |> LazyHTML.from_fragment()

    heading = LazyHTML.query(html, "header.case-card-heading.case-card-heading-stack-meta")

    assert LazyHTML.query(heading, ".case-card-heading-main > h3") |> LazyHTML.text() ==
             "Model briefing"

    assert LazyHTML.query(heading, ".case-card-heading-leading") |> LazyHTML.text() == "◇"

    assert LazyHTML.query(heading, ".case-card-heading-detail") |> LazyHTML.text() ==
             "Work request"

    assert LazyHTML.query(heading, ".case-card-heading-description")
           |> LazyHTML.text()
           |> String.trim() ==
             "What the model received for this call."

    assert LazyHTML.query(heading, ".case-card-heading-meta .execution-target-model")
           |> LazyHTML.text() == "gpt-5.6-sol"
  end

  test "messages are self-contained containers with contextual titles and subordinate controls" do
    # Intake and retained messages drifted into title/subtitle layouts. Both
    # render paths must use the same anatomy without interpreting sender text.
    sender = "<Local operator>"
    body = "<script>not markup</script>"

    heex =
      render_component(
        fn assigns ->
          ~H"""
          <Components.message_block
            sender={@sender}
            title="Current message"
            data-message-context="current"
          >
            <:meta><time>05:48 UTC</time></:meta>
            <p>{@body}</p>
            <:footer>
              <Components.disclosure id="message-details" label="Message details">
                Evidence
              </Components.disclosure>
            </:footer>
          </Components.message_block>
          """
        end,
        sender: sender,
        body: body
      )

    iodata =
      Components.message_block_html(
        sender,
        ["<p>", Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(body)), "</p>"],
        title: "Current message",
        rest: %{"data-message-context" => "current"},
        meta: "<time>05:48 UTC</time>",
        footer: Components.disclosure_html("Message details", "Evidence", id: "message-details")
      )
      |> IO.iodata_to_binary()

    for html <- [heex, iodata] do
      document = LazyHTML.from_fragment(html)
      message = LazyHTML.query(document, "article.ui-message[data-message-context=current]")
      assert LazyHTML.query(message, ".ui-message-title") |> LazyHTML.text() == "Current message"
      assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() == sender
      assert LazyHTML.query(message, ".ui-message-meta time") |> LazyHTML.text() == "05:48 UTC"
      assert LazyHTML.query(message, ".ui-message-body > p") |> LazyHTML.text() == body

      assert LazyHTML.query(
               message,
               ".ui-message-footer > details.ui-disclosure > summary .ui-icon"
             )
             |> Enum.count() == 1

      assert LazyHTML.query(message, "script") |> Enum.empty?()
    end

    bare =
      render_component(fn assigns ->
        ~H"""
        <Components.message_block>Response</Components.message_block>
        """
      end)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(bare, ".ui-message-body") |> LazyHTML.text() == "Response"
    assert LazyHTML.query(bare, "header, footer") |> Enum.empty?()
  end

  test "fact lists render retained execution targets through the shared presentation" do
    html =
      render_component(&Components.fact_list/1,
        facts: [
          %{
            label: "Model",
            value: "codex:gpt-5.6-sol/medium@default",
            presentation: :execution_target
          }
        ]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, ".execution-target-model") |> LazyHTML.text() == "gpt-5.6-sol"

    assert LazyHTML.query(html, ".execution-target-meta") |> LazyHTML.text() ==
             "Medium reasoning · Codex · Default profile"

    refute LazyHTML.text(html) =~ "codex:gpt-5.6-sol/medium@default"
  end

  test "the pager renders nothing for one page and only the links that lead somewhere" do
    assigns = %{path: fn page -> "/memory/findings?page=#{page}" end}

    assert render_component(&Components.pager/1,
             page: 1,
             pages: 1,
             path: assigns.path,
             label: "Finding pages"
           ) == ""

    first =
      render_component(&Components.pager/1,
        page: 1,
        pages: 3,
        path: assigns.path,
        label: "Finding pages"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(first, "nav.pagination[aria-label='Finding pages']") |> Enum.count() ==
             1

    assert LazyHTML.query(first, "a") |> LazyHTML.attribute("href") == ["/memory/findings?page=2"]
    assert LazyHTML.query(first, "a") |> LazyHTML.text() == "Next →"
    assert LazyHTML.query(first, "span") |> LazyHTML.text() =~ "Page 1 of 3"

    middle =
      render_component(&Components.pager/1,
        page: 2,
        pages: 3,
        path: assigns.path,
        label: "Memory pages",
        earlier: "← Newer updates",
        later: "Older updates →",
        summary: "12 entries"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(middle, "a") |> LazyHTML.attribute("href") == [
             "/memory/findings?page=1",
             "/memory/findings?page=3"
           ]

    assert LazyHTML.query(middle, "a") |> LazyHTML.text() == "← Newer updatesOlder updates →"
    assert LazyHTML.text(middle) =~ "Page 2 of 3 · 12 entries"
  end

  test "the shared filter toolbar keeps one primary view and turns optional constraints into chips" do
    html =
      render_component(&Components.filter_toolbar/1,
        id: "rules-search",
        path: "/rules",
        label: "Filter standing rules",
        placeholder: "Search instructions or scope",
        query: "deploy",
        filtered: true,
        selects: [
          %{
            id: "rules-status",
            name: "status",
            label: "Status",
            value: "active",
            options: [{"all", "Active & paused"}, {"active", "Active"}]
          },
          %{
            id: "rules-scope",
            name: "scope",
            label: "Applies to",
            value: "channel",
            options: [{"", "All scopes"}, {"channel", "Channel"}]
          }
        ]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "form.filter-toolbar > .search-field") |> Enum.count() == 1
    assert LazyHTML.query(html, "select.filter-primary[name=status]") |> Enum.count() == 1

    chip_text = LazyHTML.query(html, ".filter-chip[data-filter=scope]") |> LazyHTML.text()
    assert chip_text =~ "Applies to"
    assert chip_text =~ "Channel"

    assert LazyHTML.query(html, "input[type=hidden][name=scope]")
           |> LazyHTML.attribute("value") == ["channel"]

    assert LazyHTML.query(html, ".filter-chip-remove") |> LazyHTML.attribute("href") ==
             ["/rules?q=deploy&status=active"]

    assert LazyHTML.query(html, ".filter-add-menu select[name=scope] option[selected]")
           |> LazyHTML.attribute("value") == ["channel"]

    assert LazyHTML.query(html, "a.filter-clear") |> LazyHTML.attribute("href") == ["/rules"]
  end

  test "the shared filter toolbar offers inactive optional constraints under Filter" do
    html =
      render_component(&Components.filter_toolbar/1,
        id: "rules-search",
        path: "/rules",
        label: "Filter standing rules",
        placeholder: "Search instructions or scope",
        selects: [
          %{
            id: "rules-status",
            name: "status",
            label: "Status",
            value: "all",
            options: [{"all", "Active & paused"}, {"paused", "Paused"}]
          },
          %{
            id: "rules-scope",
            name: "scope",
            label: "Applies to",
            value: "",
            options: [{"", "All scopes"}, {"channel", "Channel"}]
          }
        ]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "details.filter-add-menu > summary") |> LazyHTML.text() ==
             "Filter"

    assert LazyHTML.query(html, ".filter-add-menu select[name=scope]") |> Enum.count() == 1
    assert LazyHTML.query(html, ".filter-chip") |> Enum.empty?()
    assert LazyHTML.query(html, "a.filter-clear") |> Enum.empty?()
  end

  test "the shared filter toolbar disables every control when its collection is empty" do
    html =
      render_component(&Components.filter_toolbar/1,
        id: "rules-search",
        path: "/rules",
        label: "Filter standing rules",
        placeholder: "Search instructions or scope",
        disabled: true,
        selects: [
          %{
            id: "rules-status",
            name: "status",
            label: "Status",
            value: "all",
            options: [{"all", "Active & paused"}, {"paused", "Paused"}]
          },
          %{
            id: "rules-scope",
            name: "scope",
            label: "Applies to",
            value: "",
            options: [{"", "All scopes"}, {"channel", "Channel"}]
          }
        ]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "input[type=search][disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, "select.filter-primary[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, "button.filter-add[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, "details.filter-add-menu") |> Enum.empty?()
  end

  # The page summary and the data table were a second vocabulary beside the
  # Kit: counts as a definition list, tables with a stacked mobile layout.
  # Every page now leads with Kit counts and compares figures in Kit tables.
  test "Kit counts lead with numbers: a warning tone, a link and a quieter breakdown" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Kit.counts label="Current workload" items={@items} patch />
          <Kit.counts label="Tokens" items={[%{value: "1.2k", label: "output"}]} secondary />
          """
        end,
        items: [
          %{value: 2, label: "active", href: "/activity?filter=running"},
          %{value: 1, label: "blocked", tone: :warn, href: "/activity?filter=attention"},
          %{value: 0, label: "workers available", tone: :warn, href: "#workers"},
          %{value: 3, label: "waiting"}
        ]
      )
      |> LazyHTML.from_fragment()

    counts = LazyHTML.query(html, ".kit-counts[aria-label='Current workload'] > .kit-count")
    assert Enum.count(counts) == 4
    assert LazyHTML.query(counts, "b") |> Enum.map(&LazyHTML.text/1) == ["2", "1", "0", "3"]
    assert LazyHTML.query(html, "a.kit-count[data-phx-link=patch]") |> Enum.count() == 2

    assert LazyHTML.query(html, "a.kit-count[href='#workers']:not([data-phx-link])")
           |> Enum.count() == 1

    assert LazyHTML.query(html, "span.kit-count") |> LazyHTML.text() =~ "waiting"
    assert LazyHTML.query(html, ".kit-count[data-tone=warn]") |> Enum.count() == 2

    assert LazyHTML.query(html, ".kit-counts.kit-counts-secondary[aria-label=Tokens]")
           |> Enum.count() == 1
  end

  test "a Kit table names each column once and right-aligns its figures" do
    rows = [%{name: "Daily health", count: 2}, %{name: "Weekly digest", count: 0}]

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Kit.table rows={@rows} label="Schedules">
            <:col :let={row} label="Schedule">{row.name}</:col>
            <:col :let={row} label="Failures" numeric>{row.count}</:col>
          </Kit.table>
          """
        end,
        rows: rows
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "table.kit-table[aria-label=Schedules] thead tr")
           |> Enum.count() == 1

    assert LazyHTML.query(document, "thead th[scope=col]")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["Schedule", "Failures"]

    assert LazyHTML.query(document, "th[data-numeric=true]")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["Failures"]

    assert LazyHTML.query(document, "td[data-numeric=true]")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["2", "0"]
  end

  test "Kit facts drop a missing value instead of showing a placeholder" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Kit.status_line state={{:warn, "Needs attention"}}><span>opened 2 h ago</span></Kit.status_line>
          <Kit.facts facts={[
            {"Channel", "#incidents"},
            {"Stage", nil},
            {"Asked", false},
            {"Repository", ""}
          ]} />
          """
        end,
        []
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "p.kit-status-line .state-word[data-tone=warn]")
           |> LazyHTML.text() ==
             "Needs attention"

    assert LazyHTML.query(html, "dl.kit-facts dt") |> Enum.map(&LazyHTML.text/1) == ["Channel"]
    assert LazyHTML.query(html, "dl.kit-facts dd") |> LazyHTML.text() == "#incidents"
  end

  test "a string-rendered list page uses the same Kit row markup as the component" do
    # The Channels list is prepared as a string by Pages; it must produce the
    # rows the Kit component produces, so one stylesheet rule covers both.
    component =
      render_component(
        fn assigns ->
          ~H"""
          <Kit.entity_list label="Channels">
            <Kit.entity_row
              name="#infra"
              href="/channels/T1/C1"
              state={{:on, "Ryker is in"}}
              meta={["Replies when mentioned"]}
            />
          </Kit.entity_list>
          """
        end,
        %{}
      )
      |> LazyHTML.from_fragment()

    page =
      Pages.page(["channels"], %{}, ControlPlaneOptions.options(self())).body
      |> LazyHTML.from_fragment()

    for contract <- [
          "div.entity-list[role=list] > article.entity-row[role=listitem]",
          "article.entity-row > div.entity-body > h3.entity-name > a[href]",
          "article.entity-row > div.entity-side > .state-word[data-tone]",
          "div.entity-body > p.entity-meta"
        ] do
      assert LazyHTML.query(component, contract) |> Enum.count() > 0, contract
      assert LazyHTML.query(page, contract) |> Enum.count() > 0, contract
    end
  end
end
