defmodule Ryker.ControlPlane.MemoryPageTest do
  @moduledoc """
  The Memory page inside the shared Configuration shell: the help disclosure,
  the memory views as compact tabs, the one toolbar that keeps the chosen view,
  a quiet count, the entries with their recall warnings, and the operational
  sections beneath. Deterministic views; no database.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{HTML, MemoryPage, Pages}

  @at ~U[2026-09-10 09:00:00Z]

  @item %{
    id: "note-1",
    title: "Deploy window decision",
    conversation: "#infra",
    conversation_path: "/channels/T123/C456",
    at: @at,
    repository: "ryker",
    text: "Deploys happen after 15:00 UTC on weekdays.",
    workspace: nil,
    groups: [],
    source: "https://slack.com/archives/C456/p1757494800000000",
    source_count: 2,
    source_path: "/memory?kind=sources&related_to=context:note-1",
    request_path: nil,
    changed_at: @at,
    source_at: @at
  }

  @view %{
    counts: %{context: 2, knowledge: 3},
    kind: "context",
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
    learning_activity: nil,
    learning: nil,
    items: [@item]
  }

  @learning %{
    enabled: false,
    worker_running: false,
    waiting_inputs: 3,
    oldest_waiting_at: nil,
    handover_failures: %{total: 0, items: [], page: 1, pages: 1},
    filter: "",
    counts: %{queued: 0, running: 0, deferred: 0, applied: 0, no_change: 0, superseded: 0},
    total: 0,
    items: [],
    page: 1,
    pages: 1,
    selected: nil
  }

  test "knowledge and conversation context are primary while sources stay record-level provenance" do
    # Before 2026-09-13 the three views were 28px numbers in bordered boxes —
    # the statistics dashboard the approved shell removes — above a search
    # form with a visible Search label, a Search button and its own Clear
    # button, and the only count was the pagination line.
    document = render_page(%{@view | q: "deploy"})

    assert outline(document, "div.conversation-memory > *") |> Enum.take(4) == [
             "nav.memory-views",
             "form.filter-toolbar",
             "p.result-count",
             "div.memory-cards"
           ]

    assert Enum.empty?(
             LazyHTML.query(
               document,
               ".memory-totals, form.search-form, .filter-field, form.filter-toolbar button:not(noscript button)"
             )
           )

    tabs = LazyHTML.query(document, "nav.memory-views a")
    assert Enum.count(tabs) == 2

    assert LazyHTML.query(document, "nav.memory-views a[aria-current=page]") |> LazyHTML.text() =~
             "Conversation context"

    assert LazyHTML.query(document, "nav.memory-views a[aria-current=page]") |> LazyHTML.text() =~
             "2"

    refute LazyHTML.text(tabs) =~ "Source"

    assert LazyHTML.query(
             document,
             "nav.memory-views a[href='/memory?kind=knowledge&page=1&q=deploy']"
           )
           |> LazyHTML.text() =~ "Current knowledge"

    toolbar = LazyHTML.query(document, "form.filter-toolbar[action='/memory'][method=get]")

    assert LazyHTML.query(toolbar, "input[type=hidden][name=kind]") |> LazyHTML.attribute("value") ==
             ["context"]

    assert LazyHTML.query(toolbar, "input#memory-search[type=search][name=q]")
           |> LazyHTML.attribute("value") == ["deploy"]

    assert LazyHTML.query(toolbar, "a.filter-clear") |> LazyHTML.attribute("href") == [
             "/memory?kind=context"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() ==
             "1 conversation context"

    assert LazyHTML.query(
             document,
             "a[href='/memory?kind=sources&related_to=context:note-1']"
           )
           |> LazyHTML.text() == "Sources · 2 →"

    knowledge = render_page(%{@view | kind: "knowledge", total: 3, items: [@item, @item, @item]})
    assert LazyHTML.query(knowledge, "p.result-count") |> LazyHTML.text() == "3 knowledge topics"
    assert Enum.empty?(LazyHTML.query(knowledge, "form.filter-toolbar a.filter-clear"))
  end

  test "an empty memory view tells a search miss from a view with nothing learned, and keeps recall warnings visible" do
    miss = render_page(%{@view | q: "absent", total: 0, items: []})

    assert LazyHTML.query(miss, "p.empty-state") |> LazyHTML.text() =~
             "No matching conversation memory"

    assert Enum.empty?(LazyHTML.query(miss, "p.result-count"))

    nothing = render_page(%{@view | total: 0, items: []})

    assert LazyHTML.query(nothing, "p.empty-state") |> LazyHTML.text() =~
             "Nothing learned here yet"

    unavailable =
      render_page(%{
        @view
        | kind: "context",
          items: [Map.put(@item, :recall_warning, :missing_source_history)]
      })

    warning = LazyHTML.query(unavailable, ".memory-card .memory-unavailable") |> LazyHTML.text()
    assert warning =~ "Not used for recall"
    assert warning =~ "No complete source history was saved"

    assert LazyHTML.query(unavailable, "p.result-count") |> LazyHTML.text() ==
             "1 conversation context"
  end

  test "the source inspector is secondary, compact, and returns to its parent record" do
    source = %{
      @item
      | id: "source-1",
        source_path: nil,
        source_count: nil,
        title: "",
        text: "The original source message."
    }

    view = %{
      @view
      | kind: "sources",
        counts: %{context: 1, knowledge: 1},
        items: [source],
        related_to: "context:summary-1",
        source_parent: %{
          back_label: "Conversation context",
          back_path: "/memory?kind=context#memory-summary-1",
          title: "Recurring validation schedule"
        }
    }

    document = render_page(%{view | learning_activity: @learning})

    assert Enum.count(LazyHTML.query(document, "nav.memory-views a")) == 2
    assert Enum.empty?(LazyHTML.query(document, "nav.memory-views a[aria-current=page]"))

    heading = LazyHTML.query(document, ".memory-source-context")
    assert LazyHTML.text(heading) =~ "Sources for Recurring validation schedule"

    assert LazyHTML.query(heading, "a[href='/memory?kind=context#memory-summary-1']")
           |> LazyHTML.text() == "← Conversation context"

    assert Enum.count(LazyHTML.query(document, "ol.memory-source-list > li")) == 1
    assert Enum.empty?(LazyHTML.query(document, "div.memory-cards"))
    assert Enum.empty?(LazyHTML.query(document, ".learning-summary, section.learning-activity"))

    assert LazyHTML.query(document, "input#memory-search")
           |> LazyHTML.attribute("placeholder") == ["Search source messages"]

    source_link = LazyHTML.query(document, ".memory-source-list a[href^='https://slack.com/']")
    assert LazyHTML.attribute(source_link, "target") == ["_blank"]
    assert LazyHTML.attribute(source_link, "rel") == ["noopener noreferrer"]

    full_page =
      HTML.memory(
        %{memories: [], reviews: [], conversation_memory: %{view | learning_activity: @learning}},
        String.duplicate("s", 32)
      )
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert Enum.empty?(
             LazyHTML.query(
               full_page,
               ".learning-summary, section.learning-activity, section.operational-memory, section.memory-review"
             )
           )
  end

  test "learning state stays visible above the views and the activity section follows the entries" do
    # "Learning is disabled" is functional state, not decorative help: it stays
    # in the compact status line, and the full activity section is related
    # operational activity below the primary content.
    document = render_page(%{@view | learning_activity: @learning})

    assert outline(document, "div.conversation-memory > *") == [
             "div.learning-summary",
             "nav.memory-views",
             "form.filter-toolbar",
             "p.result-count",
             "div.memory-cards",
             "section.learning-activity"
           ]

    assert LazyHTML.query(document, ".learning-summary strong") |> LazyHTML.text() ==
             "Learning is disabled"

    assert LazyHTML.query(document, ".learning-summary") |> LazyHTML.text() =~
             "3 messages waiting"

    assert LazyHTML.query(document, "section.learning-activity .memory-unavailable")
           |> LazyHTML.text() =~
             "no background model is maintaining knowledge"

    assert LazyHTML.query(document, "section.learning-activity h2") |> LazyHTML.text() ==
             "Learning activity"

    assert Enum.empty?(LazyHTML.query(document, "section.learning-activity .ui-eyebrow"))
  end

  test "the memory page is help, then conversation memory, then the operational sections without panels" do
    # The help was a bespoke details element with its own class, the related
    # instruction links a loose nav between it and the content, and both
    # operational sections were bordered panels with 22px headings.
    snapshot = %{
      conversation_memory: @view,
      memories: [
        %{
          kind: :repository_binding,
          ref: "memory:one",
          scope: :workspace,
          value: "ryker",
          applicability: nil,
          status: :active,
          subject: "checkout-api"
        }
      ],
      reviews: []
    }

    document =
      HTML.memory(snapshot, String.duplicate("s", 32))
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert outline(document, "div.memory-page > *") == [
             "details.page-help",
             "div.conversation-memory",
             "section.operational-memory",
             "section.memory-review"
           ]

    help = LazyHTML.query(document, "details.page-help#memory-help:not([open])")
    assert LazyHTML.query(help, "summary") |> LazyHTML.text() == "How memory works"
    assert LazyHTML.text(help) =~ "even when it does not reply"
    assert LazyHTML.text(help) =~ "To correct learned knowledge"
    assert LazyHTML.text(help) =~ "does not grant permission"
    assert LazyHTML.text(help) =~ "confirm the proposal"
    assert Enum.empty?(LazyHTML.query(help, "a[href]"))

    assert Enum.empty?(
             LazyHTML.query(
               document,
               ".memory-help, nav.behavior-links, h1, .page-description, .table-wrap"
             )
           )

    assert LazyHTML.query(document, "section.operational-memory > h2") |> LazyHTML.text() ==
             "Operational memory"

    assert LazyHTML.query(
             document,
             "section.operational-memory table.data-table td[data-label='Subject']"
           )
           |> LazyHTML.text() == "checkout-api"

    forget =
      LazyHTML.query(
        document,
        "section.operational-memory form.action-control[method=get][action='/actions/memory/memory%3Aone/forget'] button"
      )

    assert LazyHTML.text(forget) == "Forget"
    assert Enum.empty?(LazyHTML.query(document, "form[method=post]"))

    assert LazyHTML.query(document, "section.memory-review > h2") |> LazyHTML.text() ==
             "Memory review"

    assert LazyHTML.query(document, "section.memory-review p.empty-state") |> LazyHTML.text() =~
             "No stale or duplicate memories need review"

    without_conversation =
      HTML.memory(%{memories: [], reviews: []}, String.duplicate("s", 32))
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert outline(without_conversation, "div.memory-page > *") == [
             "details.page-help",
             "section.operational-memory",
             "section.memory-review"
           ]

    assert LazyHTML.query(without_conversation, "section.operational-memory p.empty-state")
           |> LazyHTML.text() =~
             "No confirmed memory is active"
  end

  test "the route keeps the shell's title and description" do
    page =
      Pages.page(["memory"], %{"kind" => "context", "q" => "deploy"}, %{
        csrf_secret: String.duplicate("s", 32),
        projection: %{
          memory: fn params ->
            %{memories: [], reviews: [], conversation_memory: %{@view | q: params["q"]}}
          end
        }
      })

    assert page.title == "Memory"

    assert page.description ==
             "Memory shows what Ryker learned from conversations and the reusable facts people explicitly asked it to remember."

    document = LazyHTML.from_fragment(page.body)

    assert LazyHTML.query(document, "form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["deploy"]
  end

  defp render_page(view) do
    render_component(&MemoryPage.render/1, view: view, csrf_secret: String.duplicate("s", 32))
    |> LazyHTML.from_fragment()
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
end
