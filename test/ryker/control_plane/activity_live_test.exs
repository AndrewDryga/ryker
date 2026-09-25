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

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "activity-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    options = %{
      actions: Actions.callbacks(profile),
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.merge(Projection.callbacks(), %{
          overview: fn ->
            %{counts: %{active: 2, waiting: 0, blocked: 1}, fleet: %{required: false}}
          end,
          activity: fn params ->
            list = Agent.get(items, & &1)

            %{
              items: list,
              total: length(list),
              page: 1,
              pages: 1,
              mode: params["mode"] || "live",
              searchable: true
            }
          end,
          schedules: fn _params -> [] end
        })
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Ryker.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: options
       ]}
    )

    %{items: items}
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

    view |> element("a.kit-count", "blocked") |> render_click()
    assert_patch(view, "/?filter=attention")
  end

  # A reconcile queues one projection refresh a moment later.
  defp refresh(view) do
    send(view.pid, :reconcile)
    Process.sleep(80)
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
