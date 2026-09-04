defmodule Responder.ControlPlane.ProjectionTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.ControlPlane.Projection
  alias Responder.CoopFleet.Worker
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Publication.Changeset, as: PublicationChangeset
  alias Responder.Repo
  alias Responder.Retention.Custody, as: RetentionCustody

  alias Responder.Slack.{
    ChannelConfigurationChangeset,
    IncidentRoomChangeset,
    IncidentRoomLifecycleEventChangeset
  }

  alias Responder.Slack.Input, as: SlackInput

  alias Responder.State.{
    Records,
    ScheduleChangeset,
    ScheduleOccurrenceChangeset
  }

  alias Responder.Work.{Cancellation, Custody, Measurement, Result, SubmissionBuilder}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "overview exposes admission phase counts and elapsed queue time" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Show admission timing"},
               event_kind: :message,
               event_ref: "Ev-control-admission-timing",
               message_ref: "1787832099.000100",
               occurred_at: DateTime.utc_now(),
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    Repo.update_all(
      from(saved in Entry, where: saved.id == ^entry.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), 1, :second)]
    )

    assert %{progress: %{admission: queued}} = Projection.overview()
    assert queued.queued == 1
    assert queued.admitting == 0
    assert is_integer(queued.oldest_active_ms) and queued.oldest_active_ms >= 0

    claim_now = DateTime.add(DateTime.utc_now(), 1, :second)
    assert {:ok, %{entry: claimed}} = Inbox.claim_next("control:timing", claim_now, 30)
    assert claimed.id == entry.id

    assert %{progress: %{admission: admitting}} = Projection.overview()
    assert admitting.queued == 0
    assert admitting.admitting == 1
  end

  test "projects bounded lifecycle metadata without exposing durable input payloads" do
    target = waiting_episode!("control:100%_literal", "raw-secret-value")
    _wildcard_decoy = waiting_episode!("control:100XXliteral", "other-secret-value")

    overview = Projection.overview()
    assert overview.counts.active == 2
    assert overview.counts.waiting == 2
    assert is_map(overview.fleet)
    assert Map.has_key?(overview.fleet, :eligible_workers)
    assert length(overview.needs_attention) <= 20

    page = Projection.episodes(%{"page" => "1", "q" => "100%_", "state" => "waiting_for_input"})
    assert Enum.map(page.items, & &1.ref) == [target.episode.key]
    assert page.pages == 1

    assert {:ok, detail} = Projection.episode(target.episode.key)
    assert detail.episode.ref == target.episode.key
    assert Enum.map(detail.events, & &1.summary) == ["input admitted", "input wait started"]
    refute inspect(detail) =~ "raw-secret-value"
    refute Map.has_key?(detail, :payload)
  end

  test "configuration reports only runtime presence and includes every product owner" do
    keys = [:control_plane, :emisar, :retention]
    previous = Map.new(keys, &{&1, Application.get_env(:responder, &1, :missing)})

    Application.put_env(:responder, :control_plane, %{port: 4321})
    Application.put_env(:responder, :emisar, %{token: "secret"})
    Application.put_env(:responder, :retention, %{lease_seconds: 60})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:responder, key)
        {key, value} -> Application.put_env(:responder, key, value)
      end)
    end)

    assert %{key: "control_plane", value: "enabled"} in Projection.configuration()
    assert %{key: "emisar", value: "enabled"} in Projection.configuration()
    assert %{key: "retention", value: "enabled"} in Projection.configuration()
    refute inspect(Projection.configuration()) =~ "4321"
    refute inspect(Projection.configuration()) =~ "secret"
  end

  test "usage keeps measured coverage cost timing and effective targets distinct" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    measured = measured_turn!("measured", "claude:opus/high@work", now)
    _unmeasured = measured_turn!("unmeasured", "codex:gpt-5.6-sol/xhigh@work", now, false)

    snapshot = Projection.usage(%{"window" => "24h"})

    assert snapshot.window == "24h"
    assert snapshot.totals.attempts == 2
    assert snapshot.totals.usage_measured == 1
    assert snapshot.totals.costed == 1
    assert snapshot.totals.timed == 1
    assert snapshot.totals.input_tokens == 1_200
    assert snapshot.totals.cached_input_tokens == 800
    assert snapshot.totals.output_tokens == 300
    assert snapshot.totals.reasoning_tokens == 25
    assert Decimal.equal?(snapshot.totals.cost_usd, Decimal.new("0.0125"))
    assert snapshot.totals.cache_hit_rate == 0.4
    assert snapshot.totals.average_queued_ms == 5_000
    assert snapshot.totals.average_provider_ms == 5_000
    assert snapshot.totals.average_host_ms == measured.usage_host_ms

    assert %{provider: "claude", model: "opus", effort: "high", attempts: 1} =
             Enum.find(snapshot.targets, &(&1.target == measured.execution_target))

    assert [%{attempts: 2, costed: 1, measured: 1}] = snapshot.channels
    assert [%{attempts: 2, costed: 1, measured: 1}] = snapshot.repositories
    assert Enum.any?(snapshot.targets, &(&1.target == "codex:gpt-5.6-sol/xhigh@work"))
    assert [%{attempts: 2, measured: 1}] = snapshot.days

    assert [target_episode] =
             Projection.episodes(%{"target" => "claude:opus/high@work"}).items

    assert target_episode.ref == episode_key!(measured.episode_id)
  end

  test "projects every kernel lifecycle and blocked work custody without model payloads" do
    working = start_episode!("working")

    assert {:ok, session} =
             Custody.pin_episode(working.episode.id, "policy:read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("control-plane:test", 60, :work)

    assert {:ok, progress} =
             Records.create(Records.token(claim.turn), "progress-one", "progress", %{
               "next_due_at" => nil,
               "phase" => "investigating",
               "summary" => "Repository and runtime evidence are being reconciled."
             })

    assert {:ok, goal} =
             Records.create(Records.token(claim.turn), "goal-one", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "Current evidence supports a bounded conclusion.",
               "id" => "verify-runtime",
               "kind" => "check",
               "prerequisite_goal_ids" => [],
               "read_only_repositories" => [],
               "requested_outcome" => "Verify the current runtime state",
               "required" => true,
               "writable_repository" => nil
             })

    assert [%{status: :active, summary: "no repository"}] = Projection.workspaces(%{})

    assert {:ok, detail} = Projection.episode(working.episode.key)
    assert Enum.map(detail.records, & &1.summary) == [progress.operation_id, goal.subject_ref]

    assert {:ok, %{status: :pending}} =
             Custody.request_block(
               working.episode.id,
               working.episode.key,
               working.episode.owner_ref,
               claim.lease_ref,
               "manual recovery required"
             )

    assert {:ok, cancellation_claim} =
             Custody.claim_next("control-plane:cancellation", 60, :work)

    assert {:ok, cancellation_receipt} =
             Cancellation.absent_receipt(
               "responder:work:create:#{session.id}:g#{session.create_generation}",
               nil,
               nil,
               nil,
               nil
             )

    assert {:ok, %{turn: %{status: :blocked}}} =
             Custody.settle_cancellation(
               working.episode.id,
               working.episode.key,
               working.episode.owner_ref,
               cancellation_claim.lease_ref,
               cancellation_receipt
             )

    waiting_event = start_episode!("waiting-event")

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: DateTime.add(@now, 600, :second),
                 episode_key: waiting_event.episode.key,
                 expected_turn_ref: waiting_event.episode.owner_ref,
                 kind: :event,
                 wait_ref: "wait:event:#{waiting_event.episode.id}"
               })
             )

    delivery = start_episode!("delivery")

    assert {:ok, _delivery} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 delivery_ref: "delivery:#{delivery.episode.id}",
                 episode_key: delivery.episode.key,
                 expected_turn_ref: delivery.episode.owner_ref,
                 result_ref: "result:#{delivery.episode.id}"
               })
             )

    complete = start_episode!("complete")

    assert {:ok, _complete} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "No visible reply is required.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: complete.episode.key,
                 expected_turn_ref: complete.episode.owner_ref,
                 result_ref: "result:#{complete.episode.id}"
               })
             )

    cancelled = start_episode!("cancelled")

    assert {:ok, _cancelled} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{cancelled.episode.id}",
                 episode_key: cancelled.episode.key,
                 expected_owner: %{kind: :turn, ref: cancelled.episode.owner_ref}
               })
             )

    overview = Projection.overview()
    assert overview.counts.blocked == 1

    assert %{kind: :blocked_work, ref: working_ref} =
             Enum.find(overview.needs_attention, &(&1.kind == :blocked_work))

    assert working_ref == working.episode.key

    assert %{next_action: "operator_recovery"} = listed_episode(working.episode.key)
    assert %{next_action: "external_event"} = listed_episode(waiting_event.episode.key)
    assert %{next_action: "deliver_result"} = listed_episode(delivery.episode.key)
    assert %{next_action: "complete"} = listed_episode(complete.episode.key)
    assert %{next_action: "cancelled"} = listed_episode(cancelled.episode.key)

    assert {:ok,
            [
              %{
                action: :retry,
                attempt_count: attempt_count,
                destination: destination,
                detail: detail,
                episode_ref: blocked_ref,
                kind: "work",
                ref: blocked_ref,
                summary: "work_execution_blocked"
              }
            ]} =
             Projection.failures(%{})

    assert blocked_ref == working.episode.key
    assert attempt_count >= 1
    assert detail =~ "stored diagnostic sha256:"
    refute detail =~ "manual recovery required"
    assert String.starts_with?(destination, "slack:T123:C456 / thread:")

    assert {:ok, %{action: :retry, ref: ^blocked_ref, status: :blocked}} =
             Projection.work(blocked_ref)

    assert Projection.delivery(:invalid) == :not_found
    assert Projection.delivery("missing") == :not_found
    assert Projection.episode(:invalid) == :not_found
    assert Projection.episode("missing") == :not_found

    assert Projection.decisions(%{}) == []
    assert Projection.findings(%{}) == []
    assert length(Projection.audit(%{})) >= 9
    assert map_size(Projection.callbacks()) == 30
  end

  test "operator workbench projections stay bounded and explicit with no durable rows" do
    assert Projection.incidents(%{}) == []
    assert Projection.schedules(%{}) == []
    assert Projection.channels(%{}) == []
    assert Projection.repositories(%{}) == []
    assert Projection.calibration(%{"window" => "24h"}) == %{rows: [], window: "24h"}

    assert Projection.incident("missing") == :not_found
    assert Projection.schedule("missing") == :not_found
    assert Projection.channel("T123", "C456") == :not_found

    assert %{grants: grants, rows: rows, source: source} = Projection.operator_configuration()
    assert is_list(grants)
    assert is_list(rows)
    assert is_binary(source)
    refute inspect(%{grants: grants, rows: rows}) =~ "secret"

    assert Projection.incidents(:invalid) == []
    assert Projection.schedules(:invalid) == []
    assert Projection.channels(:invalid) == []
    assert Projection.repositories(:invalid) == []
    assert Projection.calibration(:invalid) == %{rows: [], window: "30d"}
    assert Projection.incident(nil) == :not_found
    assert Projection.schedule(nil) == :not_found
    assert Projection.channel(nil, nil) == :not_found
  end

  test "operator workbench joins incidents schedules channels and repository freshness without payload leaks" do
    configuration_keys = [:control_plane, :schedules]

    previous_configuration =
      Map.new(configuration_keys, &{&1, Application.get_env(:responder, &1, :missing)})

    Application.put_env(:responder, :control_plane, %{
      task_policies: %{"responder" => %{name: "responder-contributor"}}
    })

    Application.put_env(:responder, :schedules, %{
      repositories: %{"responder" => %{"name" => "responder-scheduled"}}
    })

    on_exit(fn ->
      Enum.each(previous_configuration, fn
        {key, :missing} -> Application.delete_env(:responder, key)
        {key, value} -> Application.put_env(:responder, key, value)
      end)
    end)

    source = start_episode!("operator-workbench")

    assert {:ok, session} =
             Custody.pin_episode(
               source.episode.id,
               "policy:operator",
               String.duplicate("a", 64),
               "responder"
             )

    assert {:ok, claim} = Custody.claim_next("operator-workbench", 60, :work)
    assert claim.session.id == session.id

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "operator-evidence", "progress", %{
               "next_due_at" => nil,
               "phase" => "investigating",
               "summary" => "Bounded operator projection evidence."
             })

    freshness = %{
      "context" => %{
        "workspace" => %{
          "freshness" => %{
            "owner" => "coop",
            "repositories" => [
              %{
                "fetched_at" => "2026-08-28T11:59:00Z",
                "name" => "primary",
                "remote_identity" => "origin",
                "requested_revision" => "refs/heads/main",
                "resolved_revision" => String.duplicate("b", 40),
                "stale_base_revision" => nil,
                "stale_base_status" => "current",
                "version" => 2,
                "workspace_base_revision" => String.duplicate("b", 40)
              }
            ],
            "status" => "recorded"
          }
        }
      },
      "private" => "must-not-render"
    }

    Repo.update_all(
      from(turn in Responder.Work.Turn, where: turn.id == ^claim.turn.id),
      set: [
        submission: freshness,
        submission_fingerprint: Responder.CanonicalJSON.digest(freshness)
      ]
    )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    configuration =
      %{
        actor_ref: "U123",
        alert_policy: :offer,
        channel_ref: "C456",
        id: Ecto.UUID.generate(),
        invite_user_group_refs: [],
        invite_user_refs: [],
        participation: :proactive,
        repository_ref: "responder",
        revision: 1,
        saved_at: now,
        workspace_ref: "T123"
      }
      |> ChannelConfigurationChangeset.configuration()
      |> Repo.insert!()

    membership =
      %{
        channel_ref: "C456",
        external_shared: false,
        generation: 1,
        id: Ecto.UUID.generate(),
        joined_at: now,
        private: true,
        status: :joined,
        workspace_ref: "T123"
      }
      |> ChannelConfigurationChangeset.membership()
      |> Repo.insert!()

    schedule =
      %{
        authority: :read_only,
        catch_up: :latest,
        confirmation_ref: "schedule-confirmation:operator",
        confirmed_at: now,
        confirmed_by_actor_ref: "U123",
        destination_conversation_ref: "slack:T123:C456",
        destination_thread_ref: nil,
        destination_transport: "slack",
        expires_at: DateTime.add(now, 86_400, :second),
        id: Ecto.UUID.generate(),
        next_occurrence_at: DateTime.add(now, 3_600, :second),
        offer_record_id: record.id,
        recurrence: %{
          "every_seconds" => 3_600,
          "kind" => "interval",
          "starts_at" => DateTime.to_iso8601(now)
        },
        ref: "schedule:operator",
        repository: "responder",
        revision: 1,
        source_episode_id: source.episode.id,
        status: :active,
        task: "Check the current deployment without exposing private-input-marker.",
        timezone: "UTC",
        title: "Operator schedule"
      }
      |> ScheduleChangeset.insert()
      |> Repo.insert!()

    occurrence =
      %{
        child_episode_id: source.episode.id,
        event_ref: "schedule-event:operator",
        id: Ecto.UUID.generate(),
        ref: "schedule-occurrence:operator",
        schedule_id: schedule.id,
        scheduled_for: now,
        status: :dispatched
      }
      |> ScheduleOccurrenceChangeset.insert()
      |> Repo.insert!()

    room =
      %{
        attempt_count: 1,
        bot_user_ref: "U-BOT",
        channel_name: "ems-operator-incident",
        channel_ref: "CINCIDENT",
        channel_state: :active,
        channel_state_changed_at: now,
        channel_state_event_ref: "channel-state:operator",
        confirmation_ref: "incident-confirmation:operator",
        episode_id: source.episode.id,
        id: Ecto.UUID.generate(),
        invite_user_group_refs: [],
        invite_user_refs: ["U123"],
        policy: "incident-investigate",
        policy_digest: String.duplicate("c", 64),
        private: true,
        prompt: "Investigate private-incident-marker.",
        reconciled_channel_state: :active,
        record_id: record.id,
        ref: "incident-room:operator",
        repository_ref: "responder",
        requested_at: now,
        requested_by_actor_ref: "U123",
        source_channel_ref: "C456",
        source_episode_id: source.episode.id,
        source_message_ref: "1787832000.000100",
        status: :blocked,
        title: "Operator incident",
        topic: "Operator incident room",
        workspace_ref: "T123"
      }
      |> IncidentRoomChangeset.insert()
      |> Repo.insert!()

    publication =
      %{
        body: "Private publication body must-not-render-publication-body.",
        destination_conversation_ref: source.episode.destination_conversation_ref,
        destination_thread_ref: source.episode.destination_thread_ref,
        destination_transport: source.episode.destination_transport,
        episode_id: source.episode.id,
        id: Ecto.UUID.generate(),
        last_error_detail: "provider-token must-not-render-publication-error",
        offer_message_ref: "publication-offer:operator",
        record_id: record.id,
        ref: "publication:operator",
        repository: "responder",
        review_request_ref: "review-request:operator",
        review_requested_at: now,
        review_requested_by_actor_ref: "slack:user:U123",
        session_id: session.id,
        status: :review_pending,
        title: "Operator publication"
      }
      |> PublicationChangeset.insert()
      |> Repo.insert!()

    assert {:ok, followup_record} =
             Records.create(Records.token(claim.turn), "operator-followup", "progress", %{
               "next_due_at" => nil,
               "phase" => "publishing",
               "summary" => "A newer publication for the same incident."
             })

    newer_publication =
      %{
        body: "Newer private publication body.",
        destination_conversation_ref: source.episode.destination_conversation_ref,
        destination_thread_ref: source.episode.destination_thread_ref,
        destination_transport: source.episode.destination_transport,
        episode_id: source.episode.id,
        id: Ecto.UUID.generate(),
        last_error_detail: "provider-token must-not-render-publication-error:newer",
        offer_message_ref: "publication-offer:operator:newer",
        record_id: followup_record.id,
        ref: "publication:operator:newer",
        repository: "responder",
        review_request_ref: "review-request:operator:newer",
        review_requested_at: DateTime.add(now, 1, :second),
        review_requested_by_actor_ref: "slack:user:U123",
        session_id: session.id,
        status: :review_pending,
        title: "Newer operator publication"
      }
      |> PublicationChangeset.insert()
      |> Repo.insert!()

    _lifecycle =
      %{
        channel_ref: "CINCIDENT",
        event_fingerprint: String.duplicate("d", 64),
        event_ref: "incident-lifecycle:operator",
        id: Ecto.UUID.generate(),
        kind: :observed_active,
        occurred_at: now,
        room_id: room.id,
        workspace_ref: "T123"
      }
      |> IncidentRoomLifecycleEventChangeset.insert()
      |> Repo.insert!()

    Repo.insert!(%Worker{
      id: "operator-worker",
      workspace_ref: "workspace-operator",
      certificate_sha256: String.duplicate("e", 64),
      policy_digests: %{},
      policy_authority_digests: %{},
      repositories: ["ignored", %{"ref" => "responder", "revision" => "commit:operator"}],
      capabilities: [],
      capacity: %{},
      state: :eligible,
      last_seen_at: now
    })

    assert [
             %{
               publication_ref: "publication:operator:newer",
               ref: "incident-room:operator",
               status: :blocked
             }
           ] =
             Projection.incidents(%{"q" => "Operator incident", "status" => "blocked"})

    assert {:ok, incident} = Projection.incident(room.ref)
    assert incident.room.episode_ref == source.episode.key
    assert [%{kind: :observed_active}] = incident.lifecycle
    assert Enum.map(incident.records, & &1.ref) == [record.ref, followup_record.ref]
    assert publication.ref != newer_publication.ref
    assert incident.publication.ref == newer_publication.ref
    assert incident.publication.last_error =~ "stored diagnostic sha256:"
    refute inspect(incident) =~ "private-incident-marker"
    refute inspect(incident) =~ "must-not-render-publication"

    assert [%{ref: "schedule:operator"}] =
             Projection.schedules(%{"q" => "Operator", "status" => "active"})

    assert {:ok, schedule_detail} = Projection.schedule(schedule.ref)
    assert schedule_detail.schedule.recurrence == "every 3600 seconds"
    assert [%{ref: occurrence_ref, episode_ref: episode_ref}] = schedule_detail.occurrences
    assert occurrence_ref == occurrence.ref
    assert episode_ref == source.episode.key

    for {recurrence, label} <- [
          {%{"kind" => "daily", "time" => "09:30"}, "daily at 09:30"},
          {%{"kind" => "weekly", "time" => "10:00", "weekday" => "monday"},
           "weekly on monday at 10:00"},
          {%{"day" => 15, "kind" => "monthly", "time" => "11:00"}, "monthly on day 15 at 11:00"},
          {%{"at" => "2026-09-05T12:00:00Z", "kind" => "once"}, "once at 2026-09-05T12:00:00Z"},
          {%{"kind" => "future"}, "recorded recurrence"}
        ] do
      Repo.update_all(
        from(saved in Responder.State.Schedule, where: saved.id == ^schedule.id),
        set: [recurrence: recurrence]
      )

      assert {:ok, %{schedule: %{recurrence: ^label}}} = Projection.schedule(schedule.ref)
    end

    assert [%{membership: :joined, private: true, repository_ref: "responder"}] =
             Projection.channels(%{"q" => "C456"})

    assert {:ok, channel} = Projection.channel("T123", "C456")
    assert channel.channel.configuration_revision == configuration.revision
    assert channel.channel.membership == membership.status
    assert Enum.any?(channel.schedules, &(&1.ref == schedule.ref))
    assert Enum.any?(channel.episodes, &(&1.ref == source.episode.key))

    assert {:ok, incident_channel} = Projection.channel("T123", "CINCIDENT")
    assert incident_channel.channel.incident_room
    assert incident_channel.channel.channel_state == :active
    assert incident_channel.channel.private
    assert incident_channel.channel.repository_ref == "responder"

    assert [%{ref: "responder", freshness: receipt} = repository] =
             Projection.repositories(%{"q" => "respond"})

    assert repository.channels == 1
    assert repository.schedules == 1
    assert repository.sessions == 1

    assert repository.configured == %{
             contributor_policy: "responder-contributor",
             schedule_policy: "responder-scheduled"
           }

    assert [%{revision: "commit:operator", worker_ref: "operator-worker"}] = repository.workers
    assert receipt.version == 2
    assert receipt.remote_identity == "origin"
    refute inspect(repository) =~ "must-not-render"
  end

  test "model calibration attributes the admitted work class to the exact accepted turn" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    measured = measured_turn!("calibration", "codex:gpt-5.6-sol/medium@work", now)

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Calibrate this turn"},
               event_kind: :message,
               event_ref: "Ev-control-calibration",
               message_ref: "1787832099.000200",
               occurred_at: now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    decision = %{
      "action" => "start_episode",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "Requires evidence.",
      "work_class" => "standard"
    }

    Repo.update_all(
      from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :start_episode,
        decision_document: decision,
        decision_fingerprint: Responder.CanonicalJSON.digest(decision),
        decision_ref: "decision:calibration",
        episode_id: measured.episode_id,
        status: :decided
      ]
    )

    Repo.update_all(
      from(turn in Responder.Work.Turn, where: turn.id == ^measured.id),
      set: [turn_ref: "ingress-turn:#{entry.id}", validation_generation: 2]
    )

    assert %{window: "all", rows: [row]} = Projection.calibration(%{"window" => "all"})
    assert row.class == "standard"
    assert row.provider == "codex"
    assert row.model == "gpt-5.6-sol"
    assert row.effort == "medium"
    assert row.attempts == 1
    assert row.measured == 1
    assert row.repair_rounds == 1
    assert row.average_provider_ms == 5_000
    assert Decimal.equal?(row.cost_usd, Decimal.new("0.0125"))

    Repo.update_all(
      from(turn in Responder.Work.Turn, where: turn.id == ^measured.id),
      set: [
        timing_recorded: false,
        remote_finished_at: nil,
        remote_queued_at: nil,
        remote_started_at: nil,
        usage_host_ms: nil,
        usage_provider_ms: nil,
        usage_queued_ms: nil
      ]
    )

    assert %{rows: [%{average_provider_ms: nil}], window: "7d"} =
             Projection.calibration(%{"window" => "7d"})
  end

  test "effective configuration exposes provenance and grant names but never secrets or callbacks" do
    keys = [:state_tools, :work]
    previous = Map.new(keys, &{&1, Application.get_env(:responder, &1, :missing)})
    previous_path = System.get_env("RESPONDER_ELIXIR_CONFIG")

    Application.put_env(:responder, :state_tools, %{
      additional_call: fn _, _, _ -> :secret_callback end,
      additional_tools: [
        %{"name" => "search_slack", "description" => "private schema"},
        %{name: "read_incident"},
        %{unexpected: "ignored"}
      ],
      capabilities: [:emisar_approvals, :schedules],
      token: "must-not-render-secret"
    })

    Application.put_env(:responder, :work, %{
      concurrency: 4,
      platform_tools: ["source_read"],
      poll_interval_ms: 250
    })

    System.put_env("RESPONDER_ELIXIR_CONFIG", "/etc/responder/emisar.yaml")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:responder, key)
        {key, value} -> Application.put_env(:responder, key, value)
      end)

      if previous_path,
        do: System.put_env("RESPONDER_ELIXIR_CONFIG", previous_path),
        else: System.delete_env("RESPONDER_ELIXIR_CONFIG")
    end)

    snapshot = Projection.operator_configuration()
    assert snapshot.source == "/etc/responder/emisar.yaml"

    assert %{key: "work.concurrency", value: "4"} =
             Enum.find(snapshot.rows, &(&1.key == "work.concurrency"))

    assert Enum.any?(snapshot.grants, &match?(%{kind: "MCP tool", name: "search_slack"}, &1))
    assert Enum.any?(snapshot.grants, &match?(%{kind: "MCP tool", name: "read_incident"}, &1))

    assert Enum.any?(
             snapshot.grants,
             &match?(%{kind: "host capability", name: "emisar_approvals"}, &1)
           )

    assert Enum.any?(
             snapshot.grants,
             &match?(%{kind: "source/action tool", name: "source_read"}, &1)
           )

    refute inspect(snapshot) =~ "must-not-render-secret"
    refute inspect(snapshot) =~ "secret_callback"
    refute inspect(snapshot) =~ "private schema"
  end

  test "episode paging and filters fail closed to bounded defaults" do
    target = start_episode!("paging")

    assert %{page: 1, pages: 1} = Projection.episodes(%{"page" => "0"})
    assert %{page: 1} = Projection.episodes(%{"page" => "not-a-number"})
    assert %{page: 1} = Projection.episodes([])
    assert %{items: []} = Projection.episodes(%{"state" => "complete"})
    assert %{items: []} = Projection.episodes(%{"state" => "cancelled"})
    assert %{items: []} = Projection.episodes(%{"state" => "waiting_for_event"})

    assert %{items: [%{ref: invalid_search_ref}]} =
             Projection.episodes(%{"q" => String.duplicate("x", 121)})

    assert invalid_search_ref == target.episode.key
    assert %{items: [%{ref: ref}]} = Projection.episodes(%{"q" => "paging"})
    assert ref == target.episode.key

    assert %{items: [%{ref: ^ref}]} = Projection.episodes(%{"state" => "working"})
  end

  test "memory projection returns every bounded operator-owned collection" do
    assert %{behaviors: behaviors, memories: memories, schedules: schedules} = Projection.memory()
    assert is_list(behaviors)
    assert is_list(memories)
    assert is_list(schedules)
  end

  test "retention failures and safe operator actions are visible without plan payloads" do
    completed = start_episode!("retention-failure")

    assert {:ok, session} =
             Custody.pin_episode(completed.episode.id, "policy:read", String.duplicate("a", 64))

    assert {:ok, _complete} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "No visible reply is required.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: completed.episode.key,
                 expected_turn_ref: completed.episode.owner_ref,
                 result_ref: "result:retention:#{completed.episode.id}"
               })
             )

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup:projection", 60, 0)
    assert claim.session.id == session.id

    assert {:ok, blocked} =
             RetentionCustody.block(
               session.id,
               claim.lease_ref,
               "coop_unavailable",
               "private transport detail"
             )

    assert {:ok, failures} = Projection.failures(%{})

    assert %{
             detail: detail,
             kind: "retention",
             ref: ref,
             summary: "coop_unavailable"
           } =
             Enum.find(failures, &(&1.kind == "retention"))

    assert ref == session.external_ref
    assert detail =~ "stored diagnostic sha256:"
    refute detail =~ "private transport detail"
    assert {:ok, workspace} = Projection.workspace(session.external_ref)
    assert workspace.action == :rearm
    assert workspace.status == :blocked
    assert workspace.summary == "coop_unavailable"
    refute inspect(workspace) =~ "private transport detail"
    refute inspect(workspace) =~ inspect(blocked.discard_plan)
    assert workspace in Projection.workspaces(%{})
  end

  test "detail lookups and usage windows fail closed without leaking arbitrary references" do
    for callback <- [
          &Projection.admission/1,
          &Projection.delivery/1,
          &Projection.emisar/1,
          &Projection.slack_incident/1,
          &Projection.slack_interaction/1,
          &Projection.work/1,
          &Projection.workspace/1
        ] do
      assert callback.(:invalid) == :not_found
      assert callback.("missing-ref") == :not_found
    end

    assert Projection.usage(%{}).window == "7d"
    assert Projection.usage([]).window == "7d"
    assert Projection.usage(%{"window" => "unknown"}).window == "7d"
    assert Projection.usage(%{"window" => "30d"}).window == "30d"
    assert Projection.usage(%{"window" => "all"}).window == "all"
  end

  defp waiting_episode!(key, secret) do
    id = Ecto.UUID.generate()
    turn_ref = "turn:control-plane:#{id}"

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "slack:T123:C456",
            thread_ref: "thread:#{id}",
            transport: "slack"
          },
          episode_id: id,
          episode_key: "#{key}:#{id}",
          native_input_id: "source:control-plane:#{id}",
          occurred_at: @now,
          payload: %{"text" => secret},
          turn_ref: turn_ref
        })
      )

    {:ok, waiting} =
      Episodes.apply(
        EpisodeFixtures.start_wait(%{
          episode_key: started.episode.key,
          expected_turn_ref: turn_ref,
          occurred_at: DateTime.add(@now, 1, :second),
          wait_ref: "question:#{id}"
        })
      )

    waiting
  end

  defp start_episode!(suffix) do
    id = Ecto.UUID.generate()
    turn_ref = "turn:control-plane:#{suffix}:#{id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "thread:#{suffix}:#{id}",
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: "control-plane:#{suffix}:#{id}",
                 native_input_id: "source:control-plane:#{suffix}:#{id}",
                 occurred_at: @now,
                 payload: %{"text" => "redacted by projection"},
                 turn_ref: turn_ref
               })
             )

    transition
  end

  defp listed_episode(ref) do
    Projection.episodes(%{})
    |> Map.fetch!(:items)
    |> Enum.find(&(&1.ref == ref))
  end

  defp measured_turn!(suffix, target, accepted_at, usage? \\ true) do
    transition = start_episode!("usage-#{suffix}")

    assert {:ok, session} =
             Custody.pin_episode(
               transition.episode.id,
               "policy:usage",
               String.duplicate("a", 64)
             )

    assert {:ok, claim} = Custody.claim_next("usage:#{suffix}", 60, :work)
    assert claim.session.id == session.id
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, bound_session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:usage:#{session.id}"
             )

    assert {:ok, _bound_turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               bound_session.generation,
               turn.submit_generation,
               "remote:turn:#{turn.id}"
             )

    candidate =
      Jason.encode!(%{
        "decision_reason" => "No visible reply is required.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [],
          "state" => "complete"
        }
      })

    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:none, nil, "No visible reply is required.")

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    remote_turn =
      if usage? do
        %{
          "finished_at" =>
            accepted_at |> DateTime.add(-250, :millisecond) |> DateTime.to_iso8601(),
          "queued_at" =>
            accepted_at |> DateTime.add(-10_250, :millisecond) |> DateTime.to_iso8601(),
          "started_at" =>
            accepted_at |> DateTime.add(-5_250, :millisecond) |> DateTime.to_iso8601(),
          "usage" => %{
            "cached_input_tokens" => 800,
            "cost_recorded" => true,
            "cost_usd" => 0.0125,
            "input_tokens" => 1_200,
            "output_tokens" => 300,
            "reasoning_tokens" => 25
          }
        }
      else
        %{}
      end

    measurement = Measurement.prepare(remote_turn, %{"target" => target})

    assert {:ok, %{turn: accepted}} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "receipt:usage:#{suffix}",
               measurement
             )

    accepted
  end

  defp episode_key!(episode_id) do
    Responder.Repo.get!(Responder.Episodes.Episode, episode_id).key
  end
end
