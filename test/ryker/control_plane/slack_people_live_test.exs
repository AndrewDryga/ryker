defmodule Ryker.ControlPlane.SlackPeopleLiveTest do
  @moduledoc """
  How a Slack person reads in the control plane: their name, linked to their
  Slack profile, never a raw ID, and the name arrives without a reload.

  On 2026-09-26, right after Andrew chose himself on Integrations › Slack,
  "Who can manage Ryker" read "Slack user U0BHTNFCW6S"; only a later reload
  read "@Andrew". The page asked the name cache while it was drawn, the cache
  had not asked Slack yet, and nothing drew the page again once it had.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ryker.TestHelpers, only: [eventually: 1]

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Credentials
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Settings
  alias Ryker.Slack.{Input, Names}
  alias Ryker.Work.{Custody, Submission}

  @endpoint Endpoint
  @actor "control-plane:local"
  @workspace "T0123456789"
  @andrew "U0BHTNFCW6S"
  @profile "https://acme.slack.com/team/U0BHTNFCW6S"
  @managers "section[aria-label='Who can manage Ryker']"
  @chosen "#{@managers} #slack-managers"
  @switch "#{@managers} input[type=checkbox][name=workspace_admins_manage]"

  setup do
    people = start_supervised!({Agent, fn -> %{people: [], hold: false, calls: 0} end})

    start_supervised!({Endpoint,
     server: false,
     secret_key_base: String.duplicate("s", 64),
     pubsub_server: Ryker.PubSub.Server,
     live_view: [signing_salt: "slack-people-test"],
     check_origin: ["//localhost:4321"],
     url: [host: "localhost", port: 4321],
     control_plane: %{
       actions: Actions.callbacks(),
       projection: Projection.callbacks(),
       observability: %{},
       csrf_secret: String.duplicate("s", 32),
       # Who Slack lists as the workspace's people, instead of asking Slack.
       slack_members: fn -> list_people(people) end
     }})

    {:ok, _snapshot} = Settings.initialize(@actor)
    %{people: people}
  end

  test "who can manage Ryker names each person, linked to Slack, and the name arrives without a reload" do
    names!(%{@andrew => "Andrew"})
    slack_on!([@andrew])

    {:ok, view, _html} = open("/integrations/slack")

    # Before Slack has answered: a person, linked, never the raw ID.
    assert has_element?(view, "#{@managers} a[href='#{@profile}']", "Slack user")
    refute managers_text(view) =~ @andrew

    # Slack answers in the background, one name at a time, and the open page
    # shows the name.
    assert eventually(fn ->
             :ok = GenServer.call(Names, :refresh)
             has_element?(view, "#{@managers} a[href='#{@profile}']", "@Andrew")
           end)

    refute managers_text(view) =~ @andrew
  end

  # Andrew, 2026-09-26: under "Who can manage Ryker" the chosen person read
  # like the heading of the admins checkbox below it, and admins were said
  # twice, as a list row and as the checkbox. Each group is said once now:
  # the people under their own label, the admins as the switch.
  test "who can manage Ryker says each group once: chosen people by name, admins as the switch" do
    names!(%{@andrew => "Andrew"})
    slack_on!([@andrew])
    Names.name(@workspace, @andrew)
    :ok = GenServer.call(Names, :refresh)

    {:ok, view, _html} = open("/integrations/slack")

    assert has_element?(view, "#{@chosen} dt", "Chosen people")
    assert has_element?(view, "#{@chosen} dd a[href='#{@profile}']", "@Andrew")
    assert has_element?(view, "#{@switch}[checked]")
    refute has_element?(view, "#{@managers} [role=listitem]")
    assert managers_text(view) |> String.split("Workspace admins and owners") |> length() == 2
  end

  test "the switch turns off workspace admins and owners, and the chosen people stay" do
    names!(%{@andrew => "Andrew"})
    slack_on!([@andrew])
    Names.name(@workspace, @andrew)
    :ok = GenServer.call(Names, :refresh)

    {:ok, view, _html} = open("/integrations/slack")

    # One switch, saved as it changes (Andrew, 2026-09-27).
    view
    |> form("#{@managers} form#settings-slack-admins-form", %{
      "workspace_admins_manage" => "false"
    })
    |> render_change()

    refute Settings.fetch!().slack.workspace_admins_manage
    assert eventually(fn -> not has_element?(view, "#{@switch}[checked]") end)
    assert has_element?(view, "#{@chosen} dd a[href='#{@profile}']", "@Andrew")
  end

  # Andrew, 2026-10-01, setting up the tenant workspace: "layout broken and not all people shown
  # here, need paging and a search too? some orgs have hundreds of people". Choose people drew
  # every member at once, with the admins switch under its Save and Cancel, and had no way to
  # find one person among hundreds.
  test "choosing who can manage Ryker finds anyone in a large workspace and keeps the choice",
       %{people: listed} do
    names!(%{})
    slack_on!([])

    people =
      [%{id: "U0ADA", name: "Ada Lovelace"}] ++
        for n <- 1..120,
            do: %{
              id: "U0#{1000 + n}",
              name: "Person #{n |> to_string() |> String.pad_leading(3, "0")}"
            }

    Agent.update(listed, &%{&1 | people: people})
    {:ok, view, _html} = open("/integrations/slack")
    view |> element("#{@managers} button", "Choose people") |> render_click()
    render_async(view)

    # The switch saves as it changes, so it comes first; the people follow with their own Save.
    html = view |> element(@managers) |> render()

    assert position(html, ~s(name="workspace_admins_manage")) <
             position(html, ~s(id="slack-people"))

    assert has_element?(view, "#slack-people label", "Search 121 people")
    assert length(rows(view)) == 50
    assert has_element?(view, "#slack-people button", "Show 50 more")

    # A search finds anyone, and a choice outlives the search that found it.
    view |> form("#slack-people", %{"query" => "ada"}) |> render_change()
    assert rows(view) == ["Ada Lovelace"]

    view
    |> form("#slack-people", %{"query" => "ada", "operators" => ["U0ADA"]})
    |> render_change()

    view |> form("#slack-people", %{"query" => ""}) |> render_change()
    assert has_element?(view, "#slack-people input[value=U0ADA][checked]")
    assert has_element?(view, "#slack-people", "1 chosen: Ada Lovelace")

    view |> element("#slack-people button", "Show 50 more") |> render_click()
    assert length(rows(view)) == 100

    view |> form("#slack-people") |> render_submit()
    assert Settings.fetch!().slack.operators == ["U0ADA"]
  end

  # Andrew, 2026-10-01, of Choose people on the blitz workspace: "I wait for ages without any
  # progress indication, loader or button not even blocked making me click it 5 times". Reading
  # every page of a large workspace takes a while; the page says so, and more clicks start nothing.
  test "choosing people says it is loading and starts one load however often it is clicked",
       %{people: listed} do
    names!(%{})
    slack_on!([])
    Agent.update(listed, &%{&1 | people: [%{id: "U0ADA", name: "Ada Lovelace"}], hold: true})
    {:ok, view, _html} = open("/integrations/slack")

    view |> element("#{@managers} button", "Choose people") |> render_click()
    assert has_element?(view, @managers, "Loading people from Slack")
    assert has_element?(view, "#{@managers} button[disabled]", "Loading people")
    render_click(view, "load-slack-members", %{})

    Agent.update(listed, &%{&1 | hold: false})
    render_async(view)
    assert rows(view) == ["Ada Lovelace"]
    assert Agent.get(listed, & &1.calls) == 1
  end

  test "with nobody chosen, workspace admins and owners are who can manage Ryker" do
    names!(%{})
    slack_on!([])

    {:ok, view, _html} = open("/integrations/slack")

    assert has_element?(view, "#{@switch}[checked]")
    refute has_element?(view, @chosen)
    refute managers_text(view) =~ "Nobody can manage Ryker yet"
  end

  # A message that mentioned someone Slack had not named yet kept reading
  # "Slack user" on its Timeline card until a reload, though the name arrived
  # seconds later: the card was drawn from data that had not changed.
  test "a person mentioned in a Timeline message is named once Slack says, without a reload" do
    names!(%{"U0SENDER1" => "Sam", @andrew => "Andrew"})
    Names.name(@workspace, "U0SENDER1")
    :ok = GenServer.call(Names, :refresh)
    entry = slack_message!("U0SENDER1", "Can <@#{@andrew}> look at the deploy?")

    {:ok, view, _html} = open("/timeline/ingress-input%3A#{entry.id}")
    body = "#story-message-#{entry.id} .ui-message-body"

    assert has_element?(view, "#{body} a[href='#{@profile}']", "Slack user")

    assert eventually(fn ->
             :ok = GenServer.call(Names, :refresh)
             has_element?(view, "#{body} a[href='#{@profile}']", "@Andrew")
           end)
  end

  # The briefing a request was sent is drawn from the retained request, which
  # never changes, so a sender Slack named after the page opened stayed
  # "Slack user" in it until a reload.
  test "a sender in a request's briefing is named once Slack says, without a reload" do
    names!(%{@andrew => "Andrew"})
    episode = work_request!(@andrew, "Is the deploy healthy?")

    {:ok, view, _html} = open("/timeline/" <> URI.encode_www_form(episode.key))
    sender = ".prompt-assembly .ui-message-header a[href='#{@profile}']"

    assert has_element?(view, sender, "Slack user")

    assert eventually(fn ->
             :ok = GenServer.call(Names, :refresh)
             has_element?(view, sender, "@Andrew")
           end)
  end

  # The name cache is handed the workspace, its address and a lookup; here the
  # lookup is the directory a test names.
  defp names!(directory) do
    start_supervised!(
      {Names,
       workspace: @workspace,
       workspace_url: "https://acme.slack.com",
       fetch: fn ref -> {:ok, Map.get(directory, ref)} end}
    )
  end

  defp slack_on!(operators) do
    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          workspace_url: "https://acme.slack.com",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker",
          operators: operators
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end
  end

  # One Slack message, received and routed to a reply, the way the Timeline
  # shows a request.
  defp slack_message!(sender, text) do
    now = ~U[2026-09-26 12:00:00.000000Z]

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: sender},
        channel_ref: "C0123456789",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-people-#{Ecto.UUID.generate()}",
        message_ref: "1788562304.000100",
        occurred_at: now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: @workspace
      })

    {:ok, %{entry: entry}} = Inbox.record(input, [])

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:#{sender}",
          destination: %{
            conversation_ref: "slack:#{@workspace}:C0123456789",
            thread_ref: "1788562304.000100",
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: now,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "reason" => "A direct reply.",
      "repository_source" => nil,
      "work_class" => "conversational"
    }

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        inserted_at: now,
        status: :decided
      ]
    )

    entry
  end

  # A Work request whose briefing holds one Slack message from this person.
  defp work_request!(sender, text) do
    episode_id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "people:#{episode_id}",
          native_input_id: "source:people:#{episode_id}",
          turn_ref: "turn:people:#{episode_id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(episode_id, "people", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("people:#{episode_id}", 120, :work)

    context = %{
      "mode" => "full",
      "inputs" => %{
        "items" => [
          %{
            "current" => true,
            "source" => %{"kind" => "slack", "ref" => @workspace},
            "actor" => %{"kind" => "user", "ref" => sender},
            "content" => %{"text" => text}
          }
        ],
        "omitted_count" => 0
      },
      "records" => []
    }

    {:ok, submission} =
      Submission.new(
        %{"work" => context},
        Jason.encode!(%{"instructions" => "Investigate", "work" => context}),
        %{"type" => "object"},
        "work-final-live-v3"
      )

    {:ok, _turn} =
      Custody.freeze_submission(episode_id, claim.turn.turn_ref, claim.lease_ref, submission)

    claim.episode
  end

  # Who Slack lists, counted, and held back while a test looks at the page in between.
  defp list_people(agent) do
    Agent.update(agent, &Map.update!(&1, :calls, fn calls -> calls + 1 end))
    held(agent, 500)
    {:ok, Agent.get(agent, & &1.people)}
  end

  defp held(_agent, 0), do: :ok

  defp held(agent, tries) do
    if Agent.get(agent, & &1.hold) do
      Process.sleep(10)
      held(agent, tries - 1)
    end
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#slack-people .settings-option strong")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp position(html, fragment) do
    case :binary.match(html, fragment) do
      {index, _length} -> index
      :nomatch -> flunk("#{fragment} is not in #{html}")
    end
  end

  defp managers_text(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(@managers)
    |> LazyHTML.text()
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)
end
