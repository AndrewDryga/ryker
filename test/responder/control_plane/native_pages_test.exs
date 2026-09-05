defmodule Responder.ControlPlane.NativePagesTest do
  use Responder.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{ActivityPage, Assets, Components, EpisodePage, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures

  @now ~U[2026-09-05 12:00:00.000000Z]

  test "populated activity preserves filters, source labels, navigation, and scheduled context" do
    items =
      for {state, index} <- Enum.with_index(~w(pending working blocked complete cancelled), 1) do
        {"request-#{index}",
         %{
           kind: "episode",
           href: "/episodes/request-#{index}",
           title: "Investigate <unsafe> #{index}",
           source: if(index == 1, do: "Conversation Lab", else: "GitHub"),
           repository: "responder",
           target: "configured-target",
           state: state,
           bucket: if(state == "complete", do: "done", else: "running"),
           updated_at: @now,
           started_at: DateTime.add(@now, -120)
         }}
      end

    html =
      render_component(&ActivityPage.render/1,
        overview: %{counts: %{active: 2}, fleet: %{eligible_workers: 1, unavailable: true}},
        activity: %{total: 90, page: 2, pages: 3, mode: "all"},
        params: %{"q" => "trace", "repository" => "responder", "mode" => "all"},
        path: "/episodes",
        now: @now,
        stream: items,
        new_items: 2,
        schedules: [
          %{
            ref: "schedule:one",
            title: "Weekly review",
            next_occurrence_at: @now,
            timezone: "UTC"
          }
        ]
      )

    assert html =~ "Investigate &lt;unsafe&gt;"
    assert html =~ "GitHub"
    assert html =~ "2m since received"
    assert html =~ "Page 2 of 3"
    assert html =~ "page=1"
    assert html =~ "page=3"
    assert html =~ "repository=responder"
    assert html =~ "2 new or reordered requests"
    assert html =~ "Weekly review"
    assert html =~ "1 eligible"
    assert html =~ "Worker status is unavailable"
    refute html =~ "<unsafe>"
  end

  test "a filtered empty activity page does not imply the workspace has no conversations" do
    html =
      render_component(&ActivityPage.render/1,
        overview: %{counts: %{}, fleet: %{required: false}},
        activity: %{total: 0, page: 1, pages: 1, mode: "shadow"},
        params: %{"q" => "absent"},
        path: "/",
        now: @now,
        stream: [],
        new_items: 0,
        schedules: []
      )

    assert html =~ "No matching requests"
    assert html =~ "Clear filters"
    refute html =~ "activity-rail"
    refute html =~ "No requests yet"
  end

  test "worker problems remain actionable without filling an empty inbox with decorative widgets" do
    # The old rail hid worker status at tablet widths and showed invented account status.
    for fleet <- [%{required: true, eligible_workers: 0}, %{unavailable: true}] do
      html =
        render_component(&ActivityPage.render/1,
          overview: %{counts: %{}, fleet: fleet},
          activity: %{total: 0, page: 1, pages: 1, mode: "live"},
          params: %{},
          path: "/",
          now: @now,
          stream: [],
          new_items: 0,
          schedules: []
        )

      assert html =~ "Worker attention"
      assert html =~ "Inspect configuration"
      assert html =~ "href=\"/workspaces\""
      assert html =~ "No requests yet"
      refute html =~ "Coming up"
      refute html =~ "Test your responder"
      refute html =~ "Local operator"
      refute html =~ "empty-orbit"
    end
  end

  test "the episode shows cost coverage, recovery evidence, and confirmed answers together" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    step = List.last(snapshot.trace.steps)

    message = %{
      id: "confirmed",
      actor: "Responder",
      at: @now,
      status: "Delivery confirmed",
      available: true,
      text: "A retained answer <not markup>",
      href: "requests?kind=work&attempt=confirmed"
    }

    trace =
      snapshot.trace
      |> Map.put(:source, %{href: "https://slack.com/archives/C123/p123", label: "Open source"})
      |> Map.put(:history, %{truncated: true})
      |> Map.put(:stopped, %{
        headline: "Delivery needs attention",
        reason: "The provider did not confirm delivery",
        action: "Review the retained request before retrying",
        href: "/failures/delivery/example",
        attempted: ["Reconciled the previous request"]
      })
      |> Map.put(:steps, [%{step | href: "/admission/example"}])
      |> Map.update!(:case_file, fn file ->
        %{file | conversation: [message], repository: "responder", reply: message.text}
      end)

    snapshot = %{
      snapshot
      | trace: trace,
        accounting: %{costed: 1, attempts: 2, cost_usd: Decimal.new("0.12")}
    }

    html = episode_html(snapshot)

    assert html =~ "$0.12"
    assert html =~ "1/2 requests priced"
    assert html =~ "Delivery confirmed"
    assert html =~ "A retained answer &lt;not markup&gt;"
    assert html =~ "Inspect accepted answer"
    assert html =~ "History is bounded"
    assert html =~ "Already attempted"
    assert html =~ "Reconciled the previous request"
    assert html =~ "Open recovery"
    assert html =~ "Inspect related record"
    # The split panes hid the processing behind tabs and a second scroll area.
    assert html =~ "Complete execution timeline"
    refute html =~ "aria-label=\"Episode view\""
    refute html =~ "aria-label=\"Selected event\""
    refute html =~ "phx-click=\"inspect-step\""

    for {state, expected} <- [{:cancelled, "Stopped"}, {:complete, "No further reply was sent"}] do
      terminal = put_in(snapshot, [:episode, :state], state)
      assert episode_html(terminal) =~ expected
    end

    following = put_in(snapshot, [:trace, :stopped], nil)
    assert episode_html(following) =~ "Follow-up in progress"
  end

  test "elapsed labels remain meaningful across missing, naive, future, and long-lived timestamps" do
    assert Components.age(nil, @now) == "—"
    assert Components.age(DateTime.add(@now, 60), @now) == "0s"
    assert Components.age(DateTime.to_naive(DateTime.add(@now, -61)), @now) == "1m"
    assert Components.age(DateTime.add(@now, -3660), @now) == "1h 1m"
    assert Components.age(DateTime.add(@now, -172_800), @now) == "2d"
    assert Components.timestamp(DateTime.to_naive(@now)) == "05 Sep, 12:00 UTC"

    for {state, expected} <- [
          {"pending", "Queued"},
          {"waiting_for_input", "Needs your input"},
          {"waiting_for_event", "Waiting for an event"},
          {"delivery_pending", "Sending reply"},
          {"ignore", "No response needed"},
          {"react", "Reaction selected"},
          {"reply", "Reply selected"}
        ] do
      assert render_component(&Components.status/1, state: state) =~ expected
    end
  end

  test "the packaged asset allowlist serves local modules but never arbitrary paths" do
    for file <-
          ~w(phoenix.mjs phoenix_live_view.esm.js control-plane.js drafts.mjs control-plane.css workspace.css) do
      conn = Assets.call(Plug.Test.conn(:get, "/#{file}"), [])
      assert conn.status == 200
      assert conn.halted
      assert conn.resp_body != ""
    end

    for {method, path} <- [{:get, "/unknown"}, {:get, "/../mix.exs"}, {:post, "/workspace.css"}] do
      assert Assets.call(Plug.Test.conn(method, path), []).status == 404
    end
  end

  defp episode_html(snapshot),
    do:
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        selected_step: nil,
        requests: nil,
        params: %{}
      )
end
