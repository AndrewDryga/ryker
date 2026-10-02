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
  alias Ryker.ControlPlane.{Actions, Activity, ConversationLab, Endpoint, Projection}
  alias Ryker.Delivery.{RoutingResponse, RoutingResponseCustody}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
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
       pubsub_server: Ryker.PubSub.Server,
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

    decision =
      band |> LazyHTML.query(".phase-routing article.case-entry") |> Enum.to_list() |> List.last()

    assert text(decision, ".episode-request > .case-card-heading h3") == "Answered right away"

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
  # normal?" The page closed with the thread around the message; on
  # 2026-09-28: "drop this, just add link here to show all messages in thread
  # too". The header links to the thread in Activity; a message alone in its
  # thread has nothing to link.
  test "a message's header links to every message of its thread, and a lone message has no link" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>", @sent)
    answered!(greeting, "Hi! How can I help?", DateTime.add(@sent, 27, :second))

    {:ok, lone, _html} = open(greeting)
    refute has_element?(lone, ".episode-location a", "All messages in this thread")

    question =
      message!("1788562400.000200", @root, "Why is checkout returning 502s?", at(96))

    starts_request!(question)

    {:ok, view, _html} = open(greeting)
    refute has_element?(view, "section#in-this-thread")

    thread =
      Activity.conversation_path(
        "slack",
        greeting.destination_conversation_ref,
        @root
      )

    assert has_element?(
             view,
             ".episode-location a[href='#{thread}']",
             "All messages in this thread →"
           )
  end

  # Andrew, 2026-09-27, of these pages for Slack messages: "the slack
  # conversations look super broken and not properly ordered unlike
  # conversations from /conversations. They have some previous messages
  # mid-text, timeline is broken apart and not following the logic". The
  # thread's other messages sat between the answer and a "Routing details"
  # section that held the queue, the briefing and why Ryker read the message,
  # away from the decision they led to. A request's page reads Intake,
  # Routing, Work, Answer; a message's page reads the same, and its thread
  # closes the page, whether the message came from Slack or from Chat.
  test "a message's page reads in the request page's order, with its thread last, from Slack and Chat alike" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>", @sent)
    answered!(greeting, "Hi! How can I help?", at(27))

    question = message!("1788562400.000200", @root, "Why is checkout returning 502s?", at(96))
    starts_request!(question)

    {:ok, view, _html} = open(greeting)
    page = view |> render() |> LazyHTML.from_document()

    story = [
      {:chapter, "Message"},
      {:stage, "Intake"},
      {:card, "Incoming message"},
      {:card, "Participation"},
      {:stage, "Routing"},
      {:card, "Queue"},
      {:card, "Routing briefing"},
      {:card, "Answered right away"},
      {:stage, "Answer"},
      {:card, "Quick reply"}
    ]

    assert reading_order(page) == story

    # The same message sent in Chat reads the same; only the name of the
    # place it was said in differs.
    conversation = Ecto.UUID.generate()
    chat_greeting = chat!(conversation, "hi", @sent)
    answered!(chat_greeting, "Hi! How can I help?", at(27))
    chat_question = chat!(conversation, "Why is checkout returning 502s?", at(96))
    decide!(chat_question, :ignore, %{"action" => "ignore", "reason" => "Not for Ryker."}, nil)

    {:ok, chat_view, _html} = open(chat_greeting)
    chat_page = chat_view |> render() |> LazyHTML.from_document()

    assert reading_order(chat_page) == story

    # Nothing of the message's own story is left in a section of its own, and Jump
    # to lists the chapters in the order they are read.
    assert page |> LazyHTML.query("#routing-details") |> Enum.empty?()

    assert page |> LazyHTML.query(".timeline-index a") |> Enum.map(&LazyHTML.text/1) == [
             "Message"
           ]

    # The routing card's earlier-work links lead up, to the briefing above it.
    refute text(page, ".phase-routing .episode-request") =~ "↓"
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
    decision = %{"action" => "react", "reactions" => ["eyes"]}
    decide!(reacted, :react, decision, nil)

    {:ok, {:ok, [response]}} =
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

  # Andrew, 2026-09-26: "Now both reply and add a reaction". Routing now
  # answers such a message itself with its words and its emoji, and the page
  # of that message has to show everything it sent, in the order it went out:
  # a page that showed one reply would say the rest never happened.
  test "a quick answer of several messages and emoji shows each on the message's page, in order" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>, now both reply and add a reaction", @sent)

    decision = %{
      "action" => "quick_reply",
      "episode_ref" => nil,
      "messages" => ["Hi again!", "Want me to check the deploy too?"],
      "reactions" => ["thumbsup"],
      "reason" => "A greeting that asked for a reply and a reaction.",
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => nil
    }

    greeting
    |> routed!(decision, at(2))
    |> Enum.with_index(3)
    |> Enum.each(fn {response, seconds} -> delivered!(response, at(seconds)) end)

    {:ok, view, _html} = open(greeting)
    page = view |> render() |> LazyHTML.from_document()

    assert text(page, ".episode-location .ui-status") == "Answered right away"

    # The response time is to the first thing that reached the thread.
    assert text(page, ".episode-metrics .metric-response") =~ "3s"

    answer = LazyHTML.query(page, ".phase-answer")

    assert answer
           |> LazyHTML.query(".ui-message[data-author=ryker] .ui-message-body")
           |> Enum.map(&(&1 |> LazyHTML.text() |> squish())) ==
             ["Hi again!", "Want me to check the deploy too?"]

    assert text(answer, ".case-event") =~ ":thumbsup:"
    assert text(answer, ".case-event .event-state") == "Sent"

    # Routing's own card lists each message and the emoji it chose.
    facts = decision_facts(page)
    assert {"Reaction", ":thumbsup:"} in facts
    assert {"First message", "Hi again!"} in facts
    assert {"Second message", "Want me to check the deploy too?"} in facts
  end

  # The migration of 2026-09-27 rewrote every stored decision into the new
  # shape and kept each response routing had already sent, under the delivery
  # reference it was sent with, as the first of its message. Those pages must
  # read exactly as they did.
  test "an answer sent before routing could send several still reads on its page" do
    greeting = message!(@root, nil, "Hi <@#{@ryker}>", @sent)

    [response] =
      routed!(
        greeting,
        %{
          "action" => "quick_reply",
          "episode_ref" => nil,
          "messages" => ["Hi! How can I help?"],
          "reactions" => nil,
          "reason" => "A greeting needs a short answer, not work.",
          "relation" => "unrelated",
          "repository" => nil,
          "repository_source" => nil,
          "work_class" => nil
        },
        at(26)
      )

    Repo.update_all(from(sent in RoutingResponse, where: sent.id == ^response.id),
      set: [delivery_ref: "ingress-message:#{greeting.id}"]
    )

    delivered!(response, at(27))

    {:ok, view, _html} = open(greeting)
    page = view |> render() |> LazyHTML.from_document()

    assert text(page, ".phase-answer .ui-message[data-author=ryker] .ui-message-body") ==
             "Hi! How can I help?"

    assert {"Answer", "Hi! How can I help?"} in decision_facts(page)
    assert text(page, ".episode-metrics .metric-response") =~ "27s"
  end

  # Chapters, their stages and each card's title, in the order a reader
  # meets them on the page.
  defp reading_order(page) do
    page
    |> LazyHTML.query("#execution-timeline > section.trace-chapter")
    |> Enum.flat_map(fn chapter ->
      [
        {:chapter, text(chapter, ".chapter-heading h3")}
        | chapter
          |> LazyHTML.query("section.conversation-phase")
          |> Enum.flat_map(&stage_order/1)
      ]
    end)
  end

  defp stage_order(stage) do
    cards =
      stage
      |> LazyHTML.query("article.case-entry")
      |> Enum.map(fn card ->
        title =
          card
          |> LazyHTML.query(".case-card-heading h3, .ui-message-title")
          |> Enum.at(0)
          |> LazyHTML.text()
          |> squish()

        {:card, title}
      end)

    case text(stage, ".conversation-phase-heading h4") do
      "" -> cards
      heading -> [{:stage, heading} | cards]
    end
  end

  defp open(entry) do
    live(
      build_conn() |> Map.put(:host, "localhost"),
      "/timeline/" <> entry.id
    )
  end

  defp at(seconds), do: DateTime.add(@sent, round(seconds * 1_000), :millisecond)

  defp decision_facts(page) do
    page
    |> LazyHTML.query(".phase-routing .request-decision > div")
    |> Enum.map(fn fact ->
      {fact |> LazyHTML.query("dt") |> LazyHTML.text() |> squish(),
       fact |> LazyHTML.query("dd") |> LazyHTML.text() |> squish()}
    end)
  end

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
    saved!(entry)
  end

  # One message sent in a Chat conversation, as the Chat page sends it.
  defp chat!(conversation, text, occurred_at) do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    {:ok, %{entry: entry}} =
      ConversationLab.send_message(conversation, text, profile, now: fn -> occurred_at end)

    saved!(entry)
  end

  # Saved a moment after it was sent, as the live install saves it.
  defp saved!(entry) do
    saved_at = DateTime.add(entry.occurred_at, 200, :millisecond)

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [inserted_at: saved_at]
    )

    %{entry | inserted_at: saved_at}
  end

  # Routing answered the message itself: the committed routing call, the
  # decision, and the reply delivered beside the message.
  defp answered!(entry, reply, delivered_at) do
    decision = %{
      "action" => "quick_reply",
      "episode_ref" => nil,
      "messages" => [reply],
      "reactions" => nil,
      "reason" => "A greeting needs a short answer, not work.",
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => nil
    }

    [response] = routed!(entry, decision, DateTime.add(delivered_at, -1, :second))
    delivered!(response, delivered_at)
  end

  # The committed routing call and its decision, and the responses it froze
  # for delivery, in the order they are sent.
  # Routing picks the message up a second after it was sent, as the live
  # install does, so its briefing is read before the decision it led to.
  defp routed!(entry, decision, committed_at) do
    committed = DateTime.to_iso8601(committed_at)
    picked_up = DateTime.add(entry.occurred_at, 1, :second)

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "admission",
      policy_digest: String.duplicate("b", 64),
      phase: "committed",
      milestones: %{
        "context_prepared" => DateTime.to_iso8601(picked_up),
        "response_received" => committed,
        "committed" => committed
      },
      response: %{"state" => "completed", "validation_attempt" => 1},
      inserted_at: picked_up
    })

    decide!(entry, String.to_existing_atom(decision["action"]), decision, nil)
    decided = Repo.get!(Entry, entry.id)

    {:ok, {:ok, responses}} =
      Repo.transaction(fn -> RoutingResponseCustody.enqueue_in_transaction(decided) end)

    responses
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
