defmodule Ryker.ControlPlane.EngagementCardTest do
  @moduledoc """
  The consolidated Participation explanation in Getting ready.

  The gate's answer used to be invisible, and the tempting reconstruction --
  today's channel settings plus a fresh run of the predicates -- would explain
  an old decision with facts that did not exist when it was made. This card
  reads the receipt written at decision time or says that none was written.
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

  test "one Participation card precedes Input queue" do
    {_entry, episode} = admitted!(engagement_receipt: @rule_receipt)
    html = rendered(episode)
    document = LazyHTML.from_document(html)

    assert Enum.count(LazyHTML.query(document, ".participation")) == 1
    assert LazyHTML.query(document, ".participation h3") |> LazyHTML.text() == "Participation"
    refute html =~ "<h3>Participation settings</h3>"
    refute html =~ "<h3>Engagement</h3>"

    positions =
      for marker <- [
            ~s(class="ui-message-body markdown-preview"),
            ~s(class="case-event-content participation"),
            ~s(class="case-event-content input-queue")
          ],
          do: :binary.match(html, marker) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "Slack participation paths use the retained audience and checks in plain language" do
    paths = [
      {:mention, direct_receipt(), "Ryker processed this message because it was mentioned."},
      {:direct, direct_receipt(), "Ryker processed this direct message."},
      {:ambient, receipt([{"direct_or_mention", "no"}, {"existing_episode_thread", "yes"}]),
       "Ryker processed this message because it continued an existing episode."},
      {:ambient,
       receipt(
         [
           {"direct_or_mention", "no"},
           {"existing_episode_thread", "no"},
           {"standing_rule", "not_matched"},
           {"proactive_participation", "on"},
           {"shadow_evaluation", "off"}
         ],
         proactive: true
       ),
       "Ryker processed this message even though it was not mentioned because proactive replies were on."}
    ]

    for {audience, receipt, expected} <- paths do
      {_entry, episode} =
        admitted!(
          engagement_receipt: receipt,
          slack_audience: audience,
          slack_bot_user_ref: "URYKER"
        )

      card = participation(episode)
      assert summary(card) == expected
      assert Enum.empty?(LazyHTML.query(card, ".event-state"))
      assert Enum.empty?(LazyHTML.query(card, ".participation-decision"))
    end
  end

  test "normal channel setup is two plain On/Off rows without provenance or gate plumbing" do
    {_entry, episode} =
      admitted!(
        engagement_receipt: direct_receipt(),
        slack_audience: :mention,
        slack_bot_user_ref: "URYKER"
      )

    card = participation(episode)
    setup = LazyHTML.query(card, ".participation-settings")

    assert LazyHTML.query(setup, "h4") |> LazyHTML.text() == "Channel setup at the time"
    assert LazyHTML.query(setup, ".ui-facts") |> Enum.count() == 1
    assert LazyHTML.query(setup, ".event-facts") |> Enum.empty?()

    assert LazyHTML.query(setup, "dt") |> Enum.map(&LazyHTML.text/1) == [
             "Proactive replies",
             "Shadow evaluation"
           ]

    assert LazyHTML.query(setup, "dd") |> Enum.map(&(LazyHTML.text(&1) |> String.trim())) == [
             "Off",
             "Off"
           ]

    text = LazyHTML.text(card)
    refute text =~ "Saved channel setup"
    refute text =~ "Deployment default"
    refute text =~ "Direct message / mention"
    refute text =~ "Execution mode"
    refute text =~ "Decision details"
  end

  test "shadow evaluation is a no-reply explanation qualified by the retained mention" do
    receipt =
      direct_receipt()
      |> Map.put("result", "evaluate_only")
      |> Map.put("execution_mode", "shadow")
      |> put_in(["settings", "shadow"], %{"value" => true, "source" => "channel"})

    {_entry, episode} =
      admitted!(
        engagement_receipt: receipt,
        execution_mode: :shadow,
        slack_audience: :mention,
        slack_bot_user_ref: "URYKER"
      )

    card = participation(episode)

    assert summary(card) ==
             "Ryker evaluated this message without replying because Shadow evaluation was on and it qualified because Ryker was mentioned."

    refute LazyHTML.text(card) =~ "Evaluate only"
    refute LazyHTML.text(card) =~ "Not picked up"
  end

  test "explicit Lab and shortcut submissions say channel settings did not apply" do
    for {path, expected} <- [
          {"conversation_lab",
           "Ryker processed this message because it was sent directly through Chat."},
          {"slack_shortcut",
           "Ryker processed this message because it was submitted through a Slack shortcut."}
        ] do
      {_entry, episode} = admitted!(engagement_receipt: receipt([], path: path, settings: nil))
      card = participation(episode)
      assert summary(card) == expected

      assert LazyHTML.query(card, ".participation-settings") |> LazyHTML.text() =~
               "Channel settings did not apply."

      refute LazyHTML.text(card) =~ "Entry path"
    end
  end

  test "history without a receipt has one truthful explanation and no reconstructed settings" do
    {_entry, episode} = admitted!([])
    card = participation(episode)

    assert summary(card) ==
             "The participation decision and channel settings were not recorded for this message."

    assert Enum.empty?(LazyHTML.query(card, ".participation-settings"))
    refute LazyHTML.text(card) =~ "Deployment default"
  end

  defp direct_receipt, do: receipt([{"direct_or_mention", "yes"}])

  defp receipt(checks, options \\ []) do
    %{
      "version" => 1,
      "path" => Keyword.get(options, :path, "slack_event"),
      "result" => "process",
      "reason" => "Old internal reason.",
      "checks" =>
        Enum.map(checks, fn {check, outcome} -> %{"check" => check, "outcome" => outcome} end),
      "settings" =>
        Keyword.get(options, :settings, %{
          "proactive" => %{
            "value" => Keyword.get(options, :proactive, false),
            "source" => "channel"
          },
          "shadow" => %{"value" => false, "source" => "deployment"}
        }),
      "execution_mode" => "live"
    }
  end

  defp participation(episode) do
    episode
    |> rendered()
    |> LazyHTML.from_document()
    |> LazyHTML.query(".participation")
  end

  defp summary(card),
    do: card |> LazyHTML.query(".participation-summary") |> LazyHTML.text() |> String.trim()

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
