defmodule Responder.ControlPlane.EngagementCardTest do
  @moduledoc """
  Participation settings and the Engagement decision in Getting ready.

  The gate's answer used to be invisible, and the tempting reconstruction --
  today's channel settings plus a fresh run of the predicates -- would explain
  an old decision with facts that did not exist when it was made. These cards
  read the receipt written at decision time or say that none was written.
  """
  use Responder.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{EpisodePage, ModelRequests, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input

  @now ~U[2026-09-04 22:51:44.000000Z]

  @rule_receipt %{
    "version" => 1,
    "path" => "slack_event",
    "result" => "process",
    "reason" => "A standing rule matched this message.",
    "checks" => [
      %{"check" => "direct_or_mention", "outcome" => "no"},
      %{"check" => "existing_episode_thread", "outcome" => "no"},
      %{"check" => "standing_rule", "outcome" => "matched"}
    ],
    "settings" => %{
      "proactive" => %{"value" => false, "source" => "channel"},
      "shadow" => %{"value" => false, "source" => "deployment"}
    },
    "execution_mode" => "live"
  }

  test "the cards follow the approved order: settings, rules, engagement" do
    {_entry, episode} = admitted!(engagement_receipt: @rule_receipt)
    html = rendered(episode)

    positions =
      for label <- ["Participation settings", "Standing rules", "Engagement"],
          do: :binary.match(html, "<h3>" <> label) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "participation settings show each effective value with the source it won from" do
    {_entry, episode} = admitted!(engagement_receipt: @rule_receipt)
    html = rendered(episode)

    facts =
      LazyHTML.from_document(html) |> LazyHTML.query(".participation-facts") |> LazyHTML.text()

    assert facts =~ "Proactive"
    assert facts =~ "Off · Saved channel setup"
    assert facts =~ "Shadow"
    assert facts =~ "Off · Deployment default"
  end

  test "the engagement decision shows the result, the reason and only the checks the gate made" do
    {_entry, episode} = admitted!(engagement_receipt: @rule_receipt)
    html = rendered(episode)
    card = LazyHTML.from_document(html) |> LazyHTML.query(".engagement-decision")

    assert LazyHTML.text(card) =~ "Process"
    assert LazyHTML.text(card) =~ "A standing rule matched this message."

    details = LazyHTML.query(card, ".event-facts") |> LazyHTML.text()
    assert details =~ "Standing rule"
    assert details =~ "Matched"
    # The gate stopped at the rule; proactive participation was never evaluated.
    assert details =~ "Not checked"
    refute details =~ "Proactive participation\n"
    assert LazyHTML.text(card) =~ "Standing rules card above"
  end

  test "an explicit Lab submission says it bypassed channel settings instead of inventing checks" do
    receipt = %{
      "version" => 1,
      "path" => "conversation_lab",
      "result" => "process",
      "reason" => "Explicitly submitted through Conversation Lab.",
      "checks" => [],
      "settings" => nil,
      "execution_mode" => "live"
    }

    {_entry, episode} = admitted!(engagement_receipt: receipt)
    html = rendered(episode)
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, ".participation-settings") |> LazyHTML.text() =~
             "Not applicable: an explicit Conversation Lab submission bypasses channel participation settings."

    engagement = LazyHTML.query(document, ".engagement-decision") |> LazyHTML.text()
    assert engagement =~ "Explicitly submitted through Conversation Lab."
    refute engagement =~ "Direct message / mention"
  end

  test "history without a receipt says so and never reads today's settings" do
    {_entry, episode} = admitted!([])
    html = rendered(episode)
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, ".participation-settings") |> LazyHTML.text() =~
             "Effective participation settings were not recorded for this input."

    assert LazyHTML.query(document, ".engagement-decision") |> LazyHTML.text() =~
             "The engagement decision was not recorded for this input."

    refute html =~ "Decision details"
    refute html =~ "Deployment default"
  end

  test "a shadow decision is evaluate-only, not a rejection" do
    receipt =
      @rule_receipt
      |> Map.put("result", "evaluate_only")
      |> Map.put(
        "reason",
        "Shadow mode is enabled for this channel; a standing rule matched this message."
      )
      |> Map.put("execution_mode", "shadow")
      |> put_in(["settings", "shadow"], %{"value" => true, "source" => "channel"})

    {_entry, episode} = admitted!(engagement_receipt: receipt)
    html = rendered(episode)

    card =
      LazyHTML.from_document(html) |> LazyHTML.query(".engagement-decision") |> LazyHTML.text()

    assert card =~ "Evaluate only"
    assert card =~ "Shadow mode is enabled"
    refute card =~ "Not picked up"
  end

  defp rendered(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp admitted!(options) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Terraform plan: 2 to add"},
        event_kind: :message,
        event_ref: "Ev-engagement-#{Ecto.UUID.generate()}",
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
          payload: Responder.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "reason" => "A direct reply.",
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
