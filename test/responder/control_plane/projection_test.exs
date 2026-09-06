defmodule Responder.ControlPlane.ProjectionTest do
  use Responder.DataCase, async: false

  import Ecto.Query
  require Phoenix.LiveViewTest

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.Activity
  alias Responder.ControlPlane.HTML
  alias Responder.ControlPlane.Projection
  alias Responder.ControlPlane.RequestFilters
  alias Responder.ControlPlane.UsageProjection
  alias Responder.CoopFleet.{Event, Placement, Worker}
  alias Responder.Delivery.PlatformActionCustody
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.Input, as: GenericInput
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
    EventSubscriptionChangeset,
    Records,
    ScheduleChangeset,
    ScheduleOccurrenceChangeset
  }

  alias Responder.Work.{
    ActivityEvent,
    Cancellation,
    Custody,
    DeliveryReceipt,
    Measurement,
    Result,
    Session,
    SubmissionBuilder
  }

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

    first_event =
      Repo.one!(
        from(event in Responder.Episodes.Event,
          where: event.episode_id == ^target.episode.id and event.sequence == 1
        )
      )

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U-TRACE"},
               channel_ref: "C456",
               content: %{"text" => "raw-secret-value"},
               event_kind: :message,
               event_ref: "Ev-control-trace-input",
               message_ref: "1787832099.000300",
               occurred_at: @now,
               revision: 2,
               thread_ref: target.episode.destination_thread_ref,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    decision = %{
      "action" => "start_episode",
      "episode_ref" => target.episode.key,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "Material work is required.",
      "work_class" => "standard"
    }

    Repo.update_all(
      from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :start_episode,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:trace-input",
        dedupe_key: first_event.dedupe_key,
        episode_id: target.episode.id,
        status: :decided
      ]
    )

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
    assert Enum.map(detail.trace.chapters, & &1.title) == ["What came in"]
    assert Enum.map(detail.trace.steps, & &1.title) == ["Input admitted", "Input wait started"]
    assert detail.trace.stopped.headline == "Waiting for a person"
    assert detail.trace.stopped.action == "Reply in the bound conversation"
    assert detail.episode.next_action == "operator input"
    assert detail.trace.source.transport == "Slack"
    assert detail.trace.source.href == "https://slack.com/archives/C456/p1787832099000300"

    assert Enum.any?(
             detail.trace.metrics,
             &(&1.label == "State" and &1.value == "waiting for input")
           )

    refute inspect(detail) =~ "raw-secret-value"
    refute Map.has_key?(detail, :payload)
  end

  test "GitHub source links contain only destination metadata while the conversation retains its message" do
    id = Ecto.UUID.generate()

    assert {:ok, input} =
             GenericInput.new(%{
               actor: %{kind: :user, ref: "github-user:7"},
               content: %{
                 "delivery_ref" => "delivery-github-trace",
                 "event_name" => "issue_comment",
                 "payload" => %{
                   "comment" => %{"body" => "github-secret-body", "id" => 9_001},
                   "issue" => %{"number" => 42, "pull_request" => %{"url" => "withheld"}},
                   "repository" => %{"full_name" => "acme/responder"}
                 }
               },
               destination: %{
                 conversation_ref: "github:github-main:repository:99",
                 thread_ref: "github:github-main:pull:42",
                 transport: "github"
               },
               event_kind: :message,
               event_ref: "github-body:#{String.duplicate("a", 64)}",
               native_input_id: "github-item:#{String.duplicate("b", 64)}",
               occurred_at: @now,
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: "github", ref: "github-main"},
               source_capabilities: %{
                 "react" => %{
                   "emoji_names" => ~w(+1 -1 confused eyes heart hooray laugh rocket)
                 }
               },
               source_item_ref: "github:issue_comment:9001"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: input.destination,
                 episode_id: id,
                 episode_key: "github-trace:#{id}",
                 native_input_id: input.native_input_id,
                 occurred_at: input.occurred_at,
                 payload: GenericInput.document(input),
                 revision: input.revision,
                 turn_ref: "github-trace-turn:#{id}"
               })
             )

    first_event =
      Repo.one!(
        from(event in Responder.Episodes.Event,
          where: event.episode_id == ^id and event.sequence == 1
        )
      )

    Repo.update_all(
      from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :start_episode,
        decision_document: %{
          "action" => "start_episode",
          "episode_ref" => transition.episode.key,
          "reaction" => nil,
          "relation" => "unrelated",
          "reason" => "Material work is required.",
          "work_class" => "standard"
        },
        decision_fingerprint:
          CanonicalJSON.digest(%{
            "action" => "start_episode",
            "episode_ref" => transition.episode.key,
            "reaction" => nil,
            "relation" => "unrelated",
            "reason" => "Material work is required.",
            "work_class" => "standard"
          }),
        decision_ref: "decision:github-trace:#{id}",
        dedupe_key: first_event.dedupe_key,
        episode_id: id,
        status: :decided
      ]
    )

    assert {:ok, detail} = Projection.episode(transition.episode.key)

    assert detail.trace.source == %{
             href: "https://github.com/acme/responder/pull/42#issuecomment-9001",
             label: "Open source comment",
             transport: "GitHub"
           }

    # inspect(trace) truncates maps and made this depend on map iteration order.
    # The source link must omit the body; the readable conversation intentionally
    # includes it, just as it does for Slack and Lab messages.
    refute inspect(detail.trace.source, limit: :infinity) =~ "github-secret-body"
    assert [%{text: "github-secret-body"}] = detail.trace.case_file.messages

    for {source_item_ref, payload, expected} <- [
          {
            "github:pull_request_review_comment:9002",
            %{
              "comment" => %{"body" => "review-comment-secret", "id" => 9_002},
              "pull_request" => %{"number" => 43},
              "repository" => %{"full_name" => "acme/responder"}
            },
            "https://github.com/acme/responder/pull/43#discussion_r9002"
          },
          {
            "github:issue_comment:9003",
            %{
              "comment" => %{"body" => "issue-comment-secret", "id" => 9_003},
              "issue" => %{"number" => 44},
              "repository" => %{"full_name" => "acme/responder"}
            },
            "https://github.com/acme/responder/issues/44#issuecomment-9003"
          },
          {
            "github:pull_request_review:9004",
            %{
              "pull_request" => %{"number" => 45},
              "repository" => %{"full_name" => "acme/responder"},
              "review" => %{"body" => "review-secret", "id" => 9_004}
            },
            "https://github.com/acme/responder/pull/45#pullrequestreview-9004"
          }
        ] do
      Repo.update_all(
        from(saved in Entry, where: saved.id == ^entry.id),
        set: [content: %{"payload" => payload}, source_item_ref: source_item_ref]
      )

      assert {:ok, linked} = Projection.episode(transition.episode.key)
      assert linked.trace.source.href == expected
      refute inspect(linked.trace.source, limit: :infinity) =~ "secret"
    end

    for {source_item_ref, repository} <- [
          {"github:pull_request_review:9005", "not a repository"},
          {"github:unsupported:9005", "acme/responder"}
        ] do
      Repo.update_all(
        from(saved in Entry, where: saved.id == ^entry.id),
        set: [
          content: %{
            "payload" => %{
              "pull_request" => %{"number" => 46},
              "repository" => %{"full_name" => repository},
              "review" => %{"id" => 9_005}
            }
          },
          source_item_ref: source_item_ref
        ]
      )

      assert {:ok, unlinked} = Projection.episode(transition.episode.key)
      assert unlinked.trace.source == nil
    end
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

    assert {:ok, detail} = Projection.episode(episode_key!(measured.episode_id))
    prepared = Enum.find(detail.trace.steps, &(&1.title == "Turn 1 queued"))
    prepared_details = Map.new(prepared.details, &{&1.label, &1.value})

    assert Map.keys(prepared_details) |> Enum.sort() == ["Policy", "Turn"]
    assert prepared.state == ""
    refute inspect(detail.trace) =~ "redacted by projection"

    assert Enum.any?(detail.trace.steps, &(&1.title == "Turn 1 finished"))
    # A completed execution used to be stamped at its start, above tools it had not run yet.
    model_work = Enum.find(detail.trace.steps, &(&1.title == "Turn 1 finished"))
    assert model_work.at == measured.remote_finished_at
    # validate_final can finish before the model returns its answer; that is
    # still work, not evidence of an already-delivered answer.
    for {offset, band} <- [{-1, :work}, {1, :answer}] do
      history = [
        %{
          "verdict" => "accept",
          "candidate_attempt" => 1,
          "recorded_at" => DateTime.to_iso8601(DateTime.add(measured.remote_finished_at, offset))
        }
      ]

      Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^measured.id),
        set: [validation_history: history]
      )

      {:ok, checked} = Projection.episode(episode_key!(measured.episode_id))
      validation = Enum.find(checked.trace.steps, &(&1.title == "Answer validated"))
      assert validation.band == band
    end

    Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^measured.id),
      set: [validation_history: measured.validation_history]
    )

    assert Enum.any?(detail.trace.steps, &(&1.title == "Answer validated"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Turn 1 result accepted"))
    assert Enum.any?(detail.trace.chapters, &(&1.title == "The answer"))

    for {candidate, parse} <- [
          {Jason.encode!(%{"delivery" => "none"}), "JSON object"},
          {Jason.encode!(["not", "an", "object"]), "JSON value; object required"},
          {"not-json", "invalid JSON"}
        ] do
      candidate_sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

      Repo.update_all(
        from(saved in Responder.Work.Turn, where: saved.id == ^measured.id),
        set: [
          candidate: candidate,
          candidate_sha256: candidate_sha256,
          validation_history: []
        ]
      )

      assert {:ok, legacy_detail} = Projection.episode(episode_key!(measured.episode_id))
      validation = Enum.find(legacy_detail.trace.steps, &(&1.title == "Answer validated"))
      validation_details = Map.new(validation.details, &{&1.label, &1.value})
      assert validation_details["Parse"] == parse
    end

    current = Repo.get!(Responder.Work.Turn, measured.id)

    validation_history = [
      %{
        "candidate_attempt" => 1,
        "candidate_sha256" => current.candidate_sha256,
        "intent_fingerprint" => current.validation_intent_fingerprint,
        "parse" => "JSON object",
        "recorded_at" => "invalid-time",
        "response_bytes" => 120,
        "verdict" => "reject",
        "violations" => []
      },
      %{
        "candidate_attempt" => 2,
        "candidate_sha256" => current.candidate_sha256,
        "intent_fingerprint" => current.validation_intent_fingerprint,
        "parse" => "JSON object",
        "recorded_at" => DateTime.to_iso8601(now),
        "response_bytes" => 124,
        "verdict" => "reject",
        "violations" => ["Supply the missing evidence."]
      },
      %{
        "candidate_attempt" => 3,
        "candidate_sha256" => current.candidate_sha256,
        "intent_fingerprint" => current.validation_intent_fingerprint,
        "parse" => "JSON object",
        "recorded_at" => DateTime.to_iso8601(now),
        "response_bytes" => 128,
        "verdict" => "accept",
        "violations" => []
      }
    ]

    Repo.update_all(
      from(saved in Responder.Work.Turn, where: saved.id == ^measured.id),
      set: [validation_history: validation_history]
    )

    assert {:ok, validation_detail} = Projection.episode(episode_key!(measured.episode_id))
    validation_steps = Enum.filter(validation_detail.trace.steps, &(&1.stage == "Validation"))

    assert Enum.map(validation_steps, & &1.summary) == [
             "Supply the missing evidence.",
             "The response passed the checks for this attempt.",
             "Responder rejected this candidate and requested a same-turn correction."
           ]

    for {workspace_task, expected} <- [
          {%{"repository" => "acme/responder"}, "acme/responder"},
          {%{"primary" => %{"name" => "responder-primary"}}, "responder-primary"}
        ] do
      Repo.update_all(
        from(saved in Responder.Work.Session, where: saved.id == ^measured.session_id),
        set: [workspace_task: workspace_task]
      )

      assert {:ok, workspace_detail} = Projection.episode(episode_key!(measured.episode_id))

      session_step =
        Enum.find(workspace_detail.trace.steps, &(&1.title == "Workspace selected"))

      session_details = Map.new(session_step.details, &{&1.label, &1.value})
      assert session_details["Workspace target"] == expected
    end

    for {provider_ms, expected} <- [{120_000, "2m"}, {7_200_000, "2h"}] do
      Repo.update_all(
        from(saved in Responder.Work.Turn, where: saved.id == ^measured.id),
        set: [usage_provider_ms: provider_ms]
      )

      assert {:ok, duration_detail} = Projection.episode(episode_key!(measured.episode_id))
      work_step = Enum.find(duration_detail.trace.steps, &(&1.title == "Turn 1 finished"))
      work_details = Map.new(work_step.details, &{&1.label, &1.value})
      assert work_details["Provider"] == expected
    end

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

  test "cost and power-user totals follow each triggering input without double counting" do
    # Thread-level attribution assigned follow-up work to the first speaker;
    # missing provider USD also hid all usable retained token measurements.
    now = DateTime.utc_now()
    first = measured_turn!("person-one", "codex:gpt-5.6-sol/medium", now)
    second = measured_turn!("person-two", "codex:gpt-5.6-sol/medium", now)

    for {turn, actor, message_ref} <- [
          {first, "U123", "1787832099.000100"},
          {second, "U456", "1787832100.000100"}
        ] do
      {:ok, input} =
        SlackInput.new(%{
          actor: %{kind: :user, ref: actor},
          channel_ref: "C456",
          content: %{"text" => "Usage attribution"},
          event_kind: :message,
          event_ref: "Ev-#{actor}",
          message_ref: message_ref,
          occurred_at: now,
          revision: 1,
          thread_ref: "1787832099.000100",
          workspace_ref: "T123"
        })

      {:ok, %{entry: entry}} = Inbox.record(input)

      Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^turn.id),
        set: [turn_ref: "ingress-turn:#{entry.id}"]
      )
    end

    Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^second.id),
      set: [usage_cost_recorded: false, usage_cost_usd: nil]
    )

    Repo.update_all(
      from(e in Responder.Accounting.Execution,
        where: e.kind == "work" and e.source_id == ^second.id
      ),
      set: [usage_cost_recorded: false, usage_cost_usd: nil]
    )

    snapshot = Projection.usage(%{"window" => "24h"})
    assert snapshot.totals.costed == 1
    assert snapshot.totals.estimated == 1
    assert Decimal.equal?(snapshot.totals.cost_usd, Decimal.new("0.0125"))
    assert Decimal.equal?(snapshot.totals.estimated_cost_usd, Decimal.new("0.01112"))

    assert Enum.sort(Enum.map(snapshot.users, &{&1.actor, &1.attempts, &1.costed, &1.estimated})) ==
             [{"U123", 1, 1, 0}, {"U456", 1, 0, 1}]

    assert [%{attempts: 2, costed: 1, estimated: 1}] = snapshot.targets
    assert Enum.reduce(snapshot.channels, 0, &(&1.attempts + &2)) == 2
  end

  test "people exclude apps bots system hooks and the shared Lab operator without losing their usage" do
    # Emisar showed local-operator, an app, and the universal webhook as people.
    # Use the retained actor type, not a display name or a platform-ID prefix.
    now = DateTime.utc_now()

    senders = [
      {"slack", :user, "U0BHTNFCW6S"},
      {"slack", :app, "A0BL6UCCBGR"},
      {"webhook", :system, "universal"},
      {"control_plane", :user, "local-operator"},
      {"github", :user, "andrew"},
      {"github", :bot, "andrew"}
    ]

    for {{source, kind, actor}, index} <- Enum.with_index(senders) do
      {:ok, input} =
        Responder.Ingress.Input.new(%{
          actor: %{kind: kind, ref: actor},
          content: %{"text" => "Usage attribution"},
          destination: %{
            transport: source,
            conversation_ref: "#{source}:emisar:test",
            thread_ref: nil
          },
          event_kind: :message,
          event_ref: "people-#{index}",
          native_input_id: "people-#{index}",
          occurred_at: now,
          occurred_at_source: :source,
          revision: 1,
          source: %{kind: source, ref: "emisar"},
          source_capabilities: %{},
          source_item_ref: "people-#{index}"
        })

      {:ok, %{entry: entry}} = Inbox.record(input)
      turn = measured_turn!("people-#{index}", "codex:gpt-5.6-sol/medium@emisar", now)

      Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^turn.id),
        set: [turn_ref: "ingress-turn:#{entry.id}"]
      )

      Repo.insert!(%Responder.Accounting.Execution{
        kind: "admission",
        source_id: entry.id,
        generation: "1",
        transport: source,
        conversation_ref: input.destination.conversation_ref,
        execution_mode: "live",
        status: "completed",
        execution_target: "codex:gpt-5.6-luna/low@emisar",
        usage_recorded: true,
        usage_input_tokens: 10,
        recorded_at: now
      })
    end

    # A legacy execution with no retained sender must not invent a person either.
    measured_turn!("people-missing", "codex:gpt-5.6-sol/medium@emisar", now)
    snapshot = Projection.usage(%{})

    assert Enum.sort(Enum.map(snapshot.users, &{&1.source, &1.actor, &1.attempts})) == [
             {"github", "andrew", 2},
             {"slack", "U0BHTNFCW6S", 2}
           ]

    assert snapshot.totals.attempts == 13
    assert snapshot.totals.tokens == 16_160
    assert Enum.sum(Enum.map(snapshot.profiles, & &1.attempts)) == 13

    document = snapshot |> HTML.usage() |> IO.iodata_to_binary() |> LazyHTML.from_document()
    people = LazyHTML.query(document, "#usage-people")

    for label <- ["Conversation Lab", "universal", "Slack app", "without a saved person"],
        do: refute(LazyHTML.text(people) =~ label)

    params =
      people
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> Enum.map(&URI.decode_query(URI.parse(&1).query))
      |> Enum.find(&(&1["usage_source"] == "github"))

    assert params["usage_actor_kind"] == "user"
    # A bot with the same account name cannot sneak back into the drilldown.
    assert Activity.list(params).total == 2

    options = UsageProjection.filter_options()

    assert Enum.all?(
             options,
             &(Map.keys(&1) -- ~w(source workspace actor actor_kind transport conversation_ref)a ==
                 [])
           )

    controls =
      Phoenix.LiveViewTest.render_component(&RequestFilters.render/1, %{
        draft:
          RequestFilters.draft(%{
            "usage_actor" => "andrew",
            "usage_channel" => "slack:emisar:test"
          }),
        values: options,
        params: %{},
        path: "/episodes"
      })
      |> LazyHTML.from_document()

    actors =
      controls |> LazyHTML.query("#criterion-usage_actor option") |> LazyHTML.attribute("value")

    assert Enum.sort(actors) == ["", "U0BHTNFCW6S", "andrew"]

    channels =
      controls |> LazyHTML.query("#criterion-usage_channel option") |> LazyHTML.attribute("value")

    assert "slack:emisar:test" in channels
    refute "control_plane:emisar:test" in channels
  end

  # Subscription use disappeared behind model labels; reasoning was also added
  # twice to the headline and every breakdown despite being part of output.
  test "usage attributes concrete profiles and counts reasoning only within output" do
    now = DateTime.utc_now()
    measured_turn!("profile-a", "codex:gpt-5.6-sol/medium@emisar", now)
    measured_turn!("profile-b", "codex:gpt-5.6-terra/medium@emisar", now)
    measured_turn!("profile-c", "codex:gpt-5.6-sol/medium@personal", now)
    measured_turn!("profile-unknown", "codex:gpt-5.6-sol/medium", now, false)

    snapshot = Projection.usage(%{"window" => "24h"})
    assert snapshot.totals.tokens == 6_900
    assert snapshot.totals.episodes == 4
    assert snapshot.totals.reasoning_tokens == 75
    assert Enum.sum(Enum.map(snapshot.days, & &1.tokens)) == 6_900
    assert Enum.sum(Enum.map(snapshot.channels, & &1.tokens)) == 6_900
    assert Enum.sum(Enum.map(snapshot.repositories, & &1.tokens)) == 6_900
    assert Enum.sum(Enum.map(snapshot.kinds, & &1.tokens)) == 6_900
    assert Enum.sum(Enum.map(snapshot.profiles, & &1.tokens)) == 6_900

    emisar = Enum.find(snapshot.profiles, &(&1.profile == "emisar"))
    assert emisar.provider == "codex"
    assert emisar.attempts == 2
    assert emisar.episodes == 2
    assert emisar.input_tokens == 2_400
    assert emisar.cached_input_tokens == 1_600
    assert emisar.output_tokens == 600
    assert emisar.cache_hit_rate == 0.4
    assert Decimal.equal?(emisar.cost_usd, Decimal.new("0.025"))
    refute Map.has_key?(emisar, :models)
    assert Enum.find(snapshot.profiles, &is_nil(&1.profile)).usage_measured == 0

    assert Activity.list(%{
             "usage_profile" => "emisar",
             "usage_provider" => "codex",
             "usage_window" => "24h"
           }).total == 2

    assert Activity.list(%{
             "usage_profile" => "personal",
             "usage_provider" => "codex"
           }).total == 1

    assert Activity.list(%{
             "usage_profile" => "emisar",
             "usage_provider" => "claude"
           }).total == 0

    assert Activity.list(%{
             "usage_profile" => "",
             "usage_provider" => "codex"
           }).total == 1
  end

  test "profile attribution never guesses a credential from an account ladder" do
    measured_turn!("profile-ladder", "codex:gpt-5.6-sol/medium@work,personal", DateTime.utc_now())
    snapshot = Projection.usage(%{"window" => "24h"})
    assert [%{profile: nil, attempts: 1}] = snapshot.profiles
    assert Activity.list(%{"usage_profile" => %{"unexpected" => "nested query"}}).total == 0
    assert Activity.list(%{"usage_profile" => String.duplicate("x", 513)}).total == 0
    assert Activity.list(%{"usage_profile" => "", "usage_window" => "all"}).total == 1
    assert Activity.list(%{"usage_profile" => "", "usage_window" => "30d"}).total == 1
  end

  test "the usage period filters requests without requiring another usage dimension" do
    # A visible period picker must not silently show executions outside that period.
    now = DateTime.utc_now()
    measured_turn!("recent-period", "codex:gpt-5.6-sol/medium@emisar", now)
    old_time = DateTime.add(now, -10, :day)
    old = measured_turn!("old-period", "codex:gpt-5.6-sol/medium@emisar", old_time)

    # The ledger captures the host submission time, independently of provider timing.
    Repo.update_all(from(e in Responder.Accounting.Execution, where: e.source_id == ^old.id),
      set: [recorded_at: old_time]
    )

    assert Activity.list(%{"usage_window" => "24h"}).total == 1
    assert Activity.list(%{"usage_window" => "all"}).total == 2
  end

  test "missing model links find executions whose target was never recorded" do
    # Unknown targets previously linked to the nonexistent literal model "default".
    measured_turn!("missing-target", nil, DateTime.utc_now())
    measured_turn!("known-target", "codex:gpt-5.6-sol/medium@emisar", DateTime.utc_now())

    html = Projection.usage(%{}) |> HTML.usage() |> IO.iodata_to_binary()
    document = LazyHTML.from_document(html)

    params =
      document
      |> LazyHTML.query("#usage-models a")
      |> LazyHTML.attribute("href")
      |> Enum.map(&(URI.parse(&1).query |> URI.decode_query()))
      |> Enum.find(fn params -> params["usage_model"] == "" end)

    assert params, "The unknown target must use the nullable target filter"
    assert Activity.list(params).total == 1

    missing =
      RequestFilters.apply(%{}, %{
        "criteria" => %{
          "usage_provider" => %{"match" => "missing"},
          "usage_work_kind" => %{"match" => "missing"}
        }
      })

    assert Activity.list(missing).total == 1
  end

  test "model comparison and its drilldowns keep effort levels distinct across profiles" do
    # Combining medium and high hid the actual latency and cost tradeoff.
    now = DateTime.utc_now()

    for {suffix, target} <- [
          {"medium-a", "codex:gpt-5.6-sol/medium@emisar"},
          {"medium-b", "codex:gpt-5.6-sol/medium@personal"},
          {"high", "codex:gpt-5.6-sol/high@emisar"},
          {"missing-effort", "codex:gpt-5.6-sol@emisar"}
        ],
        do: measured_turn!(suffix, target, now)

    snapshot = Projection.usage(%{})

    assert Enum.sort(Enum.map(snapshot.models, &{Map.get(&1, :effort), &1.attempts})) ==
             [{nil, 1}, {"high", 1}, {"medium", 2}]

    document = snapshot |> HTML.usage() |> IO.iodata_to_binary() |> LazyHTML.from_document()

    for href <- document |> LazyHTML.query("#usage-models a") |> LazyHTML.attribute("href") do
      params = URI.decode_query(URI.parse(href).query)
      assert Map.has_key?(params, "usage_effort")
      assert Activity.list(params).total == if(params["usage_effort"] == "medium", do: 2, else: 1)
    end

    assert Activity.list(%{"usage_effort" => %{"bad" => "query"}}).total == 0
    assert Activity.list(%{"usage_effort" => String.duplicate("x", 513)}).total == 0
  end

  test "the channel breakdown contains only Slack without excluding Lab from overall usage" do
    now = DateTime.utc_now()

    for suffix <- ["lab-one", "lab-two"] do
      turn = measured_turn!(suffix, "codex:gpt-5.6-sol/medium", now)

      Repo.update_all(
        from(e in Responder.Accounting.Execution, where: e.source_id == ^turn.id),
        set: [transport: "control_plane", conversation_ref: "control-plane:lab:#{suffix}"]
      )
    end

    measured_turn!("slack-one", "codex:gpt-5.6-sol/medium", now)
    snapshot = Projection.usage(%{"window" => "24h"})

    assert [%{attempts: 1, conversation_ref: "slack:T123:C456"}] =
             snapshot.channels

    assert snapshot.totals.attempts == 3
  end

  test "usage includes live and evaluation work unless the operator narrows the scope" do
    turn = measured_turn!("all-mode", "codex:gpt-5.6-sol/medium@emisar", DateTime.utc_now())

    Repo.update_all(from(e in Responder.Accounting.Execution, where: e.source_id == ^turn.id),
      set: [execution_mode: "shadow"]
    )

    assert Projection.usage(%{}).totals.attempts == 1
    assert Projection.usage(%{}).mode == "all"
    assert Projection.usage(%{"mode" => "live"}).totals.attempts == 0
    assert Projection.usage(%{"mode" => "shadow"}).totals.attempts == 1
    refute Map.has_key?(Projection.usage(%{}), :executions)
    assert Activity.list(%{"usage_measurement" => "missing"}).total == 0
  end

  test "missing measurement drilldowns find only requests with missing reports" do
    missing = measured_turn!("missing-report", "codex:gpt-5.6-sol/medium", DateTime.utc_now())
    measured_turn!("measured-report", "codex:gpt-5.6-sol/medium", DateTime.utc_now())

    Repo.update_all(from(e in Responder.Accounting.Execution, where: e.source_id == ^missing.id),
      set: [usage_recorded: false]
    )

    result = Activity.list(%{"usage_measurement" => "missing", "mode" => "all"})
    assert result.total == 1
    assert hd(result.items).id == missing.episode_id
    assert Activity.list(%{"usage_measurement" => "measured", "mode" => "all"}).total == 1
    assert Activity.list(%{"usage_measurement" => %{"bad" => "query"}}).total == 0
  end

  # Provider work still costs money when the host never accepts the answer.
  # The old accepted_at predicate hid these executions entirely.
  test "failed and cancelled executions remain visible in cost accounting" do
    now = DateTime.utc_now()
    failed = measured_turn!("failed-cost", "codex:gpt-5.6-terra/medium", now)
    cancelled = measured_turn!("cancelled-cost", "codex:gpt-5.6-terra/medium", now)

    for {turn, status} <- [{failed, :blocked}, {cancelled, :superseded}] do
      Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^turn.id),
        set: [
          accepted_at: nil,
          status: status,
          validation_receipt: nil,
          result_ref: nil,
          continuation: nil
        ]
      )
    end

    snapshot = Projection.usage(%{"window" => "24h"})
    assert snapshot.totals.attempts == 2
    assert snapshot.totals.usage_measured == 2
    assert Decimal.equal?(snapshot.totals.cost_usd, Decimal.new("0.025"))
  end

  test "episode trace distinguishes a pending reply from confirmed delivery" do
    accepted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    turn =
      measured_turn!(
        "visible-reply",
        "codex:gpt-5.6-terra/medium@work",
        accepted_at,
        true,
        :reply
      )

    episode = Repo.get!(Responder.Episodes.Episode, turn.episode_id)
    secret = "trace-password-that-must-not-render"
    previous = Application.get_env(:responder, :episode_trace_test)
    Application.put_env(:responder, :episode_trace_test, %{token: secret})

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:responder, :episode_trace_test),
        else: Application.put_env(:responder, :episode_trace_test, previous)
    end)

    document = %{
      "delivery" => "reply",
      "message" =>
        "Done. password=#{secret} https://operator:private@example.com/result?token=hidden#fragment",
      "outcome" => %{"artifact_refs" => ["artifact:one"], "record_refs" => []}
    }

    Repo.update_all(
      from(saved in Responder.Work.Turn, where: saved.id == ^turn.id),
      set: [delivery_document: document]
    )

    assert {:ok, pending} = Projection.episode(episode.key)
    assert Enum.any?(pending.trace.steps, &(&1.title == "Reply delivery pending"))
    assert Enum.any?(pending.trace.steps, &(&1.summary =~ "waiting for transport"))
    accepted = Enum.find(pending.trace.steps, &(&1.title == "Turn 1 result accepted"))
    accepted_details = Map.new(accepted.details, &{&1.label, &1.value})
    assert accepted.summary == "Responder accepted this response for delivery."
    refute Map.has_key?(accepted_details, "Reply preview")

    assert pending.trace.case_file.reply ==
             "Done. password=[redacted] https://example.com/result"

    rendered = inspect(pending.trace, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ secret
    refute rendered =~ "operator:private"
    refute rendered =~ "token=hidden"

    assert {:ok, delivery} = Custody.claim_next("trace:delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               turn.delivery_ref,
               episode.destination_transport,
               episode.destination_conversation_ref,
               episode.destination_thread_ref,
               "message:trace:#{turn.id}"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    assert settled.turn.status == :settled
    assert {:ok, delivered} = Projection.episode(episode.key)
    assert Enum.any?(delivered.trace.steps, &(&1.title == "Reply delivered"))
    assert Enum.any?(delivered.trace.steps, &(&1.summary =~ "exact destination"))
  end

  test "episode trace tolerates nonliteral runtime config shapes while redacting replies" do
    # A Slack client and then a tuple-keyed runtime map each made every live episode detail return HTTP 500.
    accepted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    turn =
      measured_turn!(
        "opaque-runtime-client",
        "codex:gpt-5.6-terra/medium@work",
        accepted_at,
        true,
        :reply
      )

    episode = Repo.get!(Responder.Episodes.Episode, turn.episode_id)
    key = :episode_trace_struct_regression
    previous = Application.get_env(:responder, key, :missing)

    Application.put_env(
      :responder,
      key,
      %{
        :client => %Responder.Slack.Client{http: :opaque, requester: Responder.Slack.Client},
        {"read_only", nil} => []
      }
    )

    on_exit(fn ->
      if previous == :missing,
        do: Application.delete_env(:responder, key),
        else: Application.put_env(:responder, key, previous)
    end)

    Repo.update_all(
      from(saved in Responder.Work.Turn, where: saved.id == ^turn.id),
      set: [delivery_document: %{"delivery" => "reply", "message" => "A safe reply"}]
    )

    assert {:ok, detail} = Projection.episode(episode.key)
    assert detail.trace.case_file.reply == "A safe reply"
  end

  test "projects every kernel lifecycle and blocked work custody without model payloads" do
    working = start_episode!("working")

    assert {:ok, session} =
             Custody.pin_episode(working.episode.id, "policy:read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("control-plane:test", 60, :work)

    record_activity!(working.episode.id, session.id, 1, "model.thought", %{})

    record_activity!(working.episode.id, session.id, 2, "tool.started", %{
      "input" => %{
        "operation" => "nomad.job_status",
        "server" => "emisar",
        "tool" => "run_action"
      },
      "tool_call_id" => "tool:nomad"
    })

    {:ok, before_completion} = Projection.episode(working.episode.key)
    started = Enum.find(before_completion.trace.steps, &(&1.stage == "Tool call"))

    record_activity!(working.episode.id, session.id, 3, "tool.completed", %{
      "status" => "completed",
      "tool_call_id" => "tool:nomad"
    })

    # A completed tool was previously rewritten into its earlier start card.
    {:ok, after_completion} = Projection.episode(working.episode.key)
    assert Enum.find(after_completion.trace.steps, &(&1.id == started.id)) == started

    assert Enum.any?(
             after_completion.trace.steps,
             &(&1.stage == "Tool call" && &1.state == "completed" && &1.at > started.at)
           )

    record_activity!(working.episode.id, session.id, 4, "tool.completed", %{
      "status" => "failed",
      "tool_call_id" => "tool:orphan"
    })

    record_activity!(working.episode.id, session.id, 5, "model.plan", %{"step_count" => 2})

    record_activity!(working.episode.id, session.id, 6, "permission.decided", %{
      "option_kind" => "cancel",
      "outcome" => "cancelled",
      "tool_call_id" => "tool:permission"
    })

    record_activity!(working.episode.id, session.id, 7, "activity.elided", %{
      "dropped" => 12
    })

    record_activity!(working.episode.id, session.id, 8, "provider.backoff", %{
      "reset_at" => "2026-08-28T12:05:00Z",
      "target" => "codex:gpt-5.6-sol/medium"
    })

    record_activity!(working.episode.id, session.id, 9, "provider.alive", %{
      "bytes" => 4_096,
      "frames" => 8
    })

    record_activity!(working.episode.id, session.id, 10, "tool.started", %{
      "input" => %{
        "arguments" => %{
          "cmd" => "git status --short",
          "token" => "must-not-render-tool-secret"
        }
      },
      "kind" => "command",
      "title" => "Inspect repository status",
      "tool_call_id" => "tool:status"
    })

    record_activity!(working.episode.id, session.id, 11, "custom.notice", %{})
    record_activity!(working.episode.id, session.id, 12, "tool.started", %{})
    record_activity!(working.episode.id, session.id, 13, "permission.decided", %{})
    record_activity!(working.episode.id, session.id, 14, "provider.backoff", %{})
    record_activity!(working.episode.id, session.id, 15, "provider.alive", %{})

    record_activity!(working.episode.id, session.id, 16, "model.plan", %{"entries" => ["invalid"]})

    record_activity!(working.episode.id, session.id, 17, "permission.decided", %{
      "outcome" => "selected"
    })

    record_activity!(working.episode.id, session.id, 18, "provider.alive", %{
      "detail" => String.duplicate("x", 600),
      "items" => [1, "frame", %{"token" => "must-not-render-nested-secret"}],
      "optional" => nil
    })

    record_activity!(working.episode.id, session.id, 19, "tool.started", %{
      "input" => %{"path" => "lib/responder/control_plane"}
    })

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

    assert {:ok, _evidence} =
             Records.create(Records.token(claim.turn), "evidence-one", "evidence", %{
               "claim_id" => "runtime.ready",
               "observation" => "The current allocation is healthy.",
               "source_name" => "Nomad",
               "source_type" => "monitoring"
             })

    assert {:ok, _coverage} =
             Records.create(Records.token(claim.turn), "coverage-one", "coverage", %{
               "claim_ids" => ["runtime.ready"],
               "detail" => "The active allocation was inspected.",
               "layer" => "runtime",
               "observed_at" => DateTime.to_iso8601(@now),
               "source" => "Nomad",
               "status" => "healthy"
             })

    assert {:ok, _goal_state} =
             Records.create(Records.token(claim.turn), "goal-state-one", "goal_state", %{
               "goal_id" => "verify-runtime",
               "state" => "blocked"
             })

    assert {:ok, _input_request} =
             Records.create(Records.token(claim.turn), "input-request-one", "input_request", %{
               "choices" => ["Retry", "Stop"],
               "question" => "How should the operator proceed?"
             })

    assert {:ok, _event_wait} =
             Records.create(Records.token(claim.turn), "event-wait-one", "event_wait", %{
               "deadline_at" => "2099-01-01T00:00:00.000000Z",
               "event_matcher" => %{"deployment" => "release-1"},
               "kind" => "deployment",
               "verification" => "Verify the deployed revision."
             })

    assert [%{status: :active, summary: "no repository"}] = Projection.workspaces(%{})

    assert {:ok, detail} = Projection.episode(working.episode.key)
    assert Enum.flat_map(detail.trace.chapters, & &1.steps) == detail.trace.steps

    assert Enum.map(detail.trace.chapters, & &1.band) ==
             detail.trace.steps
             |> Enum.chunk_by(& &1.band)
             |> Enum.map(&List.first(&1).band)

    assert progress.operation_id in Enum.map(detail.records, & &1.summary)
    assert goal.subject_ref in Enum.map(detail.records, & &1.summary)
    assert Enum.any?(detail.trace.steps, &(&1.title == "Progress · investigating"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Goal recorded"))
    assert Enum.any?(detail.trace.steps, &(&1.stage == "Evidence"))
    assert Enum.any?(detail.trace.steps, &(&1.stage == "Coverage"))
    assert Enum.any?(detail.trace.steps, &(&1.stage == "Plan" and &1.state == ""))
    assert Enum.any?(detail.trace.steps, &(&1.stage == "Wait"))

    assert Enum.any?(
             detail.trace.steps,
             &(&1.title == "emisar · nomad.job_status" and &1.duration_ms == 1_000)
           )

    refute Enum.any?(detail.trace.steps, &(&1.title == "Model reasoning checkpoint"))

    assert Enum.any?(detail.trace.steps, &(&1.title == "Model plan updated"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Tool permission decided"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Some activity was elided"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Provider rate limit"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Provider is still responding"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Custom.notice"))
    assert Enum.any?(detail.trace.steps, &(&1.title == "Tool call"))
    refute inspect(detail.trace) =~ "must-not-render"
    refute inspect(detail.trace) =~ "password"
    refute inspect(detail.trace) =~ "token=private"

    assert Enum.any?(
             detail.trace.metrics,
             &(&1.label == "Tool calls" and &1.value == "4")
           )

    assert detail.trace.activity == %{shown: 19, tool_calls: 4, total: 19, truncated: false}

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

    assert {:ok, blocked_detail} = Projection.episode(working.episode.key)
    assert blocked_detail.trace.stopped.headline == "Work needs operator recovery"
    assert blocked_detail.episode.next_action == "operator recovery"

    assert blocked_detail.trace.stopped.href ==
             "/failures/work/#{URI.encode(working.episode.key, &URI.char_unreserved?/1)}"

    assert "1 Work claim" in blocked_detail.trace.stopped.attempted

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

    transferred = start_episode!("transferred")

    assert {:ok, transferred} =
             Episodes.apply(
               EpisodeFixtures.transfer_owner(%{
                 episode_key: transferred.episode.key,
                 expected_owner: %{kind: :turn, ref: transferred.episode.owner_ref},
                 new_owner: %{kind: :turn, ref: "replacement:#{transferred.episode.id}"},
                 transfer_ref: "transfer:#{transferred.episode.id}"
               })
             )

    assert {:ok, transferred_detail} = Projection.episode(transferred.episode.key)
    assert Enum.any?(transferred_detail.trace.steps, &(&1.title == "Owner transferred"))

    resumed = start_episode!("resumed")
    wait_ref = "wait:input:#{resumed.episode.id}"

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: resumed.episode.key,
                 expected_turn_ref: resumed.episode.owner_ref,
                 kind: :input,
                 wait_ref: wait_ref
               })
             )

    answer =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: resumed.episode.destination_conversation_ref,
          thread_ref: resumed.episode.destination_thread_ref,
          transport: resumed.episode.destination_transport
        },
        episode_id: resumed.episode.id,
        episode_key: resumed.episode.key,
        native_input_id: "resume-input:#{resumed.episode.id}",
        payload: %{"text" => "Continue without exposing this input."},
        turn_ref: "ignored:#{resumed.episode.id}"
      })

    assert {:ok, _queued_answer} = Episodes.apply(answer)

    assert {:ok, resumed} =
             Episodes.apply(
               EpisodeFixtures.resume_wait(%{
                 episode_key: resumed.episode.key,
                 expected_wait: %{kind: :input, ref: wait_ref},
                 resolution_ref: Command.dedupe_key(answer),
                 turn_ref: "resumed:#{resumed.episode.id}"
               })
             )

    assert {:ok, resumed_detail} = Projection.episode(resumed.episode.key)
    assert Enum.any?(resumed_detail.trace.steps, &(&1.title == "Wait resumed"))
    refute inspect(resumed_detail.trace) =~ "Continue without exposing"

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

    assert {:ok, waiting_detail} = Projection.episode(waiting_event.episode.key)
    assert waiting_detail.trace.stopped.headline == "Waiting for an external event"

    assert {:ok, delivery_detail} = Projection.episode(delivery.episode.key)
    assert Enum.any?(delivery_detail.trace.steps, &(&1.title == "Result accepted"))

    assert {:ok, complete_detail} = Projection.episode(complete.episode.key)
    assert Enum.any?(complete_detail.trace.steps, &(&1.title == "Result accepted"))

    assert {:ok, cancelled_detail} = Projection.episode(cancelled.episode.key)
    assert cancelled_detail.trace.stopped.headline == "Episode cancelled"

    assert {:ok, _reaction} =
             Episodes.apply(
               EpisodeFixtures.record_reaction(%{
                 episode_key: delivery.episode.key,
                 event_ref: "reaction:#{delivery.episode.id}",
                 target_delivery_ref: "delivery:#{delivery.episode.id}"
               })
             )

    assert {:ok, delivered} =
             Episodes.apply(
               EpisodeFixtures.confirm_delivery(%{
                 episode_key: delivery.episode.key,
                 expected_delivery_ref: "delivery:#{delivery.episode.id}"
               })
             )

    assert delivered.episode.state == :complete
    assert {:ok, delivered_detail} = Projection.episode(delivery.episode.key)
    assert Enum.any?(delivered_detail.trace.steps, &(&1.title == "Delivery confirmed"))
    assert Enum.any?(delivered_detail.trace.steps, &(&1.title == "Reaction recorded"))

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

    assert Projection.findings(%{}) == []
    assert map_size(Projection.callbacks()) == 38
    assert is_function(Projection.callbacks().behavior, 1)
    assert is_function(Projection.callbacks().behaviors, 2)
    refute Map.has_key?(Projection.callbacks(), :audit)
    assert is_function(Projection.callbacks().usage_filter_options, 0)
    assert is_function(Projection.callbacks().model_timeline, 2)
    assert is_function(Projection.callbacks().activity, 1)
    assert is_function(Projection.callbacks().card_lab_slack, 1)
    assert is_function(Projection.callbacks().card_lab_post, 1)
    assert is_function(Projection.callbacks().model_requests, 2)
    assert is_function(Projection.callbacks().admission_request, 2)
  end

  test "operator workbench projections stay bounded and explicit with no durable rows" do
    assert Projection.incidents(%{}) == []
    assert Projection.schedules(%{}) == []
    assert Projection.channels(%{}) == []
    assert Projection.repositories(%{}) == []
    assert Projection.usage(%{"window" => "24h"}).performance == []

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
    assert Projection.usage(:invalid).performance == []
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

    assert {:ok, %{action: post_action}} =
             PlatformActionCustody.enqueue(claim, %{
               conversation_ref: "slack:T123:C456",
               document: %{"message" => "A bounded follow-up."},
               host_slot: "post",
               kind: :message,
               source_item_ref: nil,
               thread_ref: "1787832000.000100",
               tool: :post_slack_message,
               transport: "slack"
             })

    assert {:ok, %{action: slack_reaction}} =
             PlatformActionCustody.enqueue(claim, %{
               conversation_ref: "slack:T123:C456",
               document: %{"action" => "add", "emoji_name" => "eyes"},
               host_slot: "slack-reaction",
               kind: :reaction,
               source_item_ref: "1787832000.000100",
               thread_ref: "1787832000.000100",
               tool: :set_slack_reaction,
               transport: "slack"
             })

    slack_reaction
    |> Ecto.Changeset.change(%{
      last_error_code: "rate_limited",
      last_error_detail: "private platform diagnostic",
      status: :blocked
    })
    |> Repo.update!()

    assert {:ok, %{action: github_reaction}} =
             PlatformActionCustody.enqueue(claim, %{
               conversation_ref: "github:example/responder:pull:42",
               document: %{"action" => "add", "emoji_name" => "eyes"},
               host_slot: "github-reaction",
               kind: :reaction,
               source_item_ref: "review:123",
               thread_ref: nil,
               tool: :set_github_reaction,
               transport: "github"
             })

    github_receipt = %{
      "conversation_ref" => github_reaction.conversation_ref,
      "delivery_ref" => github_reaction.action_ref,
      "message_ref" => github_reaction.source_item_ref,
      "thread_ref" => nil,
      "transport" => "github"
    }

    github_reaction
    |> Ecto.Changeset.change(%{
      delivered_at: now,
      external_receipt: github_receipt,
      external_receipt_fingerprint: CanonicalJSON.digest(github_receipt),
      status: :delivered
    })
    |> Repo.update!()

    assert post_action.status == :pending

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

    subscription =
      %{
        cursor: %{"updated_at" => "private-cursor-marker"},
        deadline_at: DateTime.add(now, 3_600, :second),
        episode_id: source.episode.id,
        id: Ecto.UUID.generate(),
        matcher: %{"secret" => "private-matcher-marker"},
        poll_after: DateTime.add(now, 300, :second),
        record_id: record.id,
        ref: "event-subscription:operator",
        revision: 1,
        source_kind: "github",
        status: :active
      }
      |> EventSubscriptionChangeset.insert()
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

    placement =
      Repo.insert!(%Placement{
        episode_id: source.episode.id,
        generation: 1,
        id: Ecto.UUID.generate(),
        last_acked_event_sequence: 0,
        lease_expires_at: DateTime.add(now, 60, :second),
        lease_ref: "placement:operator",
        requirements: %{},
        requirements_fingerprint: CanonicalJSON.digest(%{}),
        session_id: session.id,
        state: :active,
        worker_id: "operator-worker"
      })

    for {sequence, kind, payload} <- [
          {1, "turn", %{"state" => "running"}},
          {2, "candidate", %{}}
        ] do
      Repo.insert!(%Event{
        kind: kind,
        payload: payload,
        payload_fingerprint: CanonicalJSON.digest(payload),
        placement_generation: placement.generation,
        placement_id: placement.id,
        sequence: sequence,
        session_id: session.id,
        worker_id: placement.worker_id
      })
    end

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

    assert [
             %{
               episode_ref: episode_ref,
               episode_state: :working,
               ref: occurrence_ref,
               trigger: :scheduled,
               turn_status: :pending
             }
           ] = schedule_detail.occurrences

    assert occurrence_ref == occurrence.ref
    assert episode_ref == source.episode.key

    assert [projected_subscription] =
             Projection.subscriptions(%{"q" => "github", "status" => "active"})

    assert projected_subscription.ref == subscription.ref
    assert projected_subscription.episode_ref == source.episode.key
    assert byte_size(projected_subscription.matcher_digest) == 64
    assert byte_size(projected_subscription.cursor_digest) == 64
    refute Map.has_key?(projected_subscription, :matcher)
    refute Map.has_key?(projected_subscription, :cursor)
    refute inspect(projected_subscription) =~ "private-matcher-marker"
    refute inspect(projected_subscription) =~ "private-cursor-marker"

    assert [%{ref: subscription_ref}] = Projection.subscriptions(:all)
    assert subscription_ref == subscription.ref

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

    assert {:ok, episode_detail} = Projection.episode(source.episode.key)
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Operator incident"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Operator publication"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Newer operator publication"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Operator schedule"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Worker · turn"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Worker · candidate"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Additional message"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "Slack reaction"))
    assert Enum.any?(episode_detail.trace.steps, &(&1.title == "GitHub reaction"))
    refute inspect(episode_detail.trace) =~ "private-incident-marker"
    refute inspect(episode_detail.trace) =~ "must-not-render-publication"
    refute inspect(episode_detail.trace) =~ "private platform diagnostic"
  end

  test "usage compares work classes and response corrections without counting transport retries" do
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

    assert %{window: "all", performance: [row]} = Projection.usage(%{"window" => "all"})
    assert row.work_kind == "standard"
    assert row.provider == "codex"
    assert row.model == "gpt-5.6-sol"
    assert row.effort == "medium"
    assert row.attempts == 1
    assert row.measured == 1
    assert row.corrections == 0

    Repo.update_all(from(t in Responder.Work.Turn, where: t.id == ^measured.id),
      set: [validation_history: [%{"candidate_attempt" => 1, "verdict" => "reject"}]]
    )

    assert [%{corrections: 1}] = Projection.usage(%{"window" => "all"}).performance
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

    # Usage reads the frozen execution ledger, not a later mutation of the custody row.
    assert %{performance: [%{average_provider_ms: 5_000}], window: "7d"} =
             Projection.usage(%{"window" => "7d"})
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

    assert {:ok, _blocked} =
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
    refute Map.has_key?(workspace, :discard_plan)
    refute Map.has_key?(workspace, :discard_plan_fingerprint)
    assert workspace in Projection.workspaces(%{})

    fixture = File.read!("testdata/control_plane/legacy_cleanup_failure.json") |> Jason.decode!()

    Repo.update_all(from(saved in Session, where: saved.id == ^session.id),
      set: [
        cleanup_last_error_code: fixture["error_code"],
        cleanup_last_error_detail: fixture["error_detail"],
        cleanup_blocked_from: :plan_pending,
        closed_at: ~U[2026-09-02 13:56:40.115749Z]
      ]
    )

    assert {:ok, failure} = Projection.failure("retention", session.external_ref)

    assert failure.diagnosis == %{
             http_status: 409,
             code: "invalid_session_state",
             reason: :missing_ownership
           }

    assert failure.cleanup_phase == :plan_pending
    assert failure.request_state == :complete
    assert failure.closed_at == ~U[2026-09-02 13:56:40.115749Z]
    assert is_binary(failure.request_title)
    refute inspect(failure) =~ fixture["error_detail"]
    assert {:ok, failures} = Projection.failures(%{})
    assert failure in failures
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

  defp record_activity!(episode_id, session_id, sequence, kind, payload) do
    %ActivityEvent{
      coop_turn_id: "remote-turn:#{session_id}",
      episode_id: episode_id,
      kind: kind,
      occurred_at: DateTime.add(@now, sequence, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "trace-event:#{session_id}:#{sequence}",
      remote_session_id: "remote-session:#{session_id}",
      sequence: sequence,
      session_id: session_id,
      version: 1
    }
    |> Repo.insert!()
  end

  defp measured_turn!(suffix, target, accepted_at, usage? \\ true, delivery \\ :none) do
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

    message = if(delivery == :reply, do: "Investigation complete.")
    decision_reason = if(delivery == :none, do: "No visible reply is required.")

    candidate =
      Jason.encode!(%{
        "decision_reason" => decision_reason,
        "delivery" => Atom.to_string(delivery),
        "message" => message,
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

    result =
      case delivery do
        :none -> Result.new(:none, nil, decision_reason)
        :reply -> Result.new(:reply, %{"message" => message})
      end

    assert {:ok, result} = result

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
