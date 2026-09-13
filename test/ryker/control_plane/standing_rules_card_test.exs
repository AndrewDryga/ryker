defmodule Ryker.ControlPlane.StandingRulesCardTest do
  @moduledoc """
  The Standing rules card in Getting ready.

  It is always there, before the engagement decision, and it says one of three
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
    {entry, episode} = admitted!()

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
    assert html =~ "1 matched · 2 other"
    assert html =~ "This event does not match the deployment trigger."
    assert html =~ "Paused"
    refute html =~ "Standing-rule evaluation was not recorded"

    # The card precedes the routing decision in the reading order.
    assert [rules_at, routing_at] =
             Regex.scan(~r/(?:Standing rules|Routing briefing)/, html)
             |> Enum.map(&List.first/1)
             |> Enum.uniq()
             |> Enum.map(fn label -> :binary.match(html, label) |> elem(0) end)

    assert rules_at < routing_at
  end

  test "an empty recorded inventory says no rules existed" do
    {entry, episode} = admitted!()
    inventory!(entry, [])

    html = rendered(episode)
    assert html =~ "No standing rules existed when this input was processed."
    refute html =~ "Standing-rule evaluation was not recorded"
    assert html =~ ~s(data-rules-state="recorded")
  end

  test "an absent inventory says the evaluation was not recorded, never zero" do
    {_entry, episode} = admitted!()

    html = rendered(episode)
    assert html =~ "Standing-rule evaluation was not recorded for this input."
    refute html =~ "No standing rules existed"
    refute html =~ "0 matched"
    assert html =~ ~s(data-rules-state="not_recorded")
  end

  test "a later rule change does not rewrite the recorded explanation" do
    {entry, episode} = admitted!()
    inventory!(entry, [rule("Review Terraform plans", "matched", "A terraform plan from app.")])

    # A rule renamed, paused or deleted today must leave the old card alone;
    # the card reads only its own frozen entries.
    before = rendered(episode)

    Repo.update_all(
      from(row in StandingRuleInventory,
        where: row.source_input_ref == ^"ingress-input:#{entry.id}"
      ),
      set: [rule_count: 1]
    )

    assert rendered(episode) == before
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

  defp inventory!(entry, entries) do
    Repo.insert!(%StandingRuleInventory{
      id: Ecto.UUID.generate(),
      source_input_ref: "ingress-input:#{entry.id}",
      source_event_ref: entry.event_ref,
      workspace_ref: "slack:TC9F5B40D364C",
      conversation_ref: "slack:TC9F5B40D364C:C456",
      rule_count: length(entries),
      matched_count: Enum.count(entries, &(&1["verdict"] == "matched")),
      truncated: false,
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

  defp admitted! do
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

    {:ok, %{entry: entry}} = Inbox.record(input)
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
