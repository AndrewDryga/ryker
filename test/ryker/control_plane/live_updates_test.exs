defmodule Ryker.ControlPlane.LiveUpdatesTest do
  @moduledoc """
  How open pages learn that what they show changed.

  Until 2026-09-26 a PostgreSQL trigger on 93 tables sent each table's name to
  one listener, a hand-kept map guessed which pages that table might reach,
  and every open page re-read everything it showed every five seconds anyway.
  The map drifted from the pages twice in September (Working copies, Settings,
  Setup and Chat each waited for the five-second poll after a rename), and
  the poll hid it. Now each page declares the topics it listens to, each
  context announces its own changes on them after they commit, and nothing
  re-reads a page on a timer, so a page that listens to the wrong thing stays
  visibly stale instead of quietly catching up.
  """
  use Ryker.DataCase, async: false

  alias Ryker.ControlPlane.{WebRouter, WorkbenchLive}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  @root Path.expand("../../..", __DIR__)

  # Announced on a topic no page needs, because what a page shows of it is
  # also announced on a topic pages do listen to.
  @not_for_pages %{
    # Routing progress is announced on the message's own topics.
    routing_updated: "Ryker.Ingress.Inbox",
    # A review is announced on the reviewed request's topics.
    episode_reviewed: "Ryker.Episodes"
  }

  test "every page listens to topics its contexts let it join and leave" do
    command = EpisodeFixtures.admit_input()
    assert {:ok, %{episode: episode}} = Episodes.apply(command)

    # A request's page and its failure's are addressed by the request's id.
    params = %{
      "channel" => "C456",
      "id" => episode.id,
      "item" => "item-one",
      "kind" => "work",
      "ref" => "ryker",
      "slug" => "one",
      "workspace" => "T123"
    }

    for path <- live_paths() do
      concrete = String.replace(path, ~r/:([a-z]+)/, fn ":" <> name -> params[name] end)
      subscriptions = WorkbenchLive.page_subscriptions(concrete, params, Ecto.UUID.generate())
      assert subscriptions != [], "#{path} listens to nothing, so it would never redraw"

      for {module, function, arguments} = subscription <- subscriptions do
        Code.ensure_loaded!(module)
        leave = String.to_atom("un" <> Atom.to_string(function))

        assert function_exported?(module, function, length(arguments)),
               "#{path}: #{inspect(subscription)} is not a subscription"

        assert function_exported?(module, leave, length(arguments)),
               "#{path}: #{inspect(subscription)} has no #{leave} to leave it"

        assert :ok = apply(module, function, arguments)
        assert :ok = apply(module, leave, arguments)
      end
    end
  end

  # A page ignores what it does not recognise, so an event missing here is a
  # page that never redraws for it, and an event here that nothing announces
  # is a name that drifted.
  test "every change a context announces redraws the pages listening for it" do
    announced = announced_events()
    heard = MapSet.new(WorkbenchLive.page_events())
    not_for_pages = @not_for_pages |> Map.keys() |> MapSet.new()

    assert MapSet.difference(announced, MapSet.union(heard, not_for_pages)) == MapSet.new()
    assert MapSet.difference(heard, announced) == MapSet.new()
    assert MapSet.intersection(heard, not_for_pages) == MapSet.new()
  end

  test "nothing re-reads an open page on a timer" do
    source = File.read!(Path.join(@root, "lib/ryker/control_plane/workbench_live.ex"))

    refute source =~ ":reconcile"

    scheduled =
      ~r/Process\.send_after\(self\(\),\s*([^,]+),/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    assert scheduled == [":reload_page"]
  end

  defp live_paths do
    WebRouter.__routes__()
    |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
    |> Enum.map(& &1.path)
  end

  # The first element of every tuple a context hands to Ryker.PubSub.
  defp announced_events do
    Path.wildcard(Path.join(@root, "lib/**/*.ex"))
    |> Enum.map(&File.read!/1)
    |> Enum.filter(&(&1 =~ "Ryker.PubSub.broadcast("))
    |> Enum.flat_map(fn source ->
      broadcasts =
        ~r/Ryker\.PubSub\.broadcast\([^\n]*(?:\n[^\n]*){0,2}/
        |> Regex.scan(source)
        |> List.flatten()

      messages = ~r/message = \{:[a-z_]+/ |> Regex.scan(source) |> List.flatten()

      (broadcasts ++ messages)
      |> Enum.flat_map(&Regex.scan(~r/\{:([a-z_]+)/, &1, capture: :all_but_first))
      |> List.flatten()
    end)
    |> MapSet.new(&String.to_atom/1)
  end
end
