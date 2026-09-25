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
  alias Ryker.ControlPlane.{ActivityPage, BehaviorPage, EnvironmentsPage, Pages}
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

  test "a list page that leads with numbers says them as Kit counts" do
    document = activity()
    counts = LazyHTML.query(document, ".kit-counts > .kit-count")
    assert Enum.count(counts) >= 3, "Activity does not lead with Kit counts"

    assert Enum.all?(counts, &(LazyHTML.query(&1, "b") |> Enum.count() == 1)),
           "Activity has a count without its number"

    for retired <- @retired,
        do: assert(Enum.empty?(LazyHTML.query(document, retired)), "Activity uses #{retired}")
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
      overview: %{counts: %{active: 1, waiting: 0, blocked: 0}, fleet: %{required: false}},
      activity: %{total: 1, page: 1, pages: 1, mode: "live"},
      params: %{},
      path: "/",
      now: ~U[2026-09-24 12:00:00Z],
      stream: [
        {"activity-episode-1",
         %{
           kind: "episode",
           href: "/timeline/episode%3Aone",
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
      environment_channels: %{"production" => 2},
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
      params: %{"q" => "", "status" => "current"},
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
end
