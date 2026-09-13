defmodule Ryker.State.BehaviorsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{BehaviorLibrary, Projection, Router}
  alias Ryker.Episodes
  alias Ryker.Fixtures.DatabaseClock
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Slack.{AppHomeProjection, Event, Renderer, ReplyRecords}

  alias Ryker.State.{
    Behavior,
    BehaviorChangeset,
    Behaviors,
    Record,
    RecordPayload,
    Records,
    StandingAssignmentRun
  }

  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "confirmed guidance is immediately searchable when the database clock trails the host" do
    # Two full-gate guidance searches returned [] immediately after successful
    # confirmation: host-generated insertion times exceeded the database cursor
    # cutoff. Model text and historical confirmation time are not the failure.
    fixture = delivered_offers!("database-clock-guidance")
    database_time = DatabaseClock.behind_host!()

    assert {:ok, confirmed} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "database-clock"))

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:U123",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [searched] =
             Behaviors.search_guidance(context, "availability risk", "current_channel", 20)

    assert searched["behavior_ref"] == confirmed.behavior.ref
    assert confirmed.behavior.inserted_at == database_time
    assert confirmed.behavior.confirmed_at == @now
  end

  test "visible instructions remain actionable beyond the memory listing limit" do
    # Paused instructions do not consume active capacity. A capped listing must
    # not strand their lifecycle controls when the library has more history.
    fixture = delivered_offers!("older-ui-actions")
    {:ok, confirmed} = Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance"))

    # This is deliberately older history. Confirmation uses the database clock;
    # comparing it with bulk fixtures stamped by the host made this ordering
    # depend on machine clock skew and put the target back on the first page.
    Repo.update_all(from(b in Behavior, where: b.id == ^confirmed.behavior.id),
      set: [updated_at: DateTime.add(confirmed.behavior.updated_at, -86_400, :second)]
    )

    insert_unrelated_guidance!(fixture.guidance, 500)

    Repo.update_all(from(b in Behavior, where: b.id != ^confirmed.behavior.id),
      set: [status: :disabled]
    )

    refute Enum.any?(Projection.memory().behaviors, &(&1.ref == confirmed.behavior.ref))

    assert Enum.any?(
             BehaviorLibrary.list(:guidance, %{"page" => "21"}).items,
             &(&1.ref == confirmed.behavior.ref)
           )

    options =
      Router.init(%{
        actions: %{},
        observability: %{},
        projection: Projection.callbacks(),
        csrf_secret: String.duplicate("x", 32)
      })

    path = "/actions/behavior/#{URI.encode_www_form(confirmed.behavior.ref)}/disabled"

    response =
      Plug.Test.conn(:get, path)
      |> Map.put(:host, "localhost")
      |> Router.call(options)

    assert response.status == 200
    assert response.resp_body =~ "href=\"/guidance\""

    confirmed.behavior
    |> BehaviorChangeset.update(%{expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    response =
      Plug.Test.conn(:get, path)
      |> Map.put(:host, "localhost")
      |> Router.call(options)

    assert response.status == 404
  end

  test "valid expanding event conditions cannot break the instruction library" do
    # A small valid JSON filter can exceed the inspector display limit after
    # indentation. One such confirmed rule must not take down the whole page.
    fixture = delivered_offers!("expanding-ui-filter")

    {:ok, confirmed} =
      Behaviors.confirm(confirmation(fixture, fixture.source_event_assignment, "rule"))

    filter =
      Enum.reduce(1..29, List.duplicate(0, 8_500), fn _, nested -> %{"nested" => nested} end)

    payload = Map.put(confirmed.behavior.payload, "filter", filter)

    assert {:ok, _} =
             RecordPayload.prepare(
               "standing_assignment_offer",
               payload,
               "record:filter"
             )

    confirmed.behavior |> BehaviorChangeset.update(%{payload: payload}) |> Repo.update!()

    assert %{items: [item]} =
             BehaviorLibrary.list(:standing_assignment, %{})

    assert item.payload["title"] == payload["title"]

    assert item.payload["filter"] ==
             "Too large to display. Open the original conversation to inspect these conditions."
  end

  test "indefinite behaviors remain visible and manageable in the control plane" do
    # Indefinite standing rules worked at runtime but disappeared from the UI,
    # making operators believe the feature had been removed.
    fixture = delivered_offers!("indefinite-ui")
    {:ok, confirmed} = Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance"))
    confirmed.behavior |> BehaviorChangeset.update(%{expires_at: nil}) |> Repo.update!()

    assert Enum.any?(
             Projection.memory().behaviors,
             &(&1.ref == confirmed.behavior.ref)
           )
  end

  test "the instruction library separates kinds expiry scopes and history without mutating them" do
    fixture = delivered_offers!("instruction-library")

    {:ok, rule} =
      Behaviors.confirm(confirmation(fixture, fixture.source_event_assignment, "rule"))

    {:ok, preference} =
      Behaviors.confirm(confirmation(fixture, fixture.workspace_preference, "preference"))

    {:ok, guidance} = Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance"))
    {:ok, _paused} = Behaviors.set_status(preference.behavior.ref, :disabled)

    guidance.behavior
    |> BehaviorChangeset.update(%{expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    assert {:ok, 1} =
             Behaviors.observe_input(
               github_review_input("slack:T123:C456", "submitted", "changes_requested"),
               "input:library"
             )

    assert %{items: [item], runs: [run], counts: %{"active" => 1}} =
             BehaviorLibrary.list(:standing_assignment, %{})

    assert item.ref == rule.behavior.ref
    assert run.rule_ref == item.ref
    assert run.outcome == :pending
    assert item.payload["filter"] != nil
    assert BehaviorLibrary.list(:standing_assignment, %{"scope" => "repository"}).items == []
    assert BehaviorLibrary.list(:standing_assignment, %{"q" => "%"}).items == []
    assert BehaviorLibrary.list(:standing_assignment, %{"q" => "github"}).total == 1

    assert BehaviorLibrary.list(:standing_assignment, %{"status" => "nonsense", "page" => "-20"}).page ==
             1

    assert BehaviorLibrary.list(:standing_assignment, %{"page" => "oops"}).page == 1
    assert BehaviorLibrary.list(:standing_assignment, %{"status" => "archived"}).items == []
    assert %{items: [%{status: "disabled"}]} = BehaviorLibrary.list(:preference, %{})
    assert %{items: [], counts: %{"expired" => 1}} = BehaviorLibrary.list(:guidance, %{})

    assert %{items: [%{status: "expired"}]} =
             BehaviorLibrary.list(:guidance, %{"status" => "expired"})

    assert %{items: [%{status: "expired"}]} =
             BehaviorLibrary.list(:guidance, %{"status" => "all"})

    assert Repo.get!(Behavior, guidance.behavior.id).status == :active

    insert_unrelated_guidance!(fixture.guidance, 27)
    first = BehaviorLibrary.list(:guidance, %{})
    second = BehaviorLibrary.list(:guidance, %{"page" => "2"})
    assert first.total == 27
    assert length(first.items) == 25
    assert length(second.items) == 2
    assert MapSet.disjoint?(MapSet.new(first.items, & &1.ref), MapSet.new(second.items, & &1.ref))
  end

  test "operator-confirmed preferences and guidance resolve by exact scope and precedence" do
    fixture = delivered_offers!("memory")

    assert {:ok, workspace} =
             Behaviors.confirm(confirmation(fixture, fixture.workspace_preference, "workspace"))

    assert workspace.status == :confirmed
    assert workspace.behavior.kind == :preference
    assert workspace.behavior.scope_kind == :workspace
    assert workspace.behavior.scope_ref == "slack:T123"

    assert {:ok, operator} =
             Behaviors.confirm(confirmation(fixture, fixture.operator_preference, "operator"))

    assert operator.behavior.scope_kind == :operator
    assert operator.behavior.scope_ref == "slack:user:U123"

    assert {:ok, guidance} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance"))

    assert guidance.behavior.kind == :guidance
    assert guidance.behavior.scope_kind == :conversation

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:U123",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert Behaviors.effective_preferences(context) == %{
             "response_detail" => %{
               "behavior_ref" => operator.behavior.ref,
               "scope" => "operator",
               "value" => "detailed"
             }
           }

    assert [recalled] = Behaviors.guidance(context)
    assert recalled["behavior_ref"] == guidance.behavior.ref
    assert recalled["subject"] == "terraform_review_style"
    assert recalled["text"] =~ "availability risk"

    assert [searched] =
             Behaviors.search_guidance(context, "availability risk", "current_channel", 20)

    assert searched["behavior_ref"] == guidance.behavior.ref
    assert Behaviors.search_guidance(context, "availability risk", "invalid", 20) == []

    other_conversation = %{context | conversation_ref: "slack:T123:C999"}
    assert Behaviors.guidance(other_conversation) == []

    assert {:ok, duplicate} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance-retry"))

    assert duplicate.status == :duplicate
    assert duplicate.behavior.id == guidance.behavior.id
    assert Repo.aggregate(Behavior, :count, :id) == 3
  end

  test "App Home behavior controls cannot cross channel or operator scope" do
    fixture = delivered_offers!("home-behavior-privacy")

    assert {:ok, workspace} =
             Behaviors.confirm(confirmation(fixture, fixture.workspace_preference, "workspace"))

    assert {:ok, operator} =
             Behaviors.confirm(confirmation(fixture, fixture.operator_preference, "operator"))

    assert {:ok, conversation} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "conversation"))

    snapshot = AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"]))
    assert snapshot.counts.active_behaviors == 2

    assert Enum.any?(snapshot.behaviors, fn row ->
             row.ref == workspace.behavior.ref and
               row.url ==
                 "https://slack.com/app_redirect?team=T123&channel=C456&message_ts=1787832000.000100"
           end)

    assert Enum.any?(snapshot.behaviors, &(&1.ref == operator.behavior.ref))
    refute Enum.any?(snapshot.behaviors, &(&1.ref == conversation.behavior.ref))

    assert Behaviors.set_home_status(
             conversation.behavior.ref,
             :deleted,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :behavior_unauthorized}

    assert {:ok, disabled_receipt} =
             Behaviors.set_home_status(
               workspace.behavior.ref,
               :disabled,
               workspace.behavior.revision,
               "slack:user:U123",
               "slack:T123",
               "interaction:behavior:disable"
             )

    assert disabled_receipt.status == :recorded
    assert disabled_receipt.outcome["status"] == "disabled"

    disabled = Repo.get!(Behavior, workspace.behavior.id)

    assert {:ok, enabled_receipt} =
             Behaviors.set_home_status(
               workspace.behavior.ref,
               :active,
               disabled.revision,
               "slack:user:U123",
               "slack:T123",
               "interaction:behavior:enable"
             )

    assert enabled_receipt.status == :recorded
    assert enabled_receipt.outcome["status"] == "active"

    assert {:ok, duplicate} =
             Behaviors.set_home_status(
               workspace.behavior.ref,
               :disabled,
               workspace.behavior.revision,
               "slack:user:U123",
               "slack:T123",
               "interaction:behavior:disable"
             )

    assert duplicate.status == :duplicate
    assert Repo.get!(Behavior, workspace.behavior.id).status == :active

    assert Behaviors.set_home_status(
             operator.behavior.ref,
             :disabled,
             "slack:user:U999",
             "slack:T123"
           ) == {:error, :behavior_unauthorized}

    assert {:ok, own} =
             Behaviors.set_home_status(
               operator.behavior.ref,
               :disabled,
               "slack:user:U123",
               "slack:T123"
             )

    assert own.status == :disabled

    assert {:ok, shared} =
             Behaviors.set_home_status(
               workspace.behavior.ref,
               :disabled,
               "slack:user:U999",
               "slack:T123"
             )

    assert shared.status == :disabled

    assert Behaviors.set_home_status(
             workspace.behavior.ref,
             :active,
             "slack:user:U123",
             "slack:T999"
           ) == {:error, :behavior_workspace_mismatch}

    assert Behaviors.set_home_status(
             "behavior:missing",
             :active,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :behavior_not_found}
  end

  test "unrelated newer behaviors cannot crowd visible guidance out of the bounded query" do
    fixture = delivered_offers!("scope-before-limit")

    assert {:ok, relevant} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "scope-before-limit"))

    old = DateTime.add(DateTime.utc_now(), -60, :second)
    Repo.update_all(Behavior, set: [inserted_at: old, updated_at: old])
    insert_unrelated_guidance!(fixture.guidance, 100)

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:U123",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [guidance] = Behaviors.guidance(context)
    assert guidance["behavior_ref"] == relevant.behavior.ref
  end

  test "workspace guidance cannot crowd higher-precedence channel guidance out of the limit" do
    fixture = delivered_offers!("precedence-before-limit")

    assert {:ok, relevant} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "precedence-before-limit"))

    old = DateTime.add(DateTime.utc_now(), -60, :second)
    Repo.update_all(Behavior, set: [inserted_at: old, updated_at: old])
    insert_unrelated_guidance!(fixture.guidance, 100)

    workspace_payload = %{
      "expires_in" => "30d",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => "workspace-guidance",
      "summary" => "Newer workspace guidance",
      "text" => "Newer workspace guidance",
      "visibility" => "workspace"
    }

    Repo.update_all(
      from(behavior in Behavior, where: behavior.id != ^relevant.behavior.id),
      set: [payload: workspace_payload, scope_kind: :workspace, scope_ref: "slack:T123"]
    )

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:U123",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [first | _rest] = Behaviors.guidance(context)
    assert first["behavior_ref"] == relevant.behavior.ref
  end

  test "conversation-visible repository guidance stays in its source channel" do
    fixture = delivered_offers!("repository-guidance-visibility")

    assert {:ok, confirmed} =
             Behaviors.confirm(
               confirmation(fixture, fixture.guidance, "repository-guidance-visibility")
             )

    payload =
      confirmed.behavior.payload
      |> Map.put("repository", "ryker")
      |> Map.put("scope", "repository")
      |> Map.put("visibility", "conversation")

    confirmed.behavior
    |> BehaviorChangeset.update(%{
      payload: payload,
      scope_kind: :repository,
      scope_ref: "ryker"
    })
    |> Repo.update!()

    source_context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:U123",
      repository: "ryker",
      workspace_ref: "slack:T123"
    }

    assert [guidance] = Behaviors.guidance(source_context)
    assert guidance["behavior_ref"] == confirmed.behavior.ref

    assert [searched] =
             Behaviors.search_guidance(source_context, "availability", "repository", 20)

    assert searched["behavior_ref"] == confirmed.behavior.ref
    assert Behaviors.guidance(%{source_context | conversation_ref: "slack:T123:C999"}) == []
  end

  test "a confirmed standing assignment admits only its exact source, channel, and event family" do
    fixture = delivered_offers!("assignment")

    assert {:ok, confirmed} =
             Behaviors.confirm(confirmation(fixture, fixture.assignment, "assignment"))

    assert confirmed.behavior.kind == :standing_assignment
    assert confirmed.behavior.scope_ref == "slack:T123:C456"

    assert Behaviors.standing_match?(terraform_input(:app, "slack:T123:C456"))
    refute Behaviors.standing_match?(terraform_input(:user, "slack:T123:C456"))
    refute Behaviors.standing_match?(terraform_input(:app, "slack:T123:C999"))
    refute Behaviors.standing_match?(deployment_input())

    assert Behaviors.set_status(confirmed.behavior.ref, :disabled, "slack:T999") ==
             {:error, :behavior_workspace_mismatch}

    assert Repo.get!(Behavior, confirmed.behavior.id).status == :active

    assert {:ok, disabled} =
             Behaviors.set_status(confirmed.behavior.ref, :disabled, "slack:T123")

    assert disabled.status == :disabled
    assert disabled.revision == confirmed.behavior.revision + 1

    assert {:ok, unchanged} =
             Behaviors.set_status(confirmed.behavior.ref, :disabled, "slack:T123")

    assert unchanged.revision == disabled.revision
    refute Behaviors.standing_match?(terraform_input(:app, "slack:T123:C456"))

    assert {:ok, active} = Behaviors.set_status(confirmed.behavior.ref, :active, "slack:T123")
    assert active.status == :active
    assert active.revision == disabled.revision + 1
    assert Behaviors.standing_match?(terraform_input(:app, "slack:T123:C456"))

    assert {:ok, deleted} = Behaviors.set_status(confirmed.behavior.ref, :deleted, "slack:T123")
    assert deleted.status == :deleted
    assert deleted.revision == active.revision + 1

    assert Behaviors.set_status(confirmed.behavior.ref, :active, "slack:T123") ==
             {:error, :behavior_terminal}
  end

  test "a confirmed source-event automation matches only the exact adapter content filter" do
    fixture = delivered_offers!("source-event-assignment")

    assert {:ok, confirmed} =
             Behaviors.confirm(
               confirmation(fixture, fixture.source_event_assignment, "source-event-assignment")
             )

    assert confirmed.behavior.kind == :standing_assignment
    assert confirmed.behavior.expires_at == nil

    assert Behaviors.standing_match?(
             github_review_input("slack:T123:C456", "submitted", "changes_requested")
           )

    refute Behaviors.standing_match?(
             github_review_input("slack:T123:C456", "submitted", "approved")
           )

    refute Behaviors.standing_match?(
             github_review_input("slack:T123:C456", "edited", "changes_requested")
           )

    refute Behaviors.standing_match?(
             github_review_input("slack:T123:C999", "submitted", "changes_requested")
           )
  end

  test "attachment-only Terraform automation matches its run and excludes other bots and conversations" do
    # The live confirmed rule missed a newer deployment. A broad bot-message
    # filter would wake it for unrelated apps instead of fixing that omission.
    fixture = delivered_offers!("terraform-bot-filter")

    assert {:ok, confirmed} =
             Behaviors.confirm(
               confirmation(fixture, fixture.source_event_assignment, "terraform-bot-filter")
             )

    message =
      "testdata/slack/hcp-terraform-planning.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("channel", "C456")

    run = message["attachments"] |> hd() |> Map.take(["title", "title_link"])

    payload =
      confirmed.behavior.payload
      |> Map.put("source_kind", "slack")
      |> Map.put("filter", %{"bot_id" => message["bot_id"], "attachments" => [run]})

    confirmed.behavior |> BehaviorChangeset.update(%{payload: payload}) |> Repo.update!()

    normalize = fn event ->
      envelope = %{
        "type" => "events_api",
        "payload" => %{
          "type" => "event_callback",
          "team_id" => "T123",
          "event_id" => "Ev-terraform-bot-filter",
          "event" => event
        }
      }

      {:ok, %{input: input}} =
        Event.from_socket(envelope, %{
          workspace_ref: "T123",
          bot_ref: "B-RYKER",
          bot_user_ref: "U-RYKER"
        })

      input
    end

    assert Behaviors.standing_match?(normalize.(message))
    refute Behaviors.standing_match?(normalize.(Map.put(message, "bot_id", "B-OTHER")))
    refute Behaviors.standing_match?(normalize.(Map.put(message, "channel", "C999")))

    other_run = Map.put(message, "attachments", [%{run | "title" => "Run another-run"}])
    refute Behaviors.standing_match?(normalize.(other_run))

    human = message |> Map.delete("bot_id") |> Map.put("user", "U123")
    refute Behaviors.standing_match?(normalize.(human))
  end

  test "assignment controls are fenced to the exact workspace and conversation" do
    fixture = delivered_offers!("assignment-control")

    assert {:ok, assignment} =
             Behaviors.confirm(confirmation(fixture, fixture.assignment, "assignment-control"))

    assert {:ok, preference} =
             Behaviors.confirm(
               confirmation(fixture, fixture.workspace_preference, "preference-control")
             )

    assert [listed] = Behaviors.assignments_for_channel("slack:T123", "slack:T123:C456")
    assert listed.ref == assignment.behavior.ref

    assert {:ok, paused} =
             Behaviors.manage_assignment(
               assignment.behavior.ref,
               :disabled,
               "slack:T123",
               "slack:T123:C456"
             )

    assert paused.status == :disabled

    assert Behaviors.manage_assignment(
             assignment.behavior.ref,
             :active,
             "slack:T999",
             "slack:T123:C456"
           ) == {:error, :assignment_scope_mismatch}

    assert Behaviors.manage_assignment(
             assignment.behavior.ref,
             :active,
             "slack:T123",
             "slack:T123:C999"
           ) == {:error, :assignment_scope_mismatch}

    assert Behaviors.manage_assignment(
             preference.behavior.ref,
             :disabled,
             "slack:T123",
             "slack:T123:C456"
           ) == {:error, :assignment_scope_mismatch}

    assert {:ok, resumed} =
             Behaviors.manage_assignment(
               assignment.behavior.ref,
               :active,
               "slack:T123",
               "slack:T123:C456"
             )

    assert resumed.status == :active
  end

  test "guidance saved from a joined input's origin thread records the thread it was saved in" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    fixture = delivered_offers!("routed", "1787832500.000700")

    assert fixture.episode.destination_thread_ref == "1787832000.000100"
    assert fixture.receipt["thread_ref"] == "1787832500.000700"

    assert {:ok, confirmed} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "routed"))

    assert confirmed.status == :confirmed

    # Guidance's source is the card it was saved from, so the recorded thread
    # has to be the one holding the recorded message.
    assert confirmed.behavior.source_thread_ref == "1787832500.000700"
    assert confirmed.behavior.source_message_ref == fixture.receipt["message_ref"]
  end

  # The preference delete dialog existed only as a hand-written Card Lab
  # specimen, and it is the last thing an operator reads before a destructive
  # press: it has to name this preference, say what stops and say what survives.
  # A card state nobody drives from a real record is a claim, not a fact — the
  # 2026-09-12 audit found one such claim ("the parked state clears native
  # activity") was false, and a thread had been told "is working..." every 90
  # seconds ever since.
  test "deleting a saved preference is confirmed against that preference by name" do
    fixture = delivered_offers!("preference-delete-dialog")

    assert {:ok, confirmed} =
             Behaviors.confirm(
               confirmation(fixture, fixture.workspace_preference, "preference-delete")
             )

    behavior = confirmed.behavior
    record = Repo.get!(Record, fixture.workspace_preference.id)

    assert [document] = ReplyRecords.documents("slack", fixture.episode.id, [record])
    assert %{"presentation" => %{"entity" => entity}} = document
    assert entity["kind"] == "preference"
    assert entity["title"] == "response_detail"
    assert entity["instructions"] == "response_detail = standard"
    assert ["Scope", "Whole workspace"] in entity["facts"]

    assert {:ok, rendered} = Renderer.render(%{"message" => "Saved.", "records" => [document]})

    assert [delete] = List.last(rendered["blocks"])["elements"]
    assert delete["action_id"] == "ryker_delete_behavior"
    assert delete["style"] == "danger"
    assert delete["value"] == "behavior-control:#{behavior.ref}:1"
    assert delete["text"]["text"] == "Delete preference"
    assert delete["confirm"]["title"]["text"] == "Delete preference?"

    assert delete["confirm"]["text"]["text"] ==
             "Stop applying “response_detail”. Replies I already sent stay as they are."

    assert delete["confirm"]["confirm"]["text"] == "Delete preference"
    assert delete["confirm"]["deny"]["text"] == "Cancel"

    # A paused preference is still removable, and the control follows its
    # revision. The notice keeps naming the save event while the entity is
    # live, so the pause is carried by the status, not by the headline.
    assert {:ok, disabled} = Behaviors.set_status(behavior.ref, :disabled, "slack:T123")
    assert [paused_document] = ReplyRecords.documents("slack", fixture.episode.id, [record])
    assert paused_document["presentation"]["entity"]["status"] == "disabled"
    assert paused_document["presentation"]["entity"]["removable"] == true
    assert paused_document["presentation"]["entity"]["notice"] == "Preference saved"

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Saved.", "records" => [paused_document]})

    assert [paused_delete] = List.last(rendered["blocks"])["elements"]
    assert paused_delete["value"] == "behavior-control:#{behavior.ref}:#{disabled.revision}"
    assert paused_delete["confirm"]["title"]["text"] == "Delete preference?"

    # Once it is gone there is nothing left to confirm.
    assert {:ok, _deleted} = Behaviors.set_status(behavior.ref, :deleted, "slack:T123")
    assert [deleted_document] = ReplyRecords.documents("slack", fixture.episode.id, [record])

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Saved.", "records" => [deleted_document]})

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
    assert inspect(rendered) =~ "Preference deleted"
  end

  # Same gap for guidance, whose dialog has to promise something different:
  # deleting guidance stops Ryker following it, and changes nothing it has
  # already said.
  test "deleting saved guidance is confirmed against that guidance by name" do
    fixture = delivered_offers!("guidance-delete-dialog")

    assert {:ok, confirmed} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "guidance-delete"))

    behavior = confirmed.behavior
    record = Repo.get!(Record, fixture.guidance.id)

    assert [document] = ReplyRecords.documents("slack", fixture.episode.id, [record])
    assert %{"presentation" => %{"entity" => entity}} = document
    assert entity["kind"] == "guidance"
    assert entity["title"] == "terraform_review_style"
    assert entity["instructions"] =~ "lead with availability risk and drift"
    assert ["Scope", "This conversation"] in entity["facts"]
    assert ["Visibility", "This conversation"] in entity["facts"]

    assert {:ok, rendered} = Renderer.render(%{"message" => "Saved.", "records" => [document]})

    assert [delete] = List.last(rendered["blocks"])["elements"]
    assert delete["action_id"] == "ryker_delete_behavior"
    assert delete["style"] == "danger"
    assert delete["value"] == "behavior-control:#{behavior.ref}:1"
    assert delete["text"]["text"] == "Delete guidance"
    assert delete["confirm"]["title"]["text"] == "Delete guidance?"

    assert delete["confirm"]["text"]["text"] ==
             "Stop following “terraform_review_style”. Replies I already sent stay as they are."

    assert delete["confirm"]["confirm"]["text"] == "Delete guidance"
    assert delete["confirm"]["deny"]["text"] == "Cancel"

    assert {:ok, _deleted} = Behaviors.set_status(behavior.ref, :deleted, "slack:T123")
    assert [deleted_document] = ReplyRecords.documents("slack", fixture.episode.id, [record])

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Saved.", "records" => [deleted_document]})

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
    assert inspect(rendered) =~ "Guidance deleted"
  end

  test "crossed and stale behavior controls fail closed" do
    fixture = delivered_offers!("crossed")

    crossed =
      fixture
      |> confirmation(fixture.operator_preference, "crossed")
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert Behaviors.confirm(crossed) == {:error, :behavior_offer_delivery_mismatch}
    assert Repo.aggregate(Behavior, :count, :id) == 0

    Repo.update_all(Record, set: [status: :dismissed])

    assert Behaviors.confirm(confirmation(fixture, fixture.guidance, "stale")) ==
             {:error, :behavior_offer_stale}
  end

  test "a standing assignment match is recorded once and finalized with admission" do
    fixture = delivered_offers!("assignment-run")

    assert {:ok, confirmed} =
             Behaviors.confirm(confirmation(fixture, fixture.assignment, "assignment-run"))

    input = terraform_input(:app, "slack:T123:C456")
    assert {:ok, recorded} = Inbox.record(input)
    input_ref = Inbox.ref(recorded.entry)

    assert %StandingAssignmentRun{
             assignment_id: assignment_id,
             outcome: :pending,
             source_event_ref: source_event_ref,
             source_input_ref: ^input_ref
           } = Repo.one!(StandingAssignmentRun)

    assert assignment_id == confirmed.behavior.id
    assert source_event_ref == input.event_ref

    assert {:ok, duplicate} = Inbox.record(input)
    assert duplicate.status == :duplicate
    assert Repo.aggregate(StandingAssignmentRun, :count, :id) == 1

    assert {:ok, context} =
             Admission.context(input_ref,
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" =>
                 "This exact standing assignment event deserves its own bounded review.",
               "work_class" => "standard"
             })

    assert {:ok, admitted} =
             Admission.commit(context, decision, "admission-decision:1")

    run = Repo.one!(StandingAssignmentRun)
    assert run.outcome == :decided
    assert run.decision_action == :start_episode
    assert run.decision_ref == "admission-decision:1"
    assert run.episode_id == admitted.episode.id

    behavior = Repo.get!(Behavior, confirmed.behavior.id)
    assert behavior.use_count == 1
    assert %DateTime{} = behavior.last_used_at

    assert %{
             "standing_assignments" => [assignment]
           } =
             Behaviors.model_context(
               admitted.episode,
               "slack:app:actor-1",
               "ryker"
             )

    assert assignment["assignment_ref"] == confirmed.behavior.ref
    assert assignment["action"] == "review_terraform_plan"
    assert assignment["authority_ceiling"] == "read_only"
    assert assignment["task"] =~ "exact posted Terraform plan"
  end

  test "behavior retrieval and lifecycle controls stay bounded to trusted context" do
    fixture = delivered_offers!("bounded-retrieval")

    assert {:ok, preference} =
             Behaviors.confirm(
               confirmation(fixture, fixture.workspace_preference, "bounded-preference")
             )

    assert {:ok, assignment} =
             Behaviors.confirm(confirmation(fixture, fixture.assignment, "bounded-assignment"))

    assert Enum.map(Behaviors.list("slack:T123"), & &1.ref) |> Enum.sort() ==
             Enum.sort([preference.behavior.ref, assignment.behavior.ref])

    assert [active_assignment] = Behaviors.list("slack:T123", status: :active, limit: 1)
    assert active_assignment.ref in [preference.behavior.ref, assignment.behavior.ref]
    assert Behaviors.list("", status: :active) == []
    assert Behaviors.list("slack:T123", status: :unknown) == []
    assert Behaviors.list("slack:T123", limit: 0) == []

    assert {:ok, disabled} = Behaviors.set_status(assignment.behavior.ref, :disabled)
    assert disabled.status == :disabled
    assert {:ok, active} = Behaviors.set_status(assignment.behavior.ref, :active)
    assert active.status == :active

    assert Behaviors.set_status("missing-behavior", :active) == {:error, :behavior_not_found}
    assert {:error, _reason} = Behaviors.set_status("", :active)
    assert {:error, _reason} = Behaviors.set_status(assignment.behavior.ref, :unknown)

    assert {:error, _reason} =
             Behaviors.manage_assignment("ref", :unknown, "workspace", "channel")

    assert Behaviors.assignments_for_channel("", "") == []
    assert Behaviors.effective_preferences(:invalid) == %{}
    assert Behaviors.effective_preferences(%{}) == %{}
    assert Behaviors.guidance(:invalid, 20) == []
    assert Behaviors.guidance(%{}, 0) == []
    refute Behaviors.standing_match?(%{})

    assert Behaviors.model_context(%{}, "operator", nil) == %{
             "guidance" => [],
             "preferences" => %{},
             "standing_assignments" => []
           }

    assert Behaviors.observe_input(%{}, "input") ==
             {:error, {:invalid_behavior_run, :input}}

    assert Behaviors.finalize_assignment_runs_in_transaction(
             "input",
             :start_episode,
             "decision",
             nil,
             :decided
           ) == {:error, :behavior_run_transaction_required}

    assert Behaviors.finalize_assignment_runs_in_transaction(
             "input",
             :unknown,
             "decision",
             nil,
             :decided
           ) == {:error, {:invalid_behavior_run, :decision}}
  end

  test "repository preferences and human or app standing triggers keep exact scope semantics" do
    fixture = delivered_offers!("repository-and-triggers")

    repository_preference =
      fixture.workspace_preference
      |> Ecto.Changeset.change(%{
        payload:
          Map.merge(fixture.workspace_preference.payload, %{
            "expires_in" => "365d",
            "repository" => "ryker",
            "scope" => "repository"
          })
      })
      |> Repo.update!()

    short_guidance =
      fixture.guidance
      |> Ecto.Changeset.change(%{
        payload: Map.put(fixture.guidance.payload, "expires_in", "7d")
      })
      |> Repo.update!()

    assert {:ok, preference} =
             Behaviors.confirm(
               confirmation(fixture, repository_preference, "repository-preference")
             )

    assert preference.behavior.scope_kind == :repository
    assert preference.behavior.scope_ref == "ryker"
    assert DateTime.diff(preference.behavior.expires_at, @now, :day) == 365

    assert {:ok, guidance} =
             Behaviors.confirm(confirmation(fixture, short_guidance, "short-guidance"))

    assert DateTime.diff(guidance.behavior.expires_at, @now, :day) == 7

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:other",
      repository: "ryker",
      workspace_ref: "slack:T123"
    }

    assert Behaviors.effective_preferences(context)["response_detail"]["scope"] == "repository"

    assert {:ok, assignment} =
             Behaviors.confirm(confirmation(fixture, fixture.assignment, "trigger-assignment"))

    set_assignment_payload!(assignment.behavior, %{
      "source_filter" => "human",
      "trigger" => "deployment"
    })

    assert Behaviors.standing_match?(
             input!(:user, "slack:T123:C456", %{"text" => "Release deployment started."})
           )

    refute Behaviors.standing_match?(deployment_input())

    set_assignment_payload!(assignment.behavior, %{
      "source_filter" => "any",
      "trigger" => "operational_alert"
    })

    assert Behaviors.standing_match?(
             input!(:bot, "slack:T123:C456", %{"text" => "Critical alert: API is unhealthy"})
           )

    set_assignment_payload!(assignment.behavior, %{
      "source_filter" => "any",
      "trigger" => "pull_request_review"
    })

    refute Behaviors.standing_match?(
             input!(:system, "slack:T123:C456", %{"text" => "ordinary message"})
           )
  end

  test "malformed behavior confirmations fail before durable state changes" do
    assert {:error, _reason} = Behaviors.confirm(%{})
    assert {:error, _reason} = Behaviors.confirm(actor_ref: "a", actor_ref: "b")

    invalid_target = %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:invalid",
      occurred_at: @now,
      record_ref: "record:missing",
      target: %{}
    }

    assert {:error, _reason} = Behaviors.confirm(invalid_target)

    assert Behaviors.confirm(%{invalid_target | target: :invalid}) ==
             {:error, {:invalid_behavior_confirmation, :target}}

    assert Behaviors.confirm(%{invalid_target | occurred_at: :invalid}) ==
             {:error, {:invalid_behavior_confirmation, :occurred_at}}

    assert Behaviors.confirm(%{
             invalid_target
             | record_ref: "record:missing",
               target: %{
                 conversation_ref: "slack:T123:C456",
                 message_ref: "1787832001.000200",
                 thread_ref: nil,
                 transport: "slack"
               }
           }) ==
             {:error, :behavior_offer_not_found}

    assert Behaviors.set_status("behavior", :unknown, "slack:T123") ==
             {:error, {:invalid_behavior, :status}}

    assert Behaviors.set_home_status("behavior", :unknown, "actor", "workspace") ==
             {:error, {:invalid_behavior, :status}}

    assert Behaviors.assignments_for_channel("", "") == []

    assert Behaviors.manage_assignment("behavior", :unknown, "workspace", "conversation") ==
             {:error, {:invalid_behavior, :assignment}}

    assert Behaviors.manage_assignment(
             "behavior:missing",
             :active,
             "slack:T123",
             "slack:T123:C456"
           ) == {:error, :behavior_not_found}

    assert Behaviors.effective_preferences(%{}) == %{}
    assert Behaviors.effective_preferences(:invalid) == %{}

    assert Behaviors.model_context(%{}, "operator", nil) == %{
             "guidance" => [],
             "preferences" => %{},
             "standing_assignments" => []
           }

    assert Behaviors.guidance(%{}, 20) == []
    assert Behaviors.guidance(%{}, 0) == []
    assert Behaviors.search_guidance(%{}, "query", "workspace", 20) == []
    assert Behaviors.search_guidance(%{}, "query", "workspace", 0) == []
    refute Behaviors.standing_match?(:invalid)

    assert Behaviors.finalize_assignment_runs_in_transaction(
             "input:one",
             :reply,
             "decision:one",
             nil,
             :decided
           ) == {:error, :behavior_run_transaction_required}

    assert {:ok, {:error, {:invalid_behavior_confirmation, :input_ref}}} =
             Repo.transaction(fn ->
               Behaviors.finalize_assignment_runs_in_transaction(
                 "",
                 :reply,
                 "decision:one",
                 nil,
                 :decided
               )
             end)
  end

  defp delivered_offers!(suffix, delivery_thread_ref \\ "1787832000.000100") do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1787832000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "behavior-offer:#{suffix}:#{episode_id}",
                 native_input_id: "slack-message:behavior:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:behavior:#{suffix}:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:behavior:#{suffix}", 60, :work)

    assert {:ok, workspace_preference} =
             Records.create(
               Records.token(claim.turn),
               "workspace-preference",
               "preference_offer",
               %{
                 "expires_in" => "90d",
                 "key" => "response_detail",
                 "repository" => nil,
                 "scope" => "workspace",
                 "value" => "standard"
               }
             )

    assert {:ok, operator_preference} =
             Records.create(
               Records.token(claim.turn),
               "operator-preference",
               "preference_offer",
               %{
                 "expires_in" => "90d",
                 "key" => "response_detail",
                 "repository" => nil,
                 "scope" => "operator",
                 "value" => "detailed"
               }
             )

    assert {:ok, guidance} =
             Records.create(Records.token(claim.turn), "guidance", "guidance_offer", %{
               "expires_in" => "30d",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "terraform_review_style",
               "summary" => "Lead with availability risk and drift.",
               "text" =>
                 "When reviewing Terraform here, lead with availability risk and drift, not resource counts.",
               "visibility" => "conversation"
             })

    assert {:ok, assignment} =
             Records.create(
               Records.token(claim.turn),
               "assignment",
               "standing_assignment_offer",
               %{
                 "action" => "review_terraform_plan",
                 "expires_in" => "30d",
                 "repository" => "ryker",
                 "source_filter" => "app",
                 "task" => "Review the exact posted Terraform plan and report material risk.",
                 "trigger" => "terraform_plan"
               }
             )

    assert {:ok, source_event_assignment} =
             Records.create(
               Records.token(claim.turn),
               "source-event-assignment",
               "standing_assignment_offer",
               %{
                 "context_channel" => "slack:T123:C456",
                 "delivery_channel" => "slack:T123:C456",
                 "expires_at" => nil,
                 "filter" => %{
                   "action" => "submitted",
                   "review" => %{"state" => "changes_requested"}
                 },
                 "hold" => nil,
                 "repository" => "ryker",
                 "source_kind" => "github",
                 "task" => "Review the exact pull request review and report material risk.",
                 "title" => "Review every submitted pull request review"
               }
             )

    bind_and_deliver!(
      claim,
      transition.episode,
      suffix,
      [
        workspace_preference,
        operator_preference,
        guidance,
        assignment,
        source_event_assignment
      ],
      delivery_thread_ref
    )
    |> Map.merge(%{
      assignment: assignment,
      guidance: guidance,
      operator_preference: operator_preference,
      source_event_assignment: source_event_assignment,
      workspace_preference: workspace_preference
    })
  end

  defp insert_unrelated_guidance!(offer, count) do
    now = DateTime.utc_now()

    records_and_behaviors =
      Enum.map(1..count, fn index ->
        record_id = Ecto.UUID.generate()
        behavior_id = Ecto.UUID.generate()

        payload = %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "unrelated-#{index}",
          "summary" => "Unrelated guidance #{index}",
          "text" => "Unrelated guidance #{index}",
          "visibility" => "conversation"
        }

        record = %{
          confirmed_at: now,
          confirmed_by_actor_ref: "slack:user:U123",
          confirmation_ref: "confirmation:unrelated:#{index}",
          episode_id: offer.episode_id,
          id: record_id,
          inserted_at: now,
          kind: "guidance_offer",
          operation_id: "unrelated-#{index}",
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          ref: "record:unrelated:#{record_id}",
          status: :confirmed,
          turn_id: offer.turn_id,
          updated_at: now
        }

        behavior = %{
          confirmation_ref: "confirmation:unrelated:#{index}",
          confirmed_at: now,
          confirmed_by_actor_ref: "slack:user:U123",
          expires_at: DateTime.add(now, 86_400, :second),
          id: behavior_id,
          identity_key: "unrelated-#{index}",
          inserted_at: now,
          kind: :guidance,
          offer_record_id: record_id,
          payload: payload,
          ref: "behavior:#{behavior_id}",
          revision: 1,
          scope_kind: :conversation,
          scope_ref: "slack:T123:C#{index + 1_000}",
          source_conversation_ref: "slack:T123:C#{index + 1_000}",
          source_message_ref: "message:unrelated:#{index}",
          source_transport: "slack",
          status: :active,
          updated_at: now,
          use_count: 0,
          workspace_ref: "slack:T123"
        }

        {record, behavior}
      end)

    {records, behaviors} = Enum.unzip(records_and_behaviors)
    {^count, nil} = Repo.insert_all(Record, records)
    {^count, nil} = Repo.insert_all(Behavior, behaviors)
  end

  defp bind_and_deliver!(claim, episode, suffix, records, delivery_thread_ref) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id},
               "Offer the requested durable behavior.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:behavior:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:behavior:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"I can remember that after confirmation."})
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode.id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "I can remember that after confirmation.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => Enum.map(records, & &1.ref),
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode.id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:behavior:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:behavior:#{suffix}", 60, :delivery)

    # Where this turn's reply goes, exactly as `Custody.reply_target/2` freezes
    # it at acceptance: the answering input's own origin, which routing can join
    # into this episode from a thread other than its bound home.
    Repo.get_by!(Turn, episode_id: episode.id, turn_ref: turn.turn_ref)
    |> Ecto.Changeset.change(
      delivery_target: %{
        "conversation_ref" => "slack:T123:C456",
        "thread_ref" => delivery_thread_ref,
        "transport" => "slack"
      }
    )
    |> Repo.update!()

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               delivery_thread_ref,
               "1787832001.000200"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, receipt: receipt}
  end

  defp confirmation(fixture, record, suffix) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{suffix}",
      occurred_at: @now,
      record_ref: record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  defp terraform_input(actor_kind, conversation_ref) do
    input!(actor_kind, conversation_ref, %{
      "text" => "Terraform plan: 2 to add, 1 to change, 0 to destroy"
    })
  end

  defp github_review_input(conversation_ref, action, state) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :app, ref: "github-app:ryker"},
               content: %{
                 "action" => action,
                 "review" => %{"state" => state}
               },
               destination: %{
                 conversation_ref: conversation_ref,
                 thread_ref: "pull:42",
                 transport: "slack"
               },
               event_kind: :event,
               event_ref: "github-review:#{action}:#{state}:#{conversation_ref}",
               native_input_id: "github-review:42:#{state}",
               occurred_at: @now,
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: "github", ref: "github:ryker"},
               source_capabilities: %{},
               source_item_ref: "pull-review:42"
             })

    input
  end

  defp deployment_input do
    input!(:app, "slack:T123:C456", %{"text" => "Deployment completed successfully."})
  end

  defp input!(actor_kind, conversation_ref, content) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: actor_kind, ref: "actor-1"},
        content: content,
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: "1787832999.000100",
          transport: "slack"
        },
        event_kind: :message,
        event_ref: "event:#{Ecto.UUID.generate()}",
        native_input_id: "item:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "slack", ref: "T123"},
        source_capabilities: %{},
        source_item_ref: nil
      })

    input
  end

  defp set_assignment_payload!(behavior, overrides) do
    behavior
    |> Ecto.Changeset.change(%{payload: Map.merge(behavior.payload, overrides)})
    |> Repo.update!()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
