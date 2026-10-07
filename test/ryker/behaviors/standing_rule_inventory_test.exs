defmodule Ryker.Behaviors.StandingRuleInventoryTest do
  @moduledoc """
  The complete standing-rule inventory at processing time.

  Only matches were stored, so "three rules existed and none matched" and
  "nobody evaluated any rules" read identically, and the two send an operator
  in opposite directions. Recording the whole inventory is observation, and
  observation that changes execution is not observation: none of these tests
  may move a rule into or out of scheduling, and none may fail an input.
  """
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Behaviors
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.StandingAssignmentRun
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Input
  alias Ryker.Inspectors
  alias Ryker.Records.Record
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Custody

  # An hour before this file compiles, which is every test run: in the past, as
  # a confirmation is, but never a fixed date. Rules confirmed at a fixed
  # 2026-09-04 22:51:44 expire 30 days later and the runtime reads the database
  # clock, so from 2026-10-04 22:51 UTC every rule here would have read as
  # expired and six of these tests would have failed, as thirty others did when
  # their fixed 2026-08-28 confirmations expired on 2026-09-27.
  @now DateTime.utc_now()
       |> DateTime.add(-3_600, :second)
       |> DateTime.truncate(:second)
       |> Map.put(:microsecond, {0, 6})
  @conversation "slack:T123:C456"
  @workspace "slack:T123"

  test "every workspace rule is listed with the verdict it actually got, matches first-class" do
    offers = offer_source!("verdicts")
    matched = rule!(offers, "matched")
    other_filter = rule!(offers, "deployment", filter: %{"bot_id" => "B-DEPLOY"})
    other_channel = rule!(offers, "elsewhere", scope_ref: "slack:T123:C999")
    paused = rule!(offers, "paused", status: :disabled)

    expired =
      rule!(offers, "expired",
        confirmed_at: DateTime.add(@now, -10, :day),
        expires_at: DateTime.add(@now, -1, :day)
      )

    input = terraform_input(:app)
    assert {:ok, inventory} = Behaviors.record_rule_inventory(input, "input:verdicts")

    assert inventory.rule_count == 5
    assert inventory.matched_count == 1

    verdicts = Map.new(inventory.entries, &{&1["ref"], {&1["verdict"], &1["reason"]}})
    assert {"matched", reason} = verdicts[matched.ref]
    assert reason == "The recorded source and event filter matched this message."
    assert {"not_matched", reason} = verdicts[other_filter.ref]
    assert reason == "The recorded source and event filter did not match this message."
    assert {"out_of_scope", reason} = verdicts[other_channel.ref]
    assert reason == "This rule applies to another channel."
    refute reason =~ "slack:"

    # Another channel's rule is a reason, not a copy: its title, channel and
    # filter stay with the rule, so deleting that channel leaves none of its
    # words in this message's history (2026-10-04 review).
    elsewhere = Enum.find(inventory.entries, &(&1["ref"] == other_channel.ref))
    assert elsewhere |> Map.keys() |> Enum.sort() == ~w(reason ref revision status verdict)
    assert {"disabled", reason} = verdicts[paused.ref]
    assert reason == "This rule was paused when the message was processed."
    assert {"expired", "This rule expired before the message arrived."} = verdicts[expired.ref]

    # Definitions are frozen with the verdict so a later edit cannot rewrite it.
    assert Enum.all?(inventory.entries, &is_integer(&1["revision"]))
  end

  test "a verdict keeps what the rule looked for and what the message showed" do
    # The inventory said "matched" or "did not match" and nothing else, so an
    # operator could not tell whether the source, the filter or the channel
    # decided it. Each condition's result is frozen with the verdict.
    offers = offer_source!("evidence")
    plan = rule!(offers, "plan")
    deploy = rule!(offers, "deploy", filter: %{"bot_id" => "B-DEPLOY"})
    github = rule!(offers, "github", source_kind: "github")
    paused = rule!(offers, "paused", status: :disabled)

    assert {:ok, inventory} =
             Behaviors.record_rule_inventory(terraform_input(:app), "input:evidence")

    entries = Map.new(inventory.entries, &{&1["ref"], &1})

    assert entries[plan.ref]["verdict"] == "matched"

    assert entries[plan.ref]["criteria"] == %{
             "filter" => %{"bot_id" => "B-TERRAFORM"},
             "source_kind" => "slack"
           }

    assert entries[plan.ref]["evidence"] == %{
             "filter_matches" => true,
             "source_kind" => "slack",
             "source_matches" => true
           }

    # The filter decided this one; the source decided the next.
    assert entries[deploy.ref]["verdict"] == "not_matched"
    assert entries[deploy.ref]["evidence"]["source_matches"]
    refute entries[deploy.ref]["evidence"]["filter_matches"]

    assert entries[github.ref]["verdict"] == "not_matched"
    refute entries[github.ref]["evidence"]["source_matches"]
    assert entries[github.ref]["evidence"]["filter_matches"]

    # A rule that was never checked has criteria but no evidence.
    assert entries[paused.ref]["criteria"]["source_kind"] == "slack"
    assert entries[paused.ref]["evidence"] == nil
  end

  test "recording the inventory changes nothing about which rules fire" do
    offers = offer_source!("scheduling")
    matched = rule!(offers, "fires")
    _other = rule!(offers, "elsewhere", scope_ref: "slack:T123:C999")
    _paused = rule!(offers, "paused", status: :disabled)

    input = terraform_input(:app)
    assert Behaviors.standing_match?(input)
    assert {:ok, 1} = Behaviors.observe_input(input, "input:scheduling")
    assert {:ok, inventory} = Behaviors.record_rule_inventory(input, "input:scheduling")

    # The inventory lists the out-of-scope and paused rules; scheduling did not.
    assert inventory.rule_count == 3
    runs = Repo.all(from(run in StandingAssignmentRun, select: run.assignment_id))
    assert runs == [matched.id]

    # And recording it again has not created a second opinion.
    assert {:ok, 1} = Behaviors.observe_input(input, "input:scheduling")
    assert Repo.aggregate(StandingRuleInventory, :count) == 1
  end

  test "a matching rule outside the runtime's candidate window is not credited with a match" do
    # The runtime evaluates the first hundred candidate rules for a
    # conversation. A rule beyond that window never had its trigger checked, so
    # calling it "matched" would explain an engagement it could not have caused.
    offers = offer_source!("window")

    rules =
      for index <- 1..205,
          do: rule!(offers, "window-#{String.pad_leading("#{index}", 3, "0")}")

    input = terraform_input(:app)
    assert {:ok, inventory} = Behaviors.record_rule_inventory(input, "input:window")

    assert inventory.rule_count == 205
    assert inventory.matched_count == 100
    assert length(inventory.entries) == 205

    last = List.last(rules)
    entry = Enum.find(inventory.entries, &(&1["ref"] == last.ref))
    assert entry["verdict"] == "not_considered"

    assert entry["reason"] ==
             "Only the first 100 applicable rules are evaluated. This rule's trigger was not checked."

    # Scheduling is unchanged: still exactly the hundred the runtime considered.
    assert {:ok, 100} = Behaviors.observe_input(input, "input:window")
  end

  test "an inventory that cannot be written does not fail the input" do
    offers = offer_source!("failure")
    _rule = rule!(offers, "fires")

    # Break only the evidence table; input custody and scheduling are untouched.
    Repo.query!(
      "ALTER TABLE standing_rule_inventories RENAME TO standing_rule_inventories_broken"
    )

    input = terraform_input(:app)
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    assert entry.id
    assert {:ok, 1} = Behaviors.observe_input(input, "ingress-input:#{entry.id}")

    assert {:error, {:standing_rule_inventory_failed, _reason}} =
             Behaviors.record_rule_inventory(input, "ingress-input:#{entry.id}")

    Repo.query!(
      "ALTER TABLE standing_rule_inventories_broken RENAME TO standing_rule_inventories"
    )

    assert Inspectors.rule_inventory("ingress-input:#{entry.id}") == nil
  end

  test "accepting an input records its inventory after custody commits" do
    offers = offer_source!("accepted")
    _rule = rule!(offers, "fires")

    assert {:ok, %{entry: entry}} = Inbox.record(terraform_input(:app))
    inventory = Inspectors.rule_inventory("ingress-input:#{entry.id}")
    assert %StandingRuleInventory{matched_count: 1, rule_count: 1} = inventory

    # Redelivery of the same input does not multiply the evidence.
    assert {:ok, _again} = Inbox.record(terraform_input(:app))
    assert Repo.aggregate(StandingRuleInventory, :count) == 1
  end

  # Every redelivery read the workspace's rules again and wrote an inventory
  # the first delivery had already written (2026-10-04 review).
  test "a redelivered message does not take its rule inventory again" do
    offers = offer_source!("redelivered")
    _rule = rule!(offers, "fires")

    assert {:ok, %{entry: entry}} = Inbox.record(terraform_input(:app))
    assert %StandingRuleInventory{} = Inspectors.rule_inventory("ingress-input:#{entry.id}")

    assert {{:ok, %{status: :duplicate}}, 0} =
             inventory_queries(fn -> Inbox.record(terraform_input(:app)) end)
  end

  test "a workspace with no rules records an empty inventory, which is not an absent one" do
    input = terraform_input(:app)
    assert {:ok, inventory} = Behaviors.record_rule_inventory(input, "input:empty")
    assert inventory.rule_count == 0
    assert inventory.entries == []
    assert Inspectors.rule_inventory("input:empty").rule_count == 0
    assert Inspectors.rule_inventory("input:never-recorded") == nil
  end

  test "malformed references are refused without touching the database" do
    assert {:error, _reason} = Behaviors.record_rule_inventory(terraform_input(:app), "")
    assert {:error, _reason} = Behaviors.record_rule_inventory(%{}, "input:x")
    assert Repo.aggregate(StandingRuleInventory, :count) == 0
  end

  defp terraform_input(actor_kind) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: actor_kind, ref: "B-terraform"},
        channel_ref: "C456",
        content: terraform_content(actor_kind),
        event_kind: :message,
        event_ref: "Ev-inventory-#{actor_kind}",
        # A Slack message's ts is the moment it was sent.
        message_ref: "#{DateTime.to_unix(@now)}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    %Input{} = input
    input
  end

  # The Terraform app posts its plans as itself; a person pasting one does not.
  defp terraform_content(:app),
    do: Map.put(terraform_content(:user), "bot_id", "B-TERRAFORM")

  defp terraform_content(_kind),
    do: %{"text" => "Terraform plan: 2 to add, 1 to change, 0 to destroy"}

  # One episode/turn to own the offer records every rule must point back to.
  defp offer_source!(suffix) do
    episode_id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{conversation_ref: @conversation, thread_ref: nil, transport: "slack"},
          episode_id: episode_id,
          episode_key: "rule-inventory:#{suffix}:#{episode_id}",
          native_input_id: "source:#{suffix}:#{episode_id}",
          occurred_at: @now,
          turn_ref: "turn:#{suffix}:#{episode_id}"
        })
      )

    {:ok, _session} = WorkSessions.pin_episode(episode_id, "inventory", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("inventory:#{suffix}", 60, :work)
    %{episode_id: episode_id, turn_id: claim.turn.id}
  end

  defp rule!(offers, name, options \\ []) do
    payload = %{
      "context_channel" => @conversation,
      "delivery_channel" => @conversation,
      "expires_at" => nil,
      "filter" => Keyword.get(options, :filter, %{"bot_id" => "B-TERRAFORM"}),
      "hold" => nil,
      "repository" => nil,
      "source_kind" => Keyword.get(options, :source_kind, "slack"),
      "task" => "Review #{name}.",
      "title" => "Review #{name}"
    }

    record =
      Repo.insert!(%Record{
        id: Ecto.UUID.generate(),
        episode_id: offers.episode_id,
        turn_id: offers.turn_id,
        ref: "record:#{name}:#{Ecto.UUID.generate()}",
        operation_id: "offer-#{name}",
        kind: "standing_assignment_offer",
        status: :confirmed,
        payload: payload,
        payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
        confirmation_ref: "confirmation:#{name}",
        confirmed_by_actor_ref: "slack:user:U1",
        confirmed_at: @now,
        inserted_at: @now
      })

    {:ok, behavior} =
      %{
        confirmed_at: Keyword.get(options, :confirmed_at, @now),
        confirmed_by_actor_ref: "slack:user:U1",
        confirmation_ref: "confirmation:#{name}:#{record.id}",
        expires_at: Keyword.get(options, :expires_at, DateTime.add(@now, 30, :day)),
        id: Ecto.UUID.generate(),
        identity_key: "assignment:#{name}:#{record.id}",
        kind: :standing_assignment,
        offer_record_id: record.id,
        payload: payload,
        ref: "behavior:#{name}:#{record.id}",
        scope_kind: :conversation,
        scope_ref: Keyword.get(options, :scope_ref, @conversation),
        source_conversation_ref: @conversation,
        source_message_ref: "1787832001.000200",
        source_thread_ref: nil,
        source_transport: "slack",
        status: Keyword.get(options, :status, :active),
        workspace_ref: @workspace
      }
      |> Behavior.Changeset.insert()
      |> Repo.insert()

    %Behavior{} = behavior
  end

  # What `fun` answers, and how many statements it sent about rule inventories.
  defp inventory_queries(fun) do
    reference = make_ref()
    owner = self()

    :ok =
      :telemetry.attach(
        reference,
        [:ryker, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == owner and String.contains?(query, "standing_rule_inventories"),
            do: send(owner, reference)
        end,
        nil
      )

    try do
      {fun.(), drain(reference, 0)}
    after
      :telemetry.detach(reference)
    end
  end

  defp drain(reference, count) do
    receive do
      ^reference -> drain(reference, count + 1)
    after
      0 -> count
    end
  end
end
