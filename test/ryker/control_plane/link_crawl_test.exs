defmodule Ryker.ControlPlane.LinkCrawlTest do
  @moduledoc """
  Every internal link the workspace renders opens.

  On 2026-09-13 a crawl of the running release found three "Not found" pages
  behind links the Failures page itself rendered: the router's allowlist of
  failure kinds had never learned about publications. Reading the code did
  not find it; following the links did. This test follows every `href` and
  GET form action from the shell's pages against the deterministic fixture,
  so a page that offers a destination the routes refuse fails here first.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, InstructionSettings, ModelRequests, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.ControlPlaneOptions
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  @endpoint Endpoint

  # The pages the route map serves directly; everything else is discovered.
  @seeds ~w(/ /activity /conversations /incident-rooms /schedules /follow-ups /environments
            /channels /repositories /failures /working-copies /memory /memory/learned /memory/findings
            /memory/learning /rules
            /instructions /usage /setup /integrations /integrations/slack /integrations/github
            /integrations/emisar /integrations/webhooks /settings/models /settings/retention
            /settings/prices /settings/advanced)

  @live_routes [
    ~r{^/$},
    ~r{^/(conversations|activity|incident-rooms|schedules|follow-ups|environments|channels|repositories|failures|working-copies|memory|rules|instructions|usage|setup|integrations)$},
    ~r{^/memory/(learned|findings|learning)$},
    ~r{^/integrations/(slack|github|emisar|webhooks)$},
    ~r{^/settings/(models|retention|prices|advanced)$},
    ~r{^/conversations/[^/]+$},
    ~r{^/timeline/[^/]+$},
    ~r{^/incident-rooms/[^/]+$},
    ~r{^/schedules/[^/]+$},
    ~r{^/channels/[^/]+/[^/]+$},
    ~r{^/failures/[^/]+/[^/]+$}
  ]

  setup do
    fixture = ControlPlaneOptions.options(self())

    # The fixture's pages link stand-in episode refs ("episode:one") that no
    # database holds, and its conversation doubles describe a transcript the
    # live page cannot page. One real admitted episode stands behind every
    # episode link, and the real projections read an empty transcript.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    # One environment behind the Environments page, so its rows and the
    # editor each row's name opens are crawled too.
    {:ok, settings} = Ryker.Settings.initialize("control-plane:local")

    {:ok, _settings} =
      Ryker.Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: [], is_default: true},
        settings.installation.revision,
        "control-plane:local"
      )

    projection =
      Projection.callbacks()
      |> Map.merge(Map.drop(fixture.projection, [:lab_conversation, :lab_index, :lab_artifact]))
      |> Map.merge(%{
        episode: fn _ref, params -> Projection.episode(episode.key, params) end,
        model_timeline: fn _ref, params -> ModelRequests.timeline(episode.key, params) end
      })

    # With settings in place the settings pages render their editors, which
    # read the real settings commands; the fixture's doubles still answer
    # every record action the crawl could reach.
    options = %{
      fixture
      | projection: projection,
        actions:
          Actions.callbacks()
          |> Map.merge(fixture.actions)
          |> Map.put(:save_instructions, &InstructionSettings.save/3)
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

    :ok
  end

  test "every internal link and GET form on every page opens" do
    {visited, dead} = crawl(@seeds, MapSet.new(), [])

    assert dead == [],
           "#{length(dead)} of #{MapSet.size(visited)} links do not open:\n" <>
             Enum.map_join(dead, "\n", fn {href, from, reason} ->
               "  #{href} (from #{from}): #{reason}"
             end)

    # The crawl reached the record views, not only the indexes it started from.
    for prefix <- [
          "/incident-rooms/",
          "/schedules/",
          "/channels/",
          "/failures/",
          "/actions/",
          "/environments?edit="
        ] do
      assert Enum.any?(visited, &String.starts_with?(&1, prefix)),
             "nothing crawled under #{prefix}"
    end
  end

  defp crawl([], visited, dead), do: {visited, Enum.reverse(dead)}

  defp crawl([{href, from} | queue], visited, dead) do
    if MapSet.member?(visited, href) do
      crawl(queue, visited, dead)
    else
      visited = MapSet.put(visited, href)

      case open(href) do
        {:ok, links} ->
          crawl(queue ++ Enum.map(links, &{&1, href}), visited, dead)

        {:error, reason} ->
          crawl(queue, visited, [{href, from, reason} | dead])
      end
    end
  end

  defp crawl(seeds, visited, dead) when is_list(seeds),
    do: crawl(Enum.map(seeds, &{&1, "seed"}), visited, dead)

  defp open(href) do
    path = href |> String.split("#", parts: 2) |> hd() |> String.split("?", parts: 2) |> hd()

    if Enum.any?(@live_routes, &Regex.match?(&1, path)),
      do: open_live(href),
      else: open_http(href)
  end

  defp open_live(href) do
    case live(build_conn() |> Map.put(:host, "localhost"), href) do
      {:ok, _view, html} ->
        document = LazyHTML.from_document(html)

        title = LazyHTML.query(document, "title") |> LazyHTML.text()

        cond do
          title =~ "Not found" -> {:error, "not found"}
          html =~ "This view is temporarily unavailable" -> {:error, "unavailable"}
          html =~ "This record is unavailable" -> {:error, "unavailable"}
          true -> {:ok, links(document)}
        end

      {:error, {:live_redirect, %{to: to}}} ->
        {:ok, [to]}

      {:error, {:redirect, %{to: to}}} ->
        {:ok, [to]}

      other ->
        {:error, inspect(other)}
    end
  end

  defp open_http(href) do
    conn = get(build_conn() |> Map.put(:host, "localhost"), href)

    case conn.status do
      200 -> {:ok, conn.resp_body |> LazyHTML.from_document() |> links()}
      302 -> {:ok, Plug.Conn.get_resp_header(conn, "location")}
      status -> {:error, "answered #{status}"}
    end
  end

  # Internal destinations only: page links, GET confirmation forms and the
  # pager/filter links, minus the packaged assets and the mailto/external ones.
  defp links(document) do
    hrefs = LazyHTML.query(document, "a[href]") |> LazyHTML.attribute("href")

    actions =
      LazyHTML.query(document, "form[method='get'][action], form[method='GET'][action]")
      |> LazyHTML.attribute("action")

    (hrefs ++ actions)
    |> Enum.filter(&String.starts_with?(&1, "/"))
    |> Enum.reject(&String.starts_with?(&1, "/assets/"))
    |> Enum.map(&(&1 |> String.split("#", parts: 2) |> hd()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
