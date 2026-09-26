defmodule Ryker.ControlPlane.MessagePageTest do
  @moduledoc """
  The page of a message that started no work of its own: a greeting routing
  answered itself, a message it reacted to, one it left alone.

  On 2026-09-26 Andrew opened the page of "Hi @Ryker" in #test, which routing
  had answered with "Hi! How can I help?", beside the page of a request: "why
  this page is so different … last one is properly designed while other IDK
  what is that even?!" It was headed by the raw Slack text, "Hi
  <@U0C1LCVNF52>", opened on a "01 Getting ready" chapter of preparation cards,
  and had no summary, no message bubble and no answer where a reader looks
  first. Of another greeting routing answered in the same thread he asked:
  "not joined to an episode so each message looks separate, is that normal?"
  It is, but the page has to show the conversation the message is part of.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Delivery.{RoutingResponse, RoutingResponseCustody}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Settings
  alias Ryker.Slack.{Input, Names}

  @endpoint Endpoint
  @actor "control-plane:local"
  @workspace "T0123456789"
  @channel "C0TEST00001"
  @ryker "U0C1LCVNF52"
  @dana "U0DANA00001"
  @root "1788562304.000100"
  @sent ~U[2026-09-26 16:57:36.000000Z]

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub,
       live_view: [signing_salt: "message-page-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize(@actor)

    start_supervised!(
      {Names,
       workspace: @workspace,
       workspace_url: "https://acme.slack.com",
       fetch: fn _ref -> {:error, :not_asked} end}
    )

    :ok =
      Names.remember([
        {@workspace, @ryker, "Ryker"},
        {@workspace, @dana, "Dana"},
        {@workspace, @channel, "test"}
      ])

    :ok
  end

  # Andrew, 2026-09-26: the page of a greeting routing answered was headed
  # "Hi <@U0C1LCVNF52>" with a small chip, opened on "01 Getting ready", and
  # showed neither the message as it was sent nor the reply, while the request
  # page beside it led with its title, state, summary and the message itself.
  test "a message routing answered itself reads like a request: its words, the decision and the reply" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>", @sent)
    answered!(greeting, "Hi! How can I help?", DateTime.add(@sent, 27, :second))

    {:ok, view, _html} = open(greeting)
    page = view |> render() |> LazyHTML.from_document()

    # The header is the request page's: what the message says as people read
    # it, never the raw mention, then what happened to it and when.
    assert text(page, ".episode-page-intro h1") == "Hi @Ryker"
    refute text(page, ".episode-page-intro") =~ "<@"
    assert text(page, ".episode-page-intro .episode-initial-label") == "Message"
    assert text(page, ".episode-location .ui-status") == "Answered right away"

    # The summary strip says how long the answer took; nothing the message
    # never had, such as a conversation span, is shown as missing.
    assert text(page, ".episode-metrics .metric-response") =~ "27s"
    refute text(page, ".episode-metrics") =~ "Conversation span"

    # One message band: the message in the bubble the request page's Intake
    # uses, what routing decided, then what Ryker sent.
    band = LazyHTML.query(page, ".case-timeline .conversation-chapter")
    assert text(band, ".chapter-heading h3") == "Message"
    assert text(band, ".phase-ready .case-message .ui-message-body") == "Hi @Ryker"
    assert text(band, ".phase-routing .episode-request h3") == "Answered right away"

    assert text(band, ".phase-answer .ui-message[data-author=ryker] .ui-message-body") ==
             "Hi! How can I help?"

    # The preparation cards are still there, as request page cards, and not
    # under a chapter of their own.
    assert has_element?(view, ".case-entry .participation")
    assert has_element?(view, ".case-entry .input-queue")
    refute has_element?(view, "#standalone-getting-ready")
    refute has_element?(view, ".standalone-preparation")

    # The routing briefing named its parts "Ryker admission instructions" and
    # "Frozen admission context", Ryker's internal words (seen by Andrew on
    # this page, 2026-09-26).
    refute String.downcase(text(page, "main")) =~ "admission"
  end

  # Andrew, 2026-09-26, of a second greeting routing answered in the same
  # thread: "not joined to an episode so each message looks separate, is that
  # normal?" A message that starts no work has a page of its own; that page
  # shows the thread around it, and where a later message started work, the
  # link leads to that request.
  test "a message's page lists the rest of its thread, linking the request a later message started" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>", @sent)
    answered!(greeting, "Hi! How can I help?", DateTime.add(@sent, 27, :second))

    question =
      message!("1788562400.000200", @root, "Why is checkout returning 502s?", at(96))

    episode = starts_request!(question)

    follow_up =
      message!("1788562460.000300", @root, "Can you check payments too?", at(156))

    joins!(follow_up, episode)

    thanks = message!("1788562520.000400", @root, "thanks <@#{@ryker}>", at(216))
    answered!(thanks, "Anytime!", at(220))

    {:ok, view, _html} = open(greeting)

    thread = "section#in-this-thread"
    assert has_element?(view, "#{thread} h2", "In this thread")

    rows =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#{thread} [role=listitem]")
      |> Enum.map(fn row ->
        name = LazyHTML.query(row, ".entity-name > a, .entity-name > span:not(.entity-tag)")

        {name |> LazyHTML.text() |> squish(),
         row |> LazyHTML.query(".entity-name > a") |> LazyHTML.attribute("href") |> List.first(),
         row |> LazyHTML.query(".entity-tag") |> LazyHTML.text() |> squish(),
         row |> LazyHTML.query(".state-word") |> LazyHTML.text() |> squish(),
         row |> LazyHTML.query(".entity-meta") |> LazyHTML.text() |> squish()}
      end)

    request = "/timeline/" <> URI.encode_www_form(episode.key)

    assert [
             {"Hi @Ryker", nil, "This message", "Answered right away", _},
             {"Why is checkout returning 502s?", ^request, "", _started_state, started},
             {"Can you check payments too?", ^request, "", _joined_state, joined},
             {"thanks @Ryker", thanks_page, "", "Answered right away", _}
           ] = rows

    assert started =~ "Started a request"
    assert joined =~ "Added to a request"
    assert thanks_page == "/timeline/" <> URI.encode_www_form("ingress-input:#{thanks.id}")
  end

  # The old page ended at the routing card for a message routing left alone,
  # and showed a reaction only as a line of text: the reader had to know that
  # "No reply needed" meant nothing was sent. The Answer stage says it.
  test "a message routing left alone says Ryker stayed quiet and why, and a reaction shows as sent" do
    quiet = message!(@root, nil, "deploy finished", @sent)

    decide!(
      quiet,
      :ignore,
      %{"action" => "ignore", "reason" => "A status note for the team; nobody asked Ryker."},
      nil
    )

    {:ok, view, _html} = open(quiet)
    assert has_element?(view, ".episode-location .ui-status", "No response needed")
    assert has_element?(view, ".phase-answer .case-entry", "Ryker stayed quiet")
    assert has_element?(view, ".phase-answer .case-entry", "nobody asked Ryker")
    refute has_element?(view, ".episode-metrics .metric-response")

    reacted = message!("1788562400.000200", nil, "shipped it", at(60))
    decision = %{"action" => "react", "reaction" => %{"emoji_name" => "eyes"}}
    decide!(reacted, :react, decision, nil)

    {:ok, {:ok, response}} =
      Repo.transaction(fn ->
        RoutingResponseCustody.enqueue_in_transaction(Repo.get!(Entry, reacted.id))
      end)

    delivered!(response, at(62))

    {:ok, view, _html} = open(reacted)
    assert has_element?(view, ".episode-location .ui-status", "Reaction selected")
    assert has_element?(view, ".phase-answer .case-entry", ":eyes:")
    assert has_element?(view, ".phase-answer .case-entry .event-state", "Sent")
    assert has_element?(view, ".episode-metrics .metric-response", "2s")
  end

  defp open(entry) do
    live(
      build_conn() |> Map.put(:host, "localhost"),
      "/timeline/" <> URI.encode_www_form("ingress-input:#{entry.id}")
    )
  end

  defp at(seconds), do: DateTime.add(@sent, seconds, :second)

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  # One Slack message in #test, received as Slack sends it: a top-level
  # message starts its own thread, a reply names the thread it is in.
  defp message!(ts, thread, text, occurred_at) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: @dana},
        channel_ref: @channel,
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-message-page-#{ts}",
        message_ref: ts,
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: thread,
        workspace_ref: @workspace
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  # Routing answered the message itself: the committed routing call, the
  # decision, and the reply delivered beside the message.
  defp answered!(entry, reply, delivered_at) do
    decision = %{
      "action" => "quick_reply",
      "episode_ref" => nil,
      "message" => reply,
      "reaction" => nil,
      "reason" => "A greeting needs a short answer, not work.",
      "relation" => "unrelated",
      "repository_source" => nil,
      "work_class" => nil
    }

    committed = DateTime.to_iso8601(DateTime.add(delivered_at, -1, :second))

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "admission",
      policy_digest: String.duplicate("b", 64),
      phase: "committed",
      milestones: %{
        "context_prepared" => DateTime.to_iso8601(entry.inserted_at),
        "response_received" => committed,
        "committed" => committed
      },
      response: %{"state" => "completed", "validation_attempt" => 1}
    })

    decide!(entry, :quick_reply, decision, nil)
    decided = Repo.get!(Entry, entry.id)

    {:ok, {:ok, response}} =
      Repo.transaction(fn -> RoutingResponseCustody.enqueue_in_transaction(decided) end)

    delivered!(response, delivered_at)
  end

  defp delivered!(response, delivered_at) do
    Repo.update_all(from(sent in RoutingResponse, where: sent.id == ^response.id),
      set: [
        status: :delivered,
        delivered_at: delivered_at,
        external_receipt: %{"message_ref" => "1788562330.000900"},
        external_receipt_fingerprint: String.duplicate("c", 64)
      ]
    )
  end

  defp starts_request!(entry) do
    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:#{@dana}",
          destination: %{
            conversation_ref: entry.destination_conversation_ref,
            thread_ref: entry.destination_thread_ref,
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: entry.occurred_at,
          payload: %{"text" => entry.content["text"]},
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decide!(entry, :start_episode, %{"action" => "start_episode"}, episode.id)
    episode
  end

  defp joins!(entry, episode) do
    decide!(
      entry,
      :continue_episode,
      %{"action" => "continue_episode", "episode_ref" => episode.key},
      episode.id
    )
  end

  defp decide!(entry, action, decision, episode_id) do
    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        status: :decided,
        decision_action: action,
        decision_ref: "decision:#{entry.id}",
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_document: decision,
        episode_id: episode_id,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )
  end
end
