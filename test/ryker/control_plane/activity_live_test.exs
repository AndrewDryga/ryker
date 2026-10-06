defmodule Ryker.ControlPlane.ActivityLiveTest do
  @moduledoc """
  Activity's rows moved into the shared Kit list on 2026-09-24. They are still
  a LiveView stream, and the Kit list must pass the stream through untouched:
  a refresh that re-rendered or reordered every row would move the list under
  the reader, and a view switch that reloaded the page would drop its filters.
  """
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Ingress.WorkProfile

  @endpoint Endpoint

  setup do
    {:ok, items} = Agent.start_link(fn -> [item(1), item(2)] end)
    # Whether the database answers Activity's read.
    {:ok, reachable} = Agent.start_link(fn -> true end)

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "activity-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    options = %{
      actions: Actions.callbacks(%{environments: %{}, fallback_work_profile: profile}),
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.merge(Projection.callbacks(), %{
          fleet: fn -> %{required: false} end,
          activity: fn params ->
            unless Agent.get(reachable, & &1),
              do: raise(DBConnection.ConnectionError, "connection not available")

            list = Agent.get(items, & &1)

            %{
              items: list,
              total: length(list),
              page: 1,
              pages: 1,
              mode: params["mode"] || "live",
              searchable: true,
              views: %{"attention" => 1, "running" => 2, "done" => 0}
            }
          end,
          schedules: fn _params -> [] end,
          usage_filter_options: fn ->
            [%{conversation_ref: "slack:T123:C456", conversation_label: "#deploys"}]
          end
        })
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Ryker.PubSub.Server,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: options
       ]}
    )

    %{items: items, reachable: reachable}
  end

  # A link carrying `q[x]=y` handed the page a map where the search field needs text, and the page
  # crashed (2026-10-04 review). A parameter that is not text is no parameter.
  test "a query parameter that is not text is ignored rather than crashing the page" do
    for query <- ["q[x]=y", "mode[x]=all", "filter[]=running", "page[x]=2"] do
      {:ok, view, _html} =
        live(build_conn() |> Map.put(:host, "localhost"), "/activity?" <> query)

      assert has_element?(view, "#activity-stream")
    end
  end

  test "activity rows stay a live stream inside the Kit list and its views patch in place", %{
    items: items
  } do
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), "/")
    rows = "#activity-stream[phx-update=stream] > article.entity-row.entity-row-link"
    assert has_element?(view, rows <> "#activity-episode-id-1")

    assert has_element?(
             view,
             rows <> " a[data-phx-link=redirect][href='/timeline/e1']",
             "Request 1"
           )

    # A newer request waits behind the button; the rows on screen stay put.
    Agent.update(items, &[item(3) | &1])
    refresh(view)
    assert has_element?(view, "button.new-activity", "1 new or reordered items")
    refute has_element?(view, "#activity-episode-id-3")
    assert has_element?(view, "#activity-episode-id-1")

    view |> element("button.new-activity") |> render_click()
    assert has_element?(view, rows <> "#activity-episode-id-3")

    # A request that is gone leaves the list, so it cannot be acted on.
    Agent.update(items, fn list -> Enum.reject(list, &(&1.id == "id-2")) end)
    refresh(view)
    refute has_element?(view, "#activity-episode-id-2")

    # The views and the counts switch the list in place.
    view |> element(".kit-toolbar nav.segmented a", "In progress") |> render_click()
    assert_patch(view, "/?filter=running")
    assert has_element?(view, "nav.segmented a[aria-current=page]", "In progress")

    view |> element("a.kit-count", "needs you") |> render_click()
    assert_patch(view, "/?filter=attention")
  end

  # The retry after a failed read merged into the rows that read never drew:
  # after a database blip, Activity came back empty behind "2 new or
  # reordered items · Show latest", its filter menu with nothing to choose,
  # while Try again beside it would have shown the whole list. The retry the
  # page runs by itself now reads the page the way Try again does.
  test "Activity that could not be read comes back whole once the database answers", %{
    reachable: reachable
  } do
    Agent.update(reachable, fn _ -> false end)

    {view, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), "/")
        view
      end)

    assert has_element?(view, ".document-unavailable", "temporarily unavailable")

    Agent.update(reachable, fn _ -> true end)
    refresh(view)

    rows = "#activity-stream[phx-update=stream] > article.entity-row"
    assert has_element?(view, rows <> "#activity-episode-id-1")
    assert has_element?(view, rows <> "#activity-episode-id-2")
    refute has_element?(view, "button.new-activity")
    refute has_element?(view, ".app-warning", "could not refresh")

    view |> element("#filter-add") |> render_click()
    assert has_element?(view, "#filter-values-conversation button", "#deploys")
  end

  # The reload an announcement or a failed read schedules, run now.
  defp refresh(view) do
    send(view.pid, :reload_page)
    render(view)
  end

  defp item(index) do
    %{
      id: "id-#{index}",
      kind: "episode",
      href: "/timeline/e#{index}",
      title: "Request #{index}",
      source: "Direct conversation",
      conversation: nil,
      repository: nil,
      state: "working",
      bucket: "running",
      updated_at: DateTime.utc_now(),
      started_at: DateTime.utc_now()
    }
  end
end
