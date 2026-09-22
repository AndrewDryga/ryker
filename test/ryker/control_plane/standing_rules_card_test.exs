defmodule Ryker.ControlPlane.StandingRulesCardTest do
  @moduledoc """
  The Standing rules section inside Participation in Getting ready.

  It is always there below the participation decision, and it says one of three
  different things: here is every rule and its verdict; no rules existed; or
  nobody recorded the evaluation. The last two used to be the same blank, and
  an operator who reads "nobody recorded it" as "no rules existed" stops
  looking for the rule that should have fired.
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
  alias Ryker.State.StandingRuleInventory

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "an inventory renders every rule with its verdict, matches first" do
    receipt = %{
      "version" => 1,
      "path" => "slack_event",
      "result" => "process",
      "reason" => "Old internal reason.",
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

    {entry, episode} = admitted!(engagement_receipt: receipt)

    inventory!(entry, [
      rule(
        "Review deployments",
        "not_matched",
        "This event does not match the deployment trigger."
      ),
      rule(
        "Review Terraform plans",
        "matched",
        "A terraform plan from app in this conversation."
      ),
      rule(
        "Investigate database alerts",
        "disabled",
        "This rule was disabled when the input was processed."
      )
    ])

    html = rendered(episode)
    document = LazyHTML.from_document(html)
    rules = LazyHTML.query(document, ".standing-rule")

    assert Enum.count(rules) == 3
    # Matches first, then the rest in a stable title order: neither the
    # recorded order nor the verdict decides where a non-match lands.
    assert LazyHTML.attribute(rules, "data-verdict") == ~w(matched disabled not_matched)
    assert html =~ "3 rules · 1 matched"
    assert html =~ "This event does not match the deployment trigger."
    assert html =~ "Paused"
    refute html =~ "Standing-rule evaluation was not recorded"

    assert LazyHTML.query(document, ".participation-summary") |> LazyHTML.text() ==
             "Ryker processed this message because the standing rule “Review Terraform plans” matched."

    # The card precedes the routing decision in the reading order.
    assert [rules_at, routing_at] =
             Regex.scan(~r/(?:Standing rules|Routing briefing)/, html)
             |> Enum.map(&List.first/1)
             |> Enum.uniq()
             |> Enum.map(fn label -> :binary.match(html, label) |> elem(0) end)

    assert rules_at < routing_at
  end

  test "an empty recorded inventory says no standing rules" do
    {entry, episode} = admitted!()
    inventory!(entry, [])

    html = rendered(episode)
    assert html =~ "No standing rules"
    refute html =~ "Standing-rule history was not recorded"
    assert html =~ ~s(data-rules-state="recorded")
  end

  test "an absent inventory says the evaluation was not recorded, never zero" do
    {_entry, episode} = admitted!()

    html = rendered(episode)
    assert html =~ "Standing-rule history was not recorded for this message."
    refute html =~ "No standing rules"
    refute html =~ "0 matched"
    assert html =~ ~s(data-rules-state="not_recorded")
  end

  test "a truncated inventory says exactly how much was retained" do
    {entry, episode} = admitted!()

    inventory!(
      entry,
      [rule("Review Terraform plans", "matched", "A terraform plan from app.")],
      rule_count: 4,
      truncated: true
    )

    html = rendered(episode)
    assert html =~ "Only 1 of 4 rules were retained; 3 are missing from this older history."
    assert html =~ "Review Terraform plans"
  end

  test "a truncated inventory uses singular grammar for one missing rule" do
    {entry, episode} = admitted!()

    inventory!(entry, [rule("Review Terraform plans", "matched", "A terraform plan from app.")],
      rule_count: 2,
      truncated: true
    )

    assert rendered(episode) =~
             "Only 1 of 2 rules were retained; 1 is missing from this older history."
  end

  test "all verdicts and reasons stay visible, with every match first and emphasized in text" do
    {entry, episode} = admitted!()

    inventory!(entry, [
      rule(
        "Second match",
        "matched",
        "A deployment from an app in this channel matched this rule."
      ),
      rule(
        "First match",
        "matched",
        "A Terraform plan from an app in this channel matched this rule."
      ),
      rule("Wrong event", "not_matched", "This event did not match the deployment trigger."),
      rule(
        "Wrong sender",
        "not_matched",
        "This message came from an app; this rule only applies to messages from people."
      ),
      rule("Other channel", "out_of_scope", "This rule applies to another channel."),
      rule("Paused rule", "disabled", "This rule was paused when the message was processed."),
      rule("Expired rule", "expired", "This rule expired before the message arrived."),
      rule(
        "Late rule",
        "not_considered",
        "Only the first 100 applicable rules are evaluated. This rule’s trigger was not checked."
      )
    ])

    card = rendered(episode) |> LazyHTML.from_document() |> LazyHTML.query(".participation-rules")
    rules = LazyHTML.query(card, ".standing-rule")

    assert LazyHTML.query(card, "h4") |> LazyHTML.text() |> String.trim() ==
             "Standing rules at the time"

    assert LazyHTML.text(card) =~ "8 rules · 2 matched"

    assert LazyHTML.attribute(rules, "data-verdict") == [
             "matched",
             "matched",
             "expired",
             "not_considered",
             "out_of_scope",
             "disabled",
             "not_matched",
             "not_matched"
           ]

    assert LazyHTML.query(rules, ".standing-rule-heading strong")
           |> Enum.map(&LazyHTML.text/1) == [
             "First match",
             "Second match",
             "Expired rule",
             "Late rule",
             "Other channel",
             "Paused rule",
             "Wrong event",
             "Wrong sender"
           ]

    assert LazyHTML.query(rules, ".standing-rule-verdict") |> Enum.map(&LazyHTML.text/1) == [
             "Matched",
             "Matched",
             "Expired",
             "Not evaluated",
             "Other channel",
             "Paused",
             "Did not match",
             "Did not match"
           ]

    reasons = LazyHTML.query(rules, ".standing-rule-reason") |> Enum.map(&LazyHTML.text/1)
    assert Enum.any?(reasons, &(&1 =~ "only applies to messages from people"))
    assert Enum.any?(reasons, &(&1 =~ "applies to another channel"))
    assert Enum.any?(reasons, &(&1 =~ "paused when the message was processed"))
    assert Enum.any?(reasons, &(&1 =~ "expired before the message arrived"))
    assert Enum.any?(reasons, &(&1 =~ "first 100 applicable rules"))
    refute Enum.any?(reasons, &(&1 =~ "slack:"))

    assert Enum.all?(LazyHTML.query(rules, ".standing-rule-definition"), fn detail ->
             Enum.any?(
               LazyHTML.attribute(detail, "class"),
               &String.contains?(&1, "ui-disclosure")
             )
           end)

    assert LazyHTML.query(rules, ".standing-rule-definition .event-facts") |> Enum.empty?()
  end

  test "a complete inventory with no matches keeps every rule and reports zero matched" do
    {entry, episode} = admitted!()

    inventory!(entry, [
      rule("Review deployments", "not_matched", "This event did not match."),
      rule("Watch another channel", "out_of_scope", "This rule applies to another channel.")
    ])

    card = rendered(episode) |> LazyHTML.from_document() |> LazyHTML.query(".participation-rules")

    assert LazyHTML.text(card) =~ "2 rules · 0 matched"
    assert Enum.count(LazyHTML.query(card, ".standing-rule")) == 2
  end

  test "a later rule change does not rewrite the recorded explanation" do
    {entry, episode} = admitted!()
    inventory!(entry, [rule("Review Terraform plans", "matched", "A terraform plan from app.")])

    # A rule renamed, paused or deleted today must leave the old card alone;
    # the card reads only its own frozen entries.
    before = participation_tree(episode)

    Repo.update_all(
      from(row in StandingRuleInventory,
        where: row.source_input_ref == ^"ingress-input:#{entry.id}"
      ),
      set: [rule_count: 1]
    )

    assert participation_tree(episode) == before
  end

  defp rule(title, verdict, reason) do
    %{
      "ref" => "behavior:" <> String.replace(String.downcase(title), " ", "-"),
      "title" => title,
      "status" => if(verdict == "disabled", do: "disabled", else: "active"),
      "scope_ref" => "slack:TC9F5B40D364C:C456",
      "revision" => 3,
      "verdict" => verdict,
      "reason" => reason
    }
  end

  defp inventory!(entry, entries, options \\ []) do
    Repo.insert!(%StandingRuleInventory{
      id: Ecto.UUID.generate(),
      source_input_ref: "ingress-input:#{entry.id}",
      source_event_ref: entry.event_ref,
      workspace_ref: "slack:TC9F5B40D364C",
      conversation_ref: "slack:TC9F5B40D364C:C456",
      rule_count: Keyword.get(options, :rule_count, length(entries)),
      matched_count: Enum.count(entries, &(&1["verdict"] == "matched")),
      truncated: Keyword.get(options, :truncated, false),
      entries: entries,
      recorded_at: DateTime.add(@now, 1, :second)
    })
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

  defp participation_tree(episode) do
    episode
    |> rendered()
    |> LazyHTML.from_document()
    |> LazyHTML.query(".participation")
    |> LazyHTML.to_tree()
  end

  defp admitted!(options \\ []) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Terraform plan: 2 to add"},
        event_kind: :message,
        event_ref: "Ev-rules-#{Ecto.UUID.generate()}",
        message_ref: "1788562304.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input, options)
    # This fixture drives the card directly; the recorder's own path is covered
    # in Ryker.State.StandingRuleInventoryTest.
    Repo.delete_all(StandingRuleInventory)

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
