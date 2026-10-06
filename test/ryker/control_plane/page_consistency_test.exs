defmodule Ryker.ControlPlane.PageConsistencyTest do
  @moduledoc """
  Andrew, 2026-09-24, comparing Activity, Incident rooms, Failures, Channels
  and Working copies: "Look how different all those pages are, can we do
  consistency at least in terms of layouts, ideally reusing components and
  not doing one-off things. If we need counts, table views, cards list etc
  they should look standard across all app."

  Each list page had grown its own toolbar wrapper (`.manage-filters`,
  `.memory-tools`, `.schedule-toolbar`, `.follow-up-toolbar`,
  `.behavior-toolbar`, a framed collection shell with tabs on Activity and
  Incident rooms) and each page that led with numbers had its own counts
  (a definition-list summary on Activity, framed stat panels on Usage). The
  same thing drawn five ways reads as five designs. These tests render the
  pages side by side and hold them to one structure, so a page that grows
  its own wrapper again fails here, not in a screenshot review.

  Usage & cost is the one exception: Andrew, 2026-09-25, "this page
  specifically was looking pretty much perfect before you redesigned it", so
  it keeps its approved panels and grouped tables.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{ActivityPage, Assets, BehaviorPage, ChannelPage, EnvironmentsPage}
  alias Ryker.ControlPlane.{FailuresPage, Kit, PageHelp, Pages, UsagePage, WorkingCopiesPage}
  alias Ryker.Fixtures.ControlPlaneOptions

  @retired ~w(.collection-shell .manage-filters .memory-tools .memory-filter .schedule-toolbar
              .follow-up-toolbar .behavior-toolbar .page-summary .ui-tabs .data-table)

  test "every list page's search and view switch sit in the one Kit toolbar row" do
    for {name, document} <- list_pages() do
      toolbars = LazyHTML.query(document, ".kit-toolbar")
      assert Enum.count(toolbars) == 1, "#{name} has #{Enum.count(toolbars)} toolbar rows"

      assert LazyHTML.query(document, ".kit-toolbar > .filter-toolbar") |> Enum.count() == 1,
             "#{name}'s search is not the shared filter toolbar inside the Kit toolbar"

      assert LazyHTML.query(document, ".filter-toolbar") |> Enum.count() == 1,
             "#{name} has a search outside its toolbar row"

      assert LazyHTML.query(document, "nav.segmented") |> Enum.count() ==
               LazyHTML.query(document, ".kit-toolbar > nav.segmented") |> Enum.count(),
             "#{name} has a view switch outside its toolbar row"

      for retired <- @retired,
          do: assert(Enum.empty?(LazyHTML.query(document, retired)), "#{name} uses #{retired}")
    end
  end

  # Andrew, 2026-09-25: "'To open one, ask Ryker in the alert's Slack
  # thread: …' — this should be replaced with a collapsible on top of the
  # page or a help column on the right … On all pages." Seven lists ended in
  # a line of small print on how to ask for one; the rest said nothing. How
  # to use a page is now the shell's one "How this page works" panel
  # (PageHelp), which LinkCrawlTest finds on every page, so no list explains
  # itself in its body again.
  test "no list page explains itself under its list; every one has the shell's help" do
    for {name, document} <- list_pages() do
      assert Enum.empty?(LazyHTML.query(document, ".ask-hint, .page-help")),
             "#{name} explains itself in its body"
    end

    for path <-
          ~w(/ /incident-rooms /environments /channels /repositories /schedules /follow-ups /rules /memory /memory/learned),
        do: assert(PageHelp.for_path(path), "#{path} has no help")
  end

  # The hint component went with the hints. Left in the Kit, `ask_hint` is
  # the easiest way for the next list to explain itself in small print again,
  # and a stylesheet rule for a class no page renders is the same invitation.
  test "the Kit no longer offers a one-line hint, and nothing styles one" do
    Code.ensure_loaded!(Kit)
    refute function_exported?(Kit, :ask_hint, 1), "Kit.ask_hint/1 still exists"

    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    refute css =~ ".ask-hint", "workspace.css still styles .ask-hint"
  end

  # Andrew, 2026-09-25: the toolbar's quiet "18 items" said again what the
  # counts row above it already said, in a second place and a second type
  # size. A page's numbers now live in one place, its Kit counts, and the
  # first of them is how many things the list holds, with their noun.
  test "every list page that leads with numbers says them as Kit counts and no toolbar has a count" do
    for {name, document} <- list_pages() do
      assert Enum.empty?(LazyHTML.query(document, ".kit-toolbar-count")),
             "#{name}'s toolbar repeats a count"

      refute LazyHTML.query(document, ".kit-toolbar") |> LazyHTML.text() =~
               ~r/\b\d+\s+(items?|requests?|matching|rooms?|incident rooms?|environments?)\b/,
             "#{name}'s toolbar says a count"
    end

    for {name, document, leading} <- [
          {"Activity", activity(), ["1 request", "1 in progress", "0 need you"]},
          {"Incident rooms", page("/incident-rooms"), ["1 room", "1 open"]},
          {"Environments", environments(), ["1 environment", "1 channel without an environment"]}
        ] do
      counts = LazyHTML.query(document, ".kit-counts > .kit-count")

      assert Enum.all?(counts, &(LazyHTML.query(&1, "b") |> Enum.count() == 1)),
             "#{name} has a count without its number"

      assert Enum.map(counts, &words/1) == leading, "#{name} leads with other numbers"

      html = LazyHTML.to_html(document)

      assert position(html, "kit-counts") < position(html, "kit-toolbar"),
             "#{name}'s counts do not lead the page"

      for retired <- @retired,
          do: assert(Enum.empty?(LazyHTML.query(document, retired)), "#{name} uses #{retired}")
    end
  end

  # Andrew, 2026-09-28, of Environments, Channels and Repositories beside
  # Activity: "here you can click on entire row, do it here too … same issue
  # on many other pages, we need more consistency and component reuse in our
  # design". Rows had Edit, Remove, Review, Open and Manage buttons beside a
  # name that already opened the same page. A row that opens a page of its
  # own opens it from anywhere on the row and carries no buttons: what can be
  # done to the item is on its page.
  test "every row that opens a page opens it from the whole row and carries no buttons" do
    linked =
      for {name, document} <- list_pages(),
          row <- LazyHTML.query(document, ".entity-row"),
          not Enum.empty?(LazyHTML.query(row, ".entity-name a")) do
        label = "#{name}: #{row |> LazyHTML.query(".entity-name") |> words()}"
        assert LazyHTML.attribute(row, "class") |> hd() =~ "entity-row-link", label

        assert Enum.empty?(LazyHTML.query(row, ".entity-actions, .ui-button")),
               "#{label} has buttons of its own"

        name
      end

    for page <- ~w(Activity Environments Channels Repositories),
        do: assert(page in linked, "#{page} rendered no row that opens a page")
  end

  # Andrew, 2026-09-26: "Empty table states across the app should not look
  # like title+subtitle, they need to be properly designed, otherwise tables
  # look like text blobs and you can't tell it's an empty state without
  # reading it all." A channel with nothing on it showed five, each a bold
  # line and a grey line under its section's own bold title and grey
  # sentence, and Usage said so in one grey line per breakdown. Each page
  # below is rendered with nothing in it: every empty part shows the Kit's
  # empty state, whole, and no sentence saying there is nothing sits outside
  # one, so a hand-rolled empty state on these pages fails here.
  test "every empty state on a sample of empty pages is the Kit empty state" do
    for {name, document, expected} <- empty_pages() do
      empties = LazyHTML.query(document, ".kit-empty")
      assert Enum.count(empties) == expected, "#{name} shows #{Enum.count(empties)} empty states"

      for empty <- empties do
        title = empty |> LazyHTML.query(".kit-empty-title") |> LazyHTML.text()
        assert title != "", "#{name} has an empty state without a title"

        assert LazyHTML.query(empty, ".kit-empty-icon > svg") |> Enum.count() == 1,
               "#{name}: “#{title}” has no icon"

        assert LazyHTML.query(empty, ".kit-empty-text") |> LazyHTML.text() != "",
               "#{name}: “#{title}” says nothing under its title"
      end

      assert hand_rolled(document) == [], "#{name} says it is empty outside the Kit empty state"
    end
  end

  # QA 2026-09-25: a request's timeline ran 1416px wide at a 1440px window
  # while Activity, the page a reader opens it from, stopped at 1280px. The
  # timeline takes Activity's gutter and its content width.
  test "a request's timeline reads at the width Activity reads at" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    activity = top_level(css, ".ryker-app .native-page > .activity-page")
    timeline = top_level(css, ".episode-workbench")

    assert timeline["padding"] == activity["padding"]
    assert timeline["max-width"] == activity["max-width"]

    assert top_level(css, ".episode-workbench > *")["max-width"] ==
             top_level(css, ".activity-section")["max-width"]
  end

  # The declarations the unconditional rules for `selector` leave in force:
  # later rules win, and rules inside an at-rule block are not read.
  defp top_level(css, selector) do
    css
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> top_level_rules()
    |> Enum.filter(fn {selectors, _body} ->
      selector in (selectors |> String.split(",") |> Enum.map(&String.trim/1))
    end)
    |> Enum.flat_map(fn {_selectors, body} ->
      for declaration <- String.split(body, ";"),
          [name, value] <- [String.split(declaration, ":", parts: 2)],
          do: {String.trim(name), String.trim(value)}
    end)
    |> Map.new()
  end

  defp top_level_rules(css), do: top_level_rules(css, [])

  defp top_level_rules(css, rules) do
    case Regex.run(~r/\A\s*([^{}]+)\{/, css) do
      nil ->
        Enum.reverse(rules)

      [head, prelude] ->
        rest = binary_part(css, byte_size(head), byte_size(css) - byte_size(head))
        {body, rest} = block(rest, 1, "")

        if String.starts_with?(String.trim(prelude), "@"),
          do: top_level_rules(rest, rules),
          else: top_level_rules(rest, [{String.trim(prelude), body} | rules])
    end
  end

  defp block(<<"}", rest::binary>>, 1, body), do: {body, rest}
  defp block(<<"}", rest::binary>>, depth, body), do: block(rest, depth - 1, body <> "}")
  defp block(<<"{", rest::binary>>, depth, body), do: block(rest, depth + 1, body <> "{")

  defp block(<<char::utf8, rest::binary>>, depth, body),
    do: block(rest, depth, body <> <<char::utf8>>)

  defp block(<<>>, _depth, body), do: {body, ""}

  defp words(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # Where the first element carrying `class` opens in the page.
  defp position(html, class) do
    case Regex.run(~r/class="#{class}[" ]/, html, return: :index) do
      [{position, _length}] -> position
      nil -> flunk(".#{class} is not on the page")
    end
  end

  defp list_pages do
    [
      {"Activity", activity()},
      {"Incident rooms", page("/incident-rooms")},
      {"Environments", environments()},
      {"Channels", page("/channels")},
      {"Repositories", page("/repositories")},
      {"Schedules", page("/schedules")},
      {"Follow-ups", page("/follow-ups")},
      {"Rules", rules()},
      {"Facts", page("/memory")},
      {"Learned", page("/memory/learned")}
    ]
  end

  defp activity do
    render_component(&ActivityPage.render/1,
      fleet: %{required: false},
      activity: %{
        total: 1,
        page: 1,
        pages: 1,
        mode: "live",
        views: %{"attention" => 0, "running" => 1, "done" => 0}
      },
      params: %{},
      path: "/",
      now: ~U[2026-09-24 12:00:00Z],
      stream: [
        {"activity-episode-1",
         %{
           kind: "episode",
           href: "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e",
           title: "Why did checkout slow down?",
           source: "Direct conversation",
           repository: nil,
           state: "working",
           bucket: "running",
           updated_at: ~U[2026-09-24 11:58:00Z],
           started_at: ~U[2026-09-24 11:57:00Z]
         }}
      ],
      new_items: 0,
      schedules: []
    )
    |> LazyHTML.from_fragment()
  end

  defp environments do
    environment = %Ryker.Settings.Environment{
      ref: "production",
      display_name: "Production",
      is_default: true,
      repositories: [
        %Ryker.Settings.EnvironmentRepository{
          environment_ref: "production",
          repository_ref: "api",
          position: 0
        }
      ]
    }

    view = %{
      # Two channels chose Production and one chose no environment.
      environment_channels: %{"production" => 2, nil => 1},
      snapshot: %{
        emisar_connections: [],
        environments: [environment],
        repositories: [%{ref: "api", display_name: "acme/api", github_repository: "acme/api"}],
        webhook_sources: []
      }
    }

    render_component(&EnvironmentsPage.render/1, view: view, params: %{})
    |> LazyHTML.from_fragment()
  end

  defp rules do
    view = %{
      params: %{"q" => "", "view" => "current"},
      counts: %{},
      items: [],
      page: 1,
      pages: 1,
      total: 0,
      runs: []
    }

    %{__changed__: nil, view: view}
    |> BehaviorPage.rules()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp page(path) do
    page =
      Pages.page(String.split(path, "/", trim: true), %{}, ControlPlaneOptions.options(self()))

    assert page.status == 200, "#{path} answered #{page.status}"
    LazyHTML.from_fragment(page.body)
  end

  # Pages with nothing in them, each with how many empty parts it has.
  defp empty_pages do
    [
      {"A channel", empty_channel(), 5},
      {"Rules", rules(), 1},
      {"Working copies", empty_working_copies(), 1},
      {"Failures", [] |> FailuresPage.list() |> fragment(), 1},
      {"Usage & cost", empty_usage(), 8}
    ]
  end

  # The recorded channel, with none of its lists holding anything.
  defp empty_channel do
    {:ok, view} =
      ControlPlaneOptions.options(self()).projection.channel.("T123", "C456", %{})

    nothing = fn relation -> %{relation | items: [], total: 0, page: 1, pages: 1} end
    view = Enum.reduce(~w(episodes schedules summaries)a, view, &Map.update!(&2, &1, nothing))
    assigns = %{__changed__: nil, view: view, now: ~U[2026-09-26 12:00:00Z]}

    [ChannelPage.lead(assigns), ChannelPage.render(assigns)]
    |> Enum.map(&Safe.to_iodata/1)
    |> fragment()
  end

  defp empty_working_copies do
    worker = %{
      allocation: "open",
      bytes: %{"disposable_bytes" => 0, "protected_bytes" => 0, "unattributed_bytes" => nil},
      id: "worker-a",
      last_seen_at: ~U[2026-09-26 11:59:00Z],
      measured_at: "2026-09-26T11:58:00Z",
      measurement: :fresh,
      reclaimed_bytes: 0,
      refusal_reason: nil,
      state: :idle
    }

    %{
      copies: %{current: [], removed: %{key: "page", items: [], total: 0, page: 1, pages: 1}},
      storage: %{budget: %{}, preview: [], workers: [worker]},
      now: nil
    }
    |> WorkingCopiesPage.html()
    |> fragment()
  end

  defp empty_usage do
    snapshot = ControlPlaneOptions.options(self()).projection.usage.(%{})

    zero = fn
      %Decimal{} -> Decimal.new(0)
      value when is_number(value) -> 0
      value -> value
    end

    totals = Map.new(snapshot.totals, fn {key, value} -> {key, zero.(value)} end)

    %{snapshot | days: [], targets: [], channels: [], repositories: [], totals: totals}
    |> UsagePage.render()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_document()
  end

  defp fragment(iodata), do: iodata |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

  # What says a list or a part of a page has nothing in it, outside a Kit
  # empty state. A fact's value ("None, so …") and a row's facts are not
  # empty states.
  @nothing ~r/^(No|Nothing|Nobody|None yet|Ryker has not)\b/

  defp hand_rolled(document) do
    said = texts(document, "p, li, strong, span, td, h3")
    allowed = texts(document, ".kit-empty *, dd, dd *, option, .entity-row *")
    Enum.filter(said -- allowed, &(&1 =~ @nothing))
  end

  defp texts(document, selector) do
    for node <- LazyHTML.query(document, selector),
        do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end
end
