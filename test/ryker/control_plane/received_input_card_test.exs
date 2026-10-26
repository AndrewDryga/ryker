defmodule Ryker.ControlPlane.ReceivedInputCardTest do
  @moduledoc """
  Received inputs expose raw, normalized and original records as peer
  disclosures. Their technical identity stays in HTML, not a redundant
  metadata row; raw and normalized remain distinct and lazy.
  """
  # The retained sender-name regression starts the globally named directory.
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input

  @now ~U[2026-09-04 22:51:44.000000Z]
  @envelope %{
    "type" => "message",
    "channel" => "C456",
    "ts" => "1788562304.000100",
    "text" => "Terraform plan: 2 to add",
    "client_msg_id" => "raw-only-field"
  }

  test "retained app names also name compact candidate messages without rewriting the prompt" do
    start_supervised!(
      {Ryker.Slack.Names,
       workspace: "TC9F5B40D364C", fetch: fn _ -> {:error, :not_found} end, interval: 60_000}
    )

    {_entry, episode} =
      admitted!([source_envelope: %{"username" => "Example Monitoring"}],
        actor: %{kind: :app, ref: "A123"}
      )

    rendered(episode, [])

    assert GenServer.call(Ryker.Slack.Names, :refresh) == :ok

    context = %{
      "candidates" => [
        %{
          "state" => "complete",
          "title" => "Earlier alert",
          "first_message" => %{
            "actor" => "A123",
            "text" => "Alert closed",
            "at" => "2026-10-07T20:01:23Z"
          }
        }
      ]
    }

    document =
      context
      |> Ryker.InspectionRedactor.artifact()
      |> Ryker.ControlPlane.RequestContextHTML.assembly("$.context", "candidate-names")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".ui-message-header strong") |> LazyHTML.text() ==
             "Example Monitoring"

    refute LazyHTML.text(document) =~ "A123"
    assert get_in(context, ["candidates", Access.at(0), "first_message", "actor"]) == "A123"
    Ryker.Slack.Names.remember([{"TC9F5B40D364C", "A123", "Current Monitoring"}])
    rendered(episode, [])
    assert GenServer.call(Ryker.Slack.Names, :refresh) == :ok
    assert Ryker.Slack.Names.name("TC9F5B40D364C", "A123") == "Current Monitoring"
  end

  test "learned topics request unknown channel names and compact actors accept all-letter Slack IDs" do
    # Review found the topic renderer only read the cache, so a channel it alone
    # displayed never got a name. IDs also do not require a digit in Slack's grammar.
    parent = self()

    start_supervised!(
      {Ryker.Slack.Names,
       workspace: "T123",
       interval: 60_000,
       known: [{"ALETTERS", "Example Monitoring"}],
       fetch: fn ref ->
         send(parent, {:name_lookup, ref})
         {:ok, "infra"}
       end}
    )

    context = %{
      "conversation_knowledge" => [
        %{
          "title" => "Earlier alert",
          "summary" => "Alert closed",
          "conversation_ref" => "slack:T123:C456"
        }
      ],
      "candidates" => [
        %{
          "state" => "complete",
          "first_message" => %{"actor" => "ALETTERS", "text" => "Alert closed"}
        }
      ]
    }

    render = fn ->
      context
      |> Ryker.InspectionRedactor.artifact()
      |> Ryker.ControlPlane.RequestContextHTML.assembly("$.context", "topic-names")
      |> IO.iodata_to_binary()
    end

    before_lookup = render.()
    assert GenServer.call(Ryker.Slack.Names, :refresh) == :ok
    assert_received {:name_lookup, "C456"}
    assert render.() =~ "#infra"
    assert before_lookup =~ "Example Monitoring"
    refute before_lookup =~ "ALETTERS"
  end

  test "retained app metadata never waits for Slack or overwrites a name resolved during rendering" do
    # Seeding a retained name used a synchronous cache call in the render path:
    # one unrelated slow Slack lookup could stall a timeline for five seconds.
    parent = self()

    start_supervised!(
      {Ryker.Slack.Names,
       workspace: "TC9F5B40D364C",
       interval: 60_000,
       fetch: fn _ ->
         send(parent, {:lookup_waiting, self()})
         receive do: (:release_lookup -> {:ok, "Current Monitoring"})
       end}
    )

    {_entry, episode} =
      admitted!([source_envelope: %{"username" => "Historical Monitoring"}],
        actor: %{kind: :app, ref: "A123"}
      )

    Ryker.Slack.Names.name("TC9F5B40D364C", "A123")
    send(Ryker.Slack.Names, :tick)
    assert_receive {:lookup_waiting, directory}
    task = Task.async(fn -> rendered(episode, []) end)
    result = Task.yield(task, 1000)
    send(directory, :release_lookup)
    if is_nil(result), do: Task.await(task)
    assert {:ok, _html} = result
    assert GenServer.call(Ryker.Slack.Names, :refresh) == :ok
    assert Ryker.Slack.Names.name("TC9F5B40D364C", "A123") == "Current Monitoring"
  end

  test "input records are three peer disclosures and the input identity stays in HTML" do
    {entry, episode} = admitted!(source_envelope: @envelope)
    html = rendered(episode, [])
    document = LazyHTML.from_document(html)

    message = LazyHTML.query(document, "#story-message-#{entry.id}")

    assert LazyHTML.query(message, ".ui-message-title") |> LazyHTML.text() ==
             "Incoming message"

    # The sender is a person: their name, linked to their Slack profile, never
    # the raw ID (Andrew, 2026-09-26: "Slack user U0BHTNFCW6S" is not
    # readable). Slack has not named them here yet.
    sender = LazyHTML.query(message, ".ui-message-header strong a")
    assert LazyHTML.text(sender) == "Slack user"

    assert LazyHTML.attribute(sender, "href") == [
             "https://slack.com/app_redirect?team=TC9F5B40D364C&channel=U123"
           ]

    refute LazyHTML.query(message, ".ui-message-header") |> LazyHTML.text() =~ "U123"

    # The card's time sits in the time column like every other card's (the
    # first card of the page once had an empty one); the message is a reusable
    # component and keeps its own time as well.
    assert LazyHTML.query(message, ".case-entry-time > time") |> LazyHTML.text() == "22:51:44"

    assert LazyHTML.query(message, ".ui-message-meta time") |> LazyHTML.text() |> String.trim() ==
             "4 Sep, 22:51:44 UTC"

    assert LazyHTML.query(message, ".ui-message > .ui-message-frame > .ui-message-body")
           |> LazyHTML.text() =~
             "Terraform plan"

    # A redundant Details disclosure and ID row made three records require two
    # expansion steps in production (Andrew, 2026-10-25).
    assert LazyHTML.query(message, ".case-message")
           |> LazyHTML.attribute("data-input-id") == ["ingress-input:#{entry.id}"]

    assert LazyHTML.query(
             message,
             ".ui-message-footer > .input-body > summary .ui-disclosure-label"
           )
           |> Enum.map(&LazyHTML.text/1) ==
             ["Raw input (JSON)", "Normalized input (JSON)", "Original message"]

    assert Enum.empty?(LazyHTML.query(message, ".input-details"))
    refute LazyHTML.text(message) =~ "Input ID"
    refute LazyHTML.text(message) =~ "Details"
    refute "Copy Input ID" in LazyHTML.attribute(LazyHTML.query(message, "button"), "aria-label")

    # Bodies remain in the approved order.
    positions =
      for id <- [
            "input-raw-#{entry.id}",
            "input-normalized-#{entry.id}",
            "input-original-#{entry.id}"
          ],
          do: :binary.match(html, ~s(id="#{id}")) |> elem(0)

    assert positions == Enum.sort(positions)

    # Bodies are lazy: nothing raw-only or normalized is in the page until opened.
    refute html =~ "raw-only-field"
    assert html =~ ~s(data-artifact="input-#{entry.id}-raw")
    assert html =~ ~s(data-artifact="input-#{entry.id}-normalized")
  end

  # Harvested sender shape: the Google Cloud Monitoring notification carried
  # username beside app_id, but the UI showed the raw app ID instead.
  test "a Slack app is named from its retained sender metadata" do
    envelope =
      Map.merge(@envelope, %{"app_id" => "A123", "username" => "Google Cloud Monitoring"})

    {entry, episode} = admitted!([source_envelope: envelope], actor: %{kind: :app, ref: "A123"})

    message =
      rendered(episode, [])
      |> LazyHTML.from_document()
      |> LazyHTML.query("#story-message-#{entry.id}")

    assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() ==
             "Google Cloud Monitoring"

    refute LazyHTML.query(message, ".ui-message-header") |> LazyHTML.text() =~ "A123"
  end

  test "missing or expired Slack app metadata does not expose a raw app ID or a stale name" do
    for envelope <- [nil, %{"username" => ""}, %{"username" => %{}}] do
      {entry, episode} = admitted!([source_envelope: envelope], actor: %{kind: :app, ref: "A123"})

      message =
        rendered(episode, [])
        |> LazyHTML.from_document()
        |> LazyHTML.query("#story-message-#{entry.id}")

      assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() ==
               "Slack app"
    end

    {entry, episode} =
      admitted!([source_envelope: %{"username" => "Old app name"}],
        actor: %{kind: :app, ref: "A123"}
      )

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    message =
      rendered(episode, [])
      |> LazyHTML.from_document()
      |> LazyHTML.query("#story-message-#{entry.id}")

    assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() == "Slack app"
    refute LazyHTML.text(message) =~ "Old app name"
  end

  test "recorded app names are escaped and redacted like message content" do
    envelope = Map.put(@envelope, "username", "<b>Monitoring</b> password=hunter2")
    {entry, episode} = admitted!([source_envelope: envelope], actor: %{kind: :app, ref: "A123"})

    message =
      rendered(episode, [])
      |> LazyHTML.from_document()
      |> LazyHTML.query("#story-message-#{entry.id}")

    sender = LazyHTML.query(message, ".ui-message-header strong")

    assert LazyHTML.text(sender) =~ "<b>Monitoring</b>"
    assert LazyHTML.text(sender) =~ "[redacted]"
    refute LazyHTML.text(sender) =~ "hunter2"
    assert Enum.empty?(LazyHTML.query(sender, "b"))
  end

  test "edited events use the edited sender metadata and bot profiles can supply a name" do
    for envelope <- [
          %{
            "subtype" => "message_changed",
            "username" => "Old sender",
            "message" => %{"username" => "Google Cloud Monitoring"}
          },
          %{"bot_profile" => %{"name" => "Google Cloud Monitoring"}}
        ] do
      {entry, episode} = admitted!([source_envelope: envelope], actor: %{kind: :app, ref: "A123"})

      message =
        rendered(episode, [])
        |> LazyHTML.from_document()
        |> LazyHTML.query("#story-message-#{entry.id}")

      assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() ==
               "Google Cloud Monitoring"
    end
  end

  test "kernel lifecycle cards do not repeat metadata owned by input details" do
    {_entry, episode} = admitted!(source_envelope: @envelope)
    {:ok, detail} = EpisodeProjection.fetch(episode.key, %{})

    input_transition =
      Enum.find(detail.trace.steps, fn step ->
        String.starts_with?(step.id, "kernel-") && step.stage == "Input"
      end)

    assert input_transition
    assert input_transition.details == []
  end

  test "opening the raw body shows the adapter's payload, not the normalized document" do
    {entry, episode} = admitted!(source_envelope: @envelope)
    html = rendered(episode, ["input-#{entry.id}-raw"])

    raw =
      LazyHTML.from_document(html)
      |> LazyHTML.query("#input-raw-#{entry.id} pre")
      |> LazyHTML.text()

    assert raw =~ "raw-only-field"
    refute raw =~ "slack_event_kind"

    html = rendered(episode, ["input-#{entry.id}-normalized"])

    normalized =
      LazyHTML.from_document(html)
      |> LazyHTML.query("#input-normalized-#{entry.id} pre")
      |> LazyHTML.text()

    refute normalized =~ "raw-only-field"
    assert normalized =~ "Terraform plan"
  end

  test "a raw input that carried a credential shows it removed, with no secrets disclaimer" do
    # Andrew, 2026-09-26: no "Secrets redacted" disclaimers anywhere. The raw
    # body's summary said so beside its size; the value is still removed.
    envelope = Map.put(@envelope, "token", "slack-verification-token-value")
    {entry, episode} = admitted!(source_envelope: envelope)
    html = rendered(episode, ["input-#{entry.id}-raw"])
    raw = LazyHTML.from_document(html) |> LazyHTML.query("#input-raw-#{entry.id}")

    assert raw |> LazyHTML.query("pre") |> LazyHTML.text() =~ "[redacted]"
    refute html =~ "slack-verification-token-value"
    refute LazyHTML.text(raw) =~ ~r/secrets redacted/i
  end

  test "an input recorded without an envelope says the raw record is absent" do
    {entry, episode} = admitted!([])
    html = rendered(episode, ["input-#{entry.id}-raw"])

    raw = LazyHTML.from_document(html) |> LazyHTML.query("#input-raw-#{entry.id}")
    assert LazyHTML.text(raw) =~ "Not recorded"
    assert LazyHTML.text(raw) =~ "not a substitute"
    refute html =~ ~s(data-artifact="input-#{entry.id}-raw")
  end

  test "an oversized envelope is an explicit omission, not an absence" do
    {entry, episode} = admitted!(source_envelope: %{"blob" => String.duplicate("x", 70_000)})
    html = rendered(episode, [])

    raw =
      LazyHTML.from_document(html) |> LazyHTML.query("#input-raw-#{entry.id}") |> LazyHTML.text()

    assert raw =~ "Omitted"
    assert raw =~ "over the 64 KiB limit"
    refute raw =~ "Not recorded"
  end

  test "an expired input closes its bodies instead of keeping a reader's copy" do
    {entry, episode} = admitted!(source_envelope: @envelope)

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        operational_pruned_at: DateTime.utc_now(),
        source_envelope: %{"retention" => "pruned"}
      ]
    )

    html = rendered(episode, ["input-#{entry.id}-raw", "input-#{entry.id}-normalized"])
    refute html =~ "raw-only-field"
    assert html =~ ~s(id="input-raw-#{entry.id}")
    assert html =~ ~s(data-revoked="true")
  end

  test "a recognized Terraform notification leads with provider, state and facts and ends with links" do
    fixture = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    content = Map.take(fixture, ["text", "attachments", "subtype", "bot_id"])
    {entry, episode} = admitted!([], content: content, actor: %{kind: :bot, ref: "B0BHPQTBMA7"})
    html = rendered(episode, [])
    document = LazyHTML.from_document(html)

    card = LazyHTML.query(document, ".provider-message.provider-terraform")
    assert Enum.count(card) == 1
    text = LazyHTML.text(card)
    assert LazyHTML.query(card, ".case-card-heading h3") |> LazyHTML.text() == "HCP Terraform"
    assert LazyHTML.query(card, ".case-card-heading-detail") |> LazyHTML.text() == "via Slack"
    assert text =~ "Planning"
    assert Enum.empty?(LazyHTML.query(card, ".provider-state, .case-card-heading-meta"))

    assert LazyHTML.query(card, ".provider-body .provider-facts > div:first-child dt")
           |> LazyHTML.text() == "Status"

    assert LazyHTML.query(card, ".provider-body .provider-facts > div:first-child .ui-fact-value")
           |> LazyHTML.text()
           |> String.trim() == "Planning"

    assert text =~ "Dryga/emisar"
    assert text =~ "run-k9CpPp3nWjQrkCMG"
    assert LazyHTML.query(card, ".provider-facts.ui-facts") |> Enum.count() == 1
    assert LazyHTML.query(card, ".event-facts") |> Enum.empty?()

    # Provider destinations belong beside the subject, visible before the
    # technical input record rather than in a detached far-edge footer.
    details_at = :binary.match(html, ~s(id="input-raw-#{entry.id}")) |> elem(0)
    links_at = :binary.match(html, "provider-links") |> elem(0)
    assert links_at < details_at
    assert Enum.count(LazyHTML.query(card, ".provider-subject .provider-links")) == 1
    assert html =~ "Open run ↗"
    assert html =~ "Open workspace ↗"
    refute html =~ "javascript:"
    assert LazyHTML.attribute(card, "data-input-id") == ["ingress-input:#{entry.id}"]
    assert Enum.count(LazyHTML.query(document, ".provider-message + .input-body")) == 1
  end

  test "an expired input loses its recognized card rather than showing a later revision" do
    fixture = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    content = Map.take(fixture, ["text", "attachments"])
    {entry, episode} = admitted!([], content: content, actor: %{kind: :bot, ref: "B0BHPQTBMA7"})

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [operational_pruned_at: DateTime.utc_now(), content: %{"retention" => "pruned"}]
    )

    html = rendered(episode, [])
    refute html =~ "provider-terraform"
    refute html =~ "run-k9CpPp3nWjQrkCMG"
  end

  defp rendered(episode, disclosed) do
    {:ok, detail} = EpisodeProjection.fetch(episode.key, %{"disclosed" => disclosed})
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp admitted!(options, overrides \\ []) do
    {:ok, input} =
      Input.new(%{
        actor: Keyword.get(overrides, :actor, %{kind: :user, ref: "U123"}),
        channel_ref: EpisodeFixtures.channel_ref(),
        content: Keyword.get(overrides, :content, %{"text" => "Terraform plan: 2 to add"}),
        event_kind: :message,
        event_ref: "Ev-received-#{Ecto.UUID.generate()}",
        message_ref: "1788562304.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input, options)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:U123",
          destination: %{
            conversation_ref: "slack:TC9F5B40D364C:#{EpisodeFixtures.channel_ref()}",
            thread_ref: "1788562304.000100",
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @now,
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
        inserted_at: @now,
        status: :decided
      ]
    )

    {Repo.get!(Entry, entry.id), episode}
  end
end
