defmodule Ryker.ControlPlane.ConversationHistoryLiveTest do
  @moduledoc """
  How the live conversation page holds its loaded window of history.

  Until 2026-09-13 every refresh replaced the transcript with the latest
  snapshot and deleted any loaded row the snapshot did not repeat, so history
  the reader had scrolled up to vanished under them on the next reconcile.
  These tests pin the window: pages prepend, refreshes merge, and only a
  change of conversation resets anything.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{ConversationLab, Endpoint, Projection}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Repo

  @endpoint Endpoint
  @epoch ~U[2026-09-05 09:00:00.000000Z]

  setup do
    {:ok, faults} = Agent.start_link(fn -> %{history_failures: 0} end)

    options = %{
      actions: %{},
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.merge(Projection.callbacks(), %{
          overview: fn -> %{counts: %{active: 0}, needs_attention: []} end,
          activity: fn params ->
            %{items: [], total: 0, page: 1, pages: 1, mode: params["mode"] || "live"}
          end,
          lab_history: fn conversation_id, cursor, limit ->
            failures =
              Agent.get_and_update(
                faults,
                &{&1.history_failures, %{&1 | history_failures: max(&1.history_failures - 1, 0)}}
              )

            if failures > 0,
              do: raise(DBConnection.ConnectionError, "history store unavailable"),
              else: Projection.lab_history(conversation_id, cursor, limit)
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

    %{faults: faults}
  end

  test "older loaded rows survive a live refresh" do
    id = conversation!(120)
    {:ok, view, _html} = open(id)
    assert length(transcript(view)) == 50
    assert hd(transcript(view)) == "Message 71"

    assert %{"status" => "loaded"} = load_older(view, id)
    assert length(transcript(view)) == 100
    assert hd(transcript(view)) == "Message 21"

    # A reconcile only repeats the latest page. The fifty older rows the
    # reader scrolled up to are not in it and must not be taken away.
    render_hook(view, "refresh", %{})
    assert length(transcript(view)) == 100
    assert hd(transcript(view)) == "Message 21"
    assert List.last(transcript(view)) == "Message 120"
  end

  test "a stale load cannot pollute a different conversation" do
    first = conversation!(60)
    second = conversation!(3, "Second")
    {:ok, view, _html} = open(first)
    stale = history(view)

    render_patch(view, "/conversations/#{second}")
    assert transcript(view) == ["Second 1", "Second 2", "Second 3"]

    # The reply is explicit so a hook never treats silence as a page.
    assert %{"status" => "ignored"} = load_older(view, first, stale.before)
    assert transcript(view) == ["Second 1", "Second 2", "Second 3"]
    refute render(view) =~ "Message 60"
  end

  test "repeated triggers and retries do not double-prepend" do
    id = conversation!(120)
    {:ok, view, _html} = open(id)
    boundary = history(view).before
    assert %{"status" => "loaded"} = load_older(view, id, boundary)

    # The same trigger again, as a scroll listener and a click can both fire
    # before the first page lands: the boundary has moved on, so it is ignored.
    assert %{"status" => "ignored"} = load_older(view, id, boundary)
    assert length(transcript(view)) == 100
    assert transcript(view) == Enum.map(21..120, &"Message #{&1}")

    assert %{"status" => "loaded"} = load_older(view, id)
    assert transcript(view) == Enum.map(1..120, &"Message #{&1}")
    assert history(view).exhausted
    assert history(view).before == nil
    assert %{"status" => "ignored"} = load_older(view, id)
    assert length(transcript(view)) == 120
  end

  test "a failed page load is retryable and never reads as the beginning of history", %{
    faults: faults
  } do
    id = conversation!(70)
    {:ok, view, _html} = open(id)
    Agent.update(faults, &%{&1 | history_failures: 1})

    assert %{"status" => "failed"} = load_older(view, id)
    assert has_element?(view, "#lab-history[data-history-state=failed]")
    assert has_element?(view, ".lab-history-failed button[phx-click=load-older]", "Try again")
    assert length(transcript(view)) == 50

    # The retry reuses the boundary the failed load was given.
    assert %{"status" => "loaded"} = load_older(view, id)
    assert transcript(view) == Enum.map(1..70, &"Message #{&1}")
    assert has_element?(view, "#lab-history[data-history-state=exhausted]")
    refute has_element?(view, ".lab-load-earlier")
    refute has_element?(view, ".lab-history-failed")
  end

  test "live arrivals merge into the loaded window in transcript order, even a burst larger than a page" do
    id = conversation!(120)
    {:ok, view, _html} = open(id)
    assert %{"status" => "loaded"} = load_older(view, id)
    assert length(transcript(view)) == 100

    # One message committed with a timestamp between loaded rows, then a
    # burst of sixty: more than one page arrives between two refreshes.
    {:ok, %{entry: backdated}} = send!(id, "Backdated between 100 and 101", 1000)

    Repo.update_all(from(e in Entry, where: e.id == ^backdated.id),
      set: [inserted_at: DateTime.add(@epoch, 100, :second) |> DateTime.add(500, :millisecond)]
    )

    for index <- 121..180, do: send!(id, "Message #{index}", index)
    render_hook(view, "refresh", %{})

    expected =
      Enum.map(21..100, &"Message #{&1}") ++
        ["Backdated between 100 and 101"] ++ Enum.map(101..180, &"Message #{&1}")

    assert transcript(view) == expected

    # An edit updates the row in place; nothing moves and nothing repeats.
    "control-plane-item:" <> item_id = backdated.source_item_ref
    {:ok, _edited} = ConversationLab.edit_message(id, item_id, "Backdated, corrected", profile())
    render_hook(view, "refresh", %{})
    assert transcript(view) == List.replace_at(expected, 80, "Backdated, corrected")
  end

  test "the transcript offers a keyboard-reachable Load earlier action and no fixed message cap" do
    id = conversation!(60)
    {:ok, view, html} = open(id)
    refute html =~ "Latest 200"
    refute html =~ "200 visible"
    assert has_element?(view, "#lab-history[data-history-state=more][data-conversation='#{id}']")

    assert has_element?(
             view,
             "#lab-history-edge button.lab-load-earlier[phx-click=load-older][phx-value-conversation='#{id}']",
             "Load earlier"
           )

    assert has_element?(view, "#lab-history-latest[phx-update=ignore] button.lab-new-messages")

    view
    |> element("#lab-history-edge button.lab-load-earlier")
    |> render_click()

    # Andrew, 2026-09-19: reaching the first message needs no "Start of the
    # retained conversation" marker. The missing Load earlier action already
    # says nothing older exists, and a message retention expired keeps its
    # place in the transcript, so "retained" hedged against nothing.
    assert transcript(view) == Enum.map(1..60, &"Message #{&1}")
    assert has_element?(view, "#lab-history[data-history-state=exhausted]")
    refute has_element?(view, ".lab-load-earlier")
    refute render(element(view, "#lab-history-edge")) =~ "Start of the"

    # An empty conversation shows no history edge at all.
    {:ok, empty, _html} = open(Ecto.UUID.generate())
    refute has_element?(empty, ".lab-load-earlier")
  end

  defp open(id) do
    build_conn() |> Map.put(:host, "localhost") |> live("/conversations/#{id}")
  end

  defp load_older(view, id, before \\ :current) do
    before = if before == :current, do: history(view).before, else: before
    render_hook(view, "load-older", %{"conversation" => id, "before" => before})
    reply(view)
  end

  # The hook reply is what the browser hook acts on; the rendered HTML is
  # what render_hook returns, so the reply is read from the proxy mailbox.
  defp reply(view) do
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, payload}} -> payload
    after
      1_000 -> flunk("the load-older event produced no reply")
    end
  end

  defp history(view) do
    [node] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#lab-history")
      |> Enum.to_list()

    attributes = node |> LazyHTML.attributes() |> List.first() |> Map.new()

    %{
      before: attributes["data-before"],
      exhausted: attributes["data-history-state"] == "exhausted",
      state: attributes["data-history-state"]
    }
  end

  # Message bodies in DOM order, exactly as the test client holds the stream.
  defp transcript(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#lab-messages article .chat-message-text")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp conversation!(count, prefix \\ "Message") do
    id = Ecto.UUID.generate()
    for index <- 1..count, do: send!(id, "#{prefix} #{index}", index)
    id
  end

  defp send!(id, text, index) do
    {:ok, %{entry: entry}} =
      ConversationLab.send_message(id, text, profile(),
        id_generator: fn -> Ecto.UUID.generate() end,
        now: fn -> DateTime.add(@epoch, index, :second) end
      )

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [inserted_at: DateTime.add(@epoch, index, :second)]
    )

    {:ok, %{entry: entry}}
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-history-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    profile
  end
end
