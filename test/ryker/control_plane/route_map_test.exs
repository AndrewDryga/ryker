defmodule Ryker.ControlPlane.RouteMapTest do
  @moduledoc """
  The approved naming cutover is a route contract, not a label change.

  Operators keep links. An operator who bookmarks a Timeline and finds a 404 has
  lost a record; an operator who follows a generated link into a surface that no
  longer exists has lost a diagnosis. These tests hold the whole map shut at
  once: every generated link, the live routes behind them, the invalidation
  domains and the removal of the superseded paths.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Ryker.ControlPlane.{Activity, Endpoint, ModelRequests, Navigation, Updates}
  alias Ryker.ControlPlane.{ConversationLab, Projection}
  alias Ryker.Ingress.WorkProfile

  @endpoint Endpoint

  setup do
    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Ryker.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: %{
           actions: %{},
           csrf_secret: String.duplicate("s", 32),
           observability: %{},
           projection: Projection.callbacks()
         }
       ]}
    )

    :ok
  end

  defp conn, do: build_conn() |> Map.put(:host, "localhost")

  test "Activity, Timeline and Model calls answer at their approved routes" do
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    timeline = "/timeline/" <> URI.encode_www_form(episode.key)

    assert {:ok, _view, activity} = live(conn(), "/activity")
    assert activity =~ "Activity"

    assert {:ok, _view, root} = live(conn(), "/")
    assert root =~ "Activity"

    assert {:ok, view, _html} = live(conn(), timeline)
    assert has_element?(view, "#execution-timeline")

    assert {:ok, calls, _html} = live(conn(), timeline <> "/model-calls")
    assert has_element?(calls, ".model-inspector")
  end

  test "superseded episode routes are removed rather than redirected" do
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    encoded = URI.encode_www_form(episode.key)

    for path <- ["/episodes", "/episodes/" <> encoded, "/episodes/#{encoded}/requests"] do
      response = get(conn(), path)
      assert response.status == 404, "#{path} must not resolve"
      assert get_resp_header(response, "location") == []
    end

    # The retained record itself survives the route removal.
    assert {:ok, view, _html} = live(conn(), "/timeline/" <> encoded)
    assert has_element?(view, "#execution-timeline")
  end

  test "generated links name the approved routes" do
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    assert Activity.conversation_path("slack", "slack:T1:C1") =~ "/activity?"

    assert %{items: items} = Activity.list(%{"mode" => "all"})
    assert items != []
    assert Enum.all?(items, &String.starts_with?(&1.href, "/timeline/"))

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    hrefs =
      timeline.items
      |> Enum.map(& &1[:href])
      |> Enum.reject(&is_nil/1)

    assert Enum.all?(hrefs, &String.contains?(&1, "model-calls"))

    sidebar = Phoenix.LiveViewTest.render_component(&Navigation.sidebar/1, path: "/", live: false)
    assert sidebar =~ "Activity"
    refute sidebar =~ ">Requests<"
  end

  test "a deep link into an input with no episode resolves on the Timeline route" do
    {:ok, entry} = lab_entry()

    assert {:ok, view, _html} = live(conn(), "/timeline/ingress-input%3A#{entry.id}")
    assert has_element?(view, ".back-to-activity", "Activity")
    assert has_element?(view, ".model-inspector")
  end

  test "live invalidation reaches the renamed surfaces a reader is actually on" do
    assert Updates.domain("/") == "activity"
    assert Updates.domain("/activity") == "activity"
    assert Updates.domain("/timeline/episode%3Aone") == "timeline"
    assert Updates.domain("/timeline/episode%3Aone/model-calls") == "timeline"

    # A renamed route with a stale invalidation table leaves an open Timeline
    # frozen while execution continues, which reads exactly like a stuck run.
    for domain <- ["activity", "timeline"] do
      Phoenix.PubSub.subscribe(Ryker.ControlPlane.PubSub, "control-plane:#{domain}")
    end

    state = %{connection: self(), reference: make_ref(), pending: MapSet.new(), timer: nil}

    {:noreply, pending} =
      Updates.handle_info(
        {:notification, self(), state.reference, "ryker_control_plane",
         "ingress_inbox_entries"},
        state
      )

    assert MapSet.member?(pending.pending, "timeline")
    assert MapSet.member?(pending.pending, "activity")
    Process.cancel_timer(pending.timer)
  end

  defp lab_entry do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "route-map-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    {:ok, %{entry: entry}} =
      ConversationLab.send_message(
        Ecto.UUID.generate(),
        "Investigate admission",
        profile
      )

    {:ok, entry}
  end
end
