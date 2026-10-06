defmodule Ryker.ControlPlane.RealtimePagesTest do
  @moduledoc """
  A change shows on a page that is already open, without a reload, because
  the context that made it announced it; and a page that hears nothing reads
  nothing.

  Until 2026-09-26 an open page learned of changes from a PostgreSQL trigger
  whose table-to-page map drifted from the pages, and hid the drift behind a
  five-second poll of every open page: Working copies, Settings, Setup and
  Chat each sat on stale data until the poll came round, and every open tab
  re-read everything it showed five times a minute whether or not anything
  had changed. Each test here makes a change the way production does, through
  the owning context, while the page is open, and waits well under that five
  seconds for the page to show it.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ryker.TestHelpers, only: [eventually: 2]

  alias Ryker.ControlPlane.{Actions, ConversationLab, Endpoint, Projection}
  alias Ryker.Delivery.PlatformActionCustody
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Fixtures.TaskOffer
  alias Ryker.Ingress.WorkProfile
  alias Ryker.{Memories, Records, Settings}
  alias Ryker.Slack.{ChannelConfigurations, IncidentRoom, IncidentRoomChangeset, IncidentRooms}
  alias Ryker.Work.Custody

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    observer = self()
    profile = profile!()

    # Activity reports each read, so a test can tell a page that listens from
    # a page that polls.
    projection =
      Map.update!(Projection.callbacks(), :activity, fn read ->
        fn params ->
          send(observer, :activity_read)
          read.(params)
        end
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "realtime-pages-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(%{environments: %{}, fallback_work_profile: profile}),
         csrf_secret: String.duplicate("s", 32),
         observability: %{},
         projection: projection
       }}
    )

    %{profile: profile}
  end

  test "a message that arrives shows on an open Activity page, which reads nothing meanwhile",
       %{profile: profile} do
    {:ok, view, _html} = open("/")
    drain(:activity_read)

    # Nothing changed, so nothing is read again: there is no poll to wait for.
    refute_receive :activity_read, 300

    assert {:ok, _receipt} =
             ConversationLab.send_message(
               Ecto.UUID.generate(),
               "Why did checkout fail?",
               profile
             )

    # A new row waits behind one button rather than moving the rows being read.
    assert shows?(fn -> has_element?(view, "button.new-activity", "1 new") end)
    view |> element("button.new-activity") |> render_click()
    assert render(view) =~ "Why did checkout fail?"
  end

  test "a running request's Timeline shows what the run records while it is open" do
    source = SavedEntities.source!("slack:T123:C456")
    {:ok, view, _html} = open("/timeline/" <> source.episode.id)
    refute render(view) =~ "Readiness probes fail after each deploy"

    assert {:ok, _record} =
             Records.create(Records.token(source.turn), "progress-realtime", "progress", %{
               "next_due_at" => nil,
               "phase" => "investigating",
               "summary" => "Readiness probes fail after each deploy."
             })

    assert shows?(fn -> render(view) =~ "Readiness probes fail after each deploy" end)
  end

  test "a message sent to a conversation from another tab shows in the open conversation",
       %{profile: profile} do
    id = Ecto.UUID.generate()
    {:ok, view, _html} = open("/conversations/#{id}")
    refute has_element?(view, "#lab-messages .chat-message-text")

    assert {:ok, _receipt} = ConversationLab.send_message(id, "Is checkout healthy?", profile)

    assert shows?(fn ->
             has_element?(view, "#lab-messages .chat-message-text", "Is checkout healthy?")
           end)
  end

  test "a reply Slack refuses for good shows on an open Failures page" do
    claim = work_claim!("failures")
    {:ok, view, _html} = open("/failures")
    assert has_element?(view, ".kit-empty-title", "Nothing needs you")

    assert {:ok, %{action: action}} =
             PlatformActionCustody.enqueue_in_turn(claim, %{
               conversation_ref: "slack:T123:C123",
               document: %{"action" => "add", "emoji_name" => "eyes"},
               kind: :reaction,
               source_item_ref: "1787832000.000100",
               thread_ref: "1787832000.000100",
               tool: :set_slack_reaction,
               transport: "slack"
             })

    assert {:ok, %{lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert {:ok, _blocked} =
             PlatformActionCustody.block(
               action.action_ref,
               lease_ref,
               "slack_api_error",
               ~s|{:slack_api_error, "channel_not_found"}|
             )

    assert shows?(fn ->
             not has_element?(view, ".kit-empty-title", "Nothing needs you") and
               has_element?(view, ".failures-page .entity-row")
           end)
  end

  test "a working copy a task starts shows on an open Working copies page" do
    {:ok, view, _html} = open("/working-copies")
    assert has_element?(view, ".kit-empty-title", "No working copies right now")

    episode = episode!("working-copy")
    assert {:ok, _session} = Custody.pin_episode(episode.id, "policy:realtime", digest(), "ryker")

    assert shows?(fn ->
             not has_element?(view, ".kit-empty-title", "No working copies right now")
           end)
  end

  test "a room a person rearms goes back to setting up on the open Incident rooms list" do
    room = blocked_room!()
    {:ok, view, _html} = open("/incident-rooms")
    assert has_element?(view, ".entity-side .state-word", "Needs attention")

    assert {:ok, _rearmed} = IncidentRooms.rearm(room.ref)

    assert shows?(fn ->
             has_element?(view, ".entity-side .state-word", "Setting up") and
               not has_element?(view, ".entity-side .state-word", "Needs attention")
           end)
  end

  test "a channel Ryker joins shows on the open Channels list" do
    {:ok, view, _html} = open("/channels?show=all")
    refute has_element?(view, "#channel-T123-C987")

    assert {:ok, %{status: :joined}} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: "U123",
                 channel_ref: "C987",
                 event_ref: "event:join-realtime",
                 kind: :joined,
                 occurred_at: DateTime.utc_now(),
                 workspace_ref: "T123"
               },
               %{default_environment: nil, environments: []}
             )

    assert shows?(fn -> has_element?(view, "#channel-T123-C987") end)
  end

  test "a repository added in another tab shows on the open Repositories page" do
    assert {:ok, snapshot} = Settings.initialize(@actor)
    {:ok, view, _html} = open("/repositories")
    refute has_element?(view, "#repository-billing")

    assert {:ok, _saved} =
             Settings.put_repository(%{ref: "billing"}, snapshot.installation.revision, @actor)

    assert shows?(fn -> has_element?(view, "#repository-billing") end)
  end

  # Feedback is recorded by whatever saw it (a reaction, a message, routing,
  # a review) and announced once it commits; the open Feedback page and the
  # request's Timeline redraw from that, with no poll.
  #
  # A Chat request: until setup is done every page also hears Slack's
  # conversations, which would redraw this one for the wrong reason.
  test "feedback recorded while the Feedback page and the request are open shows on both" do
    id = Ecto.UUID.generate()
    conversation = "control-plane:lab:#{Ecto.UUID.generate()}"

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation,
            thread_ref: conversation,
            transport: "control_plane"
          },
          episode_id: id,
          episode_key: "realtime-feedback:#{id}",
          native_input_id: "realtime-feedback:#{id}",
          turn_ref: "turn:realtime-feedback:#{id}"
        })
      )

    {:ok, page, _html} = open("/feedback")
    assert has_element?(page, ".kit-empty-title", "No feedback yet")
    {:ok, timeline, _html} = open("/timeline/" <> episode.id)
    refute has_element?(timeline, "#feedback")

    assert {:ok, %{status: :recorded}} =
             Ryker.Feedback.record(%{
               kind: :sentiment,
               value: "frustrated",
               note: "They had to ask twice.",
               actor_ref: "control_plane:user:local-operator",
               source: "control_plane",
               source_ref: "realtime-feedback",
               occurred_at: DateTime.utc_now(),
               request: {:episode, episode.id}
             })

    assert shows?(fn ->
             has_element?(page, "#feedback-frustrated .entity-row", "They had to ask twice.")
           end)

    assert shows?(fn ->
             has_element?(timeline, "#feedback .feedback-card", "They had to ask twice.")
           end)
  end

  # A request people were unhappy with becomes a candidate in the
  # transaction that records the feedback; the open What to fix page hears
  # it, and hears a decision too, with no poll.
  test "a request people were unhappy with, and a decision on it, show on the open What to fix page" do
    id = Ecto.UUID.generate()
    conversation = "control-plane:lab:#{Ecto.UUID.generate()}"

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation,
            thread_ref: conversation,
            transport: "control_plane"
          },
          episode_id: id,
          episode_key: "realtime-improvement:#{id}",
          native_input_id: "realtime-improvement:#{id}",
          turn_ref: "turn:realtime-improvement:#{id}"
        })
      )

    {:ok, page, _html} = open("/feedback/fix")
    assert has_element?(page, ".kit-empty-title", "Nothing to decide")

    assert {:ok, %{status: :recorded}} =
             Ryker.Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "control_plane:user:local-operator",
               source: "control_plane",
               source_ref: "realtime-improvement",
               occurred_at: DateTime.utc_now(),
               request: {:episode, episode.id}
             })

    candidate = Ryker.Improvement.for_request({:episode, episode.id})
    assert shows?(fn -> has_element?(page, "#improvement-#{candidate.id}", "Waiting") end)

    assert {:ok, _dismissed} = Ryker.Improvement.dismiss(candidate.id, @actor)
    assert shows?(fn -> has_element?(page, ".kit-empty-title", "Nothing to decide") end)
  end

  test "a fact forgotten from Slack leaves the open Facts page" do
    source = SavedEntities.source!("slack:T123:C456")
    fact = SavedEntities.memory!(source, "checkout owner", "The payments team owns checkout.")
    {:ok, view, _html} = open("/memory")
    assert render(view) =~ "The payments team owns checkout."

    assert {:ok, _forgotten} = Memories.forget(fact.ref)

    assert shows?(fn -> not (render(view) =~ "The payments team owns checkout.") end)
  end

  test "settings the running system applies stop reading as pending on the open Advanced page" do
    assert {:ok, snapshot} = Settings.initialize(@actor)
    {:ok, view, _html} = open("/settings/advanced")
    assert has_element?(view, ".page-feedback", "Applying the saved settings")

    assert :ok = Settings.record_application(snapshot.installation.revision, :ok)

    assert shows?(fn ->
             not has_element?(view, ".page-feedback", "Applying the saved settings")
           end)
  end

  # Andrew, 2026-10-01, of the setup page while he connected Emisar: "emisar is connected but this
  # card doesn't show it … it took a while for them to activate themselves". The open page follows
  # a connection made elsewhere; what made it late on mac-server was the console restarting
  # under it (OwnerTest, "a change the console can take in place …").
  test "an Emisar account connected elsewhere shows on the open setup page" do
    assert {:ok, _snapshot} = Settings.initialize(@actor)
    {:ok, view, _html} = open("/setup")
    refute has_element?(view, "#setup-emisar[data-state=done]")

    assert {:ok, _connected} =
             Ryker.IntegrationSetup.connect_emisar(%{
               "rpc_url" => "https://emisar.example/api/mcp/rpc",
               "token" => "emisar-token-that-is-long-enough"
             })

    assert shows?(fn -> has_element?(view, "#setup-emisar[data-state=done]", "Emisar") end)
    assert has_element?(view, ".setup-meter > span[data-optional=true][data-done=true]")
  end

  # Andrew, 2026-09-27, on Integrations › Emisar: "blue thing on top of this
  # page appears and disappears in cycles". Repository setup saves a settings
  # revision per step, twice a second while it ran, and every settings page
  # announced each one as "Applying the saved settings…" until the runtime
  # caught up, so the notice blinked for as long as setup ran.
  test "setup recording its progress never reads as a save being applied" do
    assert {:ok, snapshot} = Settings.initialize(@actor)
    assert :ok = Settings.record_application(snapshot.installation.revision, :ok)
    {:ok, view, _html} = open("/integrations/emisar")
    refute has_element?(view, ".page-feedback", "Applying the saved settings")

    assert {:ok, _saved} =
             Settings.put_repository(
               %{ref: "billing"},
               snapshot.installation.revision,
               "github:onboarding"
             )

    # The open page redraws on the announcement within a few hundred
    # milliseconds; the notice must not come with it.
    refute eventually(
             fn -> has_element?(view, ".page-feedback", "Applying the saved settings") end,
             1_000
           )
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  # Well inside the five seconds the old poll took, so a page that caught up
  # only on a timer fails here, and wide enough for a loaded host's reload.
  defp shows?(check), do: eventually(check, 3_000)

  defp drain(message) do
    receive do
      ^message -> drain(message)
    after
      100 -> :ok
    end
  end

  defp profile! do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "realtime-pages-test",
        policy_digest: digest(),
        repository_ref: nil
      })

    profile
  end

  defp episode!(suffix) do
    id = Ecto.UUID.generate()

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "realtime:#{suffix}:#{id}",
                 native_input_id: "source:realtime:#{suffix}:#{id}",
                 turn_ref: "turn:realtime:#{suffix}:#{id}"
               })
             )

    episode
  end

  defp work_claim!(suffix) do
    episode = episode!(suffix)
    assert {:ok, _session} = Custody.pin_episode(episode.id, "policy:realtime", digest())
    assert {:ok, claim} = Custody.claim_next("worker:realtime:#{suffix}", 60)
    claim
  end

  # A room whose setup stopped before its channel existed, as the worker leaves
  # it after its attempts.
  defp blocked_room! do
    source = SavedEntities.source!("slack:T123:C456")

    assert {:ok, offer} =
             Records.create(
               Records.token(source.turn),
               "incident-offer",
               "task_offer",
               TaskOffer.payload(%{
                 "kind" => "incident",
                 "prompt" => "Investigate checkout errors.",
                 "repository" => nil,
                 "title" => "Checkout errors"
               })
             )

    room =
      %{
        attempt_count: 3,
        bot_user_ref: "U0RYKERBOT",
        channel_name: "inc-checkout-errors",
        confirmation_ref: "incident-confirmation:realtime",
        id: Ecto.UUID.generate(),
        invite_user_group_refs: [],
        invite_user_refs: ["U123"],
        last_error_code: "slack_api_error",
        last_error_detail: ~s|{:slack_api_error, "name_taken"}|,
        policy: "ryker-incident",
        policy_digest: digest(),
        private: false,
        prompt: "Investigate checkout errors.",
        record_id: offer.id,
        ref: "incident-room:realtime",
        repository_ref: "acme/checkout-api",
        requested_at: DateTime.utc_now(),
        requested_by_actor_ref: "U123",
        source_channel_ref: "C456",
        source_episode_id: source.episode.id,
        source_message_ref: "1790001200.000100",
        status: :blocked,
        title: "Checkout errors",
        topic: "Checkout errors · investigating",
        workspace_ref: "T123"
      }
      |> IncidentRoomChangeset.insert()
      |> Repo.insert!()

    Repo.get!(IncidentRoom, room.id)
  end

  defp digest, do: String.duplicate("a", 64)
end
