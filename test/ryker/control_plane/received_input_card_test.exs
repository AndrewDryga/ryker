defmodule Ryker.ControlPlane.ReceivedInputCardTest do
  @moduledoc """
  The Received input card and its Input details.

  Input details open on extracted metadata a person can read, and only then
  offer the raw source envelope, the normalized input and the original message
  as separate bodies. Raw is what the adapter received and normalized is what
  Ryker made of it; showing the second under the first's name told an
  operator that the source had sent fields Ryker had actually added.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection}
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

  test "input details lead with metadata and keep raw, normalized and original apart" do
    {entry, episode} = admitted!(source_envelope: @envelope)
    html = rendered(episode, [])
    document = LazyHTML.from_document(html)

    message = LazyHTML.query(document, "#story-message-#{entry.id}")

    assert LazyHTML.query(message, ".case-card-heading h3") |> LazyHTML.text() ==
             "Slack user U123"

    assert LazyHTML.query(message, ".case-message-text") |> LazyHTML.text() =~ "Terraform plan"

    details = LazyHTML.query(document, "#input-details-#{entry.id}")
    assert Enum.count(details) == 1
    text = LazyHTML.text(details)

    for label <- [
          "Input ID",
          "Source",
          "Event",
          "Event ID",
          "Event identity",
          "Message ID",
          "Sender ID",
          "Source revision",
          "Source event time",
          "Recorded by Ryker"
        ] do
      assert text =~ label
    end

    refute text =~ "time reported by the source"
    refute text =~ "time assigned at ingress"
    refute text =~ "Extracted metadata"

    assert details
           |> LazyHTML.query("button[data-copy-value]")
           |> LazyHTML.attribute("data-copy-value")
           |> Enum.take(2) == ["ingress-input:#{entry.id}", entry.dedupe_key]

    # Metadata precedes the three bodies, and the bodies come in the approved order.
    positions =
      for id <- [
            "input-raw-#{entry.id}",
            "input-normalized-#{entry.id}",
            "input-original-#{entry.id}"
          ],
          do: :binary.match(html, ~s(id="#{id}")) |> elem(0)

    assert positions == Enum.sort(positions)
    assert :binary.match(html, ~s(id="input-details-#{entry.id}")) |> elem(0) < hd(positions)

    # Bodies are lazy: nothing raw-only or normalized is in the page until opened.
    refute html =~ "raw-only-field"
    assert html =~ ~s(data-artifact="input-#{entry.id}-raw")
    assert html =~ ~s(data-artifact="input-#{entry.id}-normalized")
  end

  test "kernel lifecycle cards do not repeat metadata owned by input details" do
    {_entry, episode} = admitted!(source_envelope: @envelope)
    {:ok, detail} = Projection.episode(episode.key, %{})

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
    assert raw =~ "beyond the 64 KiB bound"
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
    assert text =~ "HCP Terraform · via Slack"
    assert text =~ "Planning"
    assert text =~ "Dryga/emisar"
    assert text =~ "run-k9CpPp3nWjQrkCMG"
    assert LazyHTML.query(card, ".provider-facts.ui-facts") |> Enum.count() == 1
    assert LazyHTML.query(card, ".event-facts") |> Enum.empty?()

    # Links sit after Input details, outside the disclosure, visible when collapsed.
    details_at = :binary.match(html, ~s(id="input-details-#{entry.id}")) |> elem(0)
    links_at = :binary.match(html, "provider-links") |> elem(0)
    assert links_at > details_at
    assert html =~ "Open run ↗"
    assert html =~ "Open workspace ↗"
    refute html =~ "javascript:"
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
    {:ok, detail} = Projection.episode(episode.key, %{"disclosed" => disclosed})
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
        channel_ref: "C456",
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
            conversation_ref: "slack:TC9F5B40D364C:C456",
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
