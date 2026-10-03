defmodule Ryker.ControlPlane.WorkSetupCardTest do
  @moduledoc """
  The Work setup card: whether the run's message started or continued the
  request, the environment the work ran in and why, what that environment
  gave it, and the session it ran on.

  The page used to render "Workspace selected" from the local Session row and
  its insertion time, which proves that configuration was pinned and nothing
  else: not that a remote session existed, not that a checkout was ready. Ready
  needs evidence of completed preparation, and a row that only proves selection
  says exactly that.

  Environments are saved through the settings store, which serializes its
  writers on one lock, so this module runs on its own.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{ConversationLab, EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Records
  alias Ryker.Settings
  alias Ryker.Slack.IncidentRoomChangeset
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Custody, Session, Submission, Turn}

  @actor "control-plane:local"
  @now ~U[2026-09-26 09:14:05.000000Z]

  @workspace %{
    "primary" => %{
      "base_commit" => String.duplicate("e36a37b", 6) |> binary_part(0, 40),
      "name" => "ryker",
      "path" => ".",
      "read_only" => false
    },
    "companions" => [
      %{
        "base_commit" => String.duplicate("9bc021a", 6) |> binary_part(0, 40),
        "name" => "coop",
        "path" => "../coop",
        "read_only" => true
      }
    ],
    "freshness" => []
  }

  # The Payments environment's workspace as Coop reports it: its first
  # repository is the working copy and the second is mounted read-only.
  @environment_workspace %{
    "primary" => %{
      "base_commit" => String.duplicate("c1b143d", 6) |> binary_part(0, 40),
      "name" => "payments",
      "path" => ".",
      "read_only" => false
    },
    "companions" => [
      %{
        "base_commit" => String.duplicate("5e0a7f2", 6) |> binary_part(0, 40),
        "name" => "infra",
        "path" => "/coop/repositories/infra",
        "read_only" => true
      }
    ],
    "context_ref" => "payments",
    "parallel_goal_limit" => 1
  }

  test "a ready setup shows no check mark and no word for its state" do
    # Andrew, 2026-09-26: the green check on Work setup said nothing a reader
    # could use. A ready card is the ordinary case and carries no state at
    # all; a card that is not ready still names its state.
    work = submitted!("ready")
    html = rendered(work.episode)
    card = card(html, work.turn)
    document = LazyHTML.from_document(html)
    heading = LazyHTML.query(document, "#event-setup-#{work.turn.id} .case-card-heading")

    assert LazyHTML.query(heading, ".case-card-heading-main > h3") |> LazyHTML.text() ==
             "Work setup"

    assert ready?(html, work.turn)
    assert Enum.empty?(LazyHTML.query(document, "#event-setup-#{work.turn.id} .success-mark"))
    assert Enum.empty?(LazyHTML.query(heading, ".case-card-heading-meta"))
    refute card =~ "Ready"
    assert card =~ "Session"
    assert card =~ "New · the model starts with only this briefing"
    refute html =~ "Workspace selected"
  end

  test "a ready setup says what the model started with and what code it could see, nothing else" do
    # Andrew, 2026-09-24: "what is the meaning of each field? don't we have
    # just one worker and one policy, why so much complexity?" The card listed
    # the session generation, the worker, the execution policy, the workspace
    # and, behind a disclosure larger than its two rows, repository access and
    # "Ryker tools: Bound to this work turn". On a one-worker install the
    # worker and policy are the same on every card; they now appear only when
    # setup failed and they are part of the explanation.
    work = submitted!("details")
    html = rendered(work.episode)
    card = card(html, work.turn)

    location = html |> LazyHTML.from_document() |> LazyHTML.query(".episode-location")
    refute LazyHTML.text(location) =~ "ryker"

    assert fact(html, work.turn, "Repositories") == "ryker · can change it, coop · read only"
    assert fact(html, work.turn, "Environment") == "None · the work ran outside any environment"

    for noise <- [
          "Setup details",
          "Generation",
          "Execution policy",
          "Worker",
          "Ryker tools",
          "Bound to this work turn"
        ] do
      refute card =~ noise
    end

    refute card =~ "Selected from"
    refute card =~ "Preparation checks"
    refute card =~ "Technical details"
    refute card =~ "Policy digest"
    refute card =~ "Authority digest"

    assert labels(html, work.turn) == ["Environment", "Repositories", "Session"]
    # The briefing owns the repo@sha chips and the tool catalog; setup does not repeat them.
    refute card =~ "e36a37be36a"
    refute card =~ "get_work_state"
  end

  test "work setup names the environment the work ran in, why, and what it gave the work" do
    # Andrew, 2026-09-26: the card said "Session: New · the model starts with
    # only this briefing" and "Code: No repository" under a green check. It is
    # about the environment: whether the message started or continued the
    # request, which environment the work ran in and why, and what that
    # environment gave the work.
    payments_environment!()
    entry = slack_message!("channel", "CPAYMENTS")
    work = routed_work!("channel", entry, start_decision(), environment_pin())
    html = rendered(work.episode)

    assert labels(html, work.turn) == [
             "Request",
             "Environment",
             "Repositories",
             "Emisar",
             "Session"
           ]

    assert fact(html, work.turn, "Request") == "New · this message started it"
    assert fact(html, work.turn, "Environment") == "Payments · this channel's environment"

    assert fact(html, work.turn, "Repositories") ==
             "acme/payments · can change it, acme/infra · read only"

    assert fact(html, work.turn, "Emisar") == "Production approvals"
    assert fact(html, work.turn, "Session") == "New · the model starts with only this briefing"
  end

  test "a run started by a message that continued the request says so" do
    # The first message started the request; the second was routed into it.
    # Each run's card says which its message did, read from routing's
    # recorded decision for that message.
    payments_environment!()
    first = slack_message!("first", "CPAYMENTS")
    work = routed_work!("first", first, start_decision(), environment_pin())
    second = slack_message!("second", "CPAYMENTS")

    decide!(second, work.episode, %{
      "action" => "continue_episode",
      "episode_ref" => "candidate:#{String.duplicate("e", 64)}",
      "messages" => nil,
      "reactions" => nil,
      "reason" => "The same payment failure, still being investigated.",
      "relation" => "same_work",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => "standard"
    })

    later =
      Repo.insert!(%Turn{
        id: Ecto.UUID.generate(),
        episode_id: work.episode.id,
        session_id: work.session.id,
        turn_ref: "ingress-turn:#{second.id}",
        status: :pending,
        coop_turn_id: "coop-turn-continued",
        inserted_at: DateTime.add(DateTime.utc_now(), 1)
      })

    html = rendered(work.episode)
    assert fact(html, work.turn, "Request") == "New · this message started it"

    assert fact(html, later, "Request") ==
             "Continued · routing added this message to the work already under way"

    assert fact(html, later, "Session") ==
             "Continued · the model still has what it saw in the previous round"
  end

  test "a message that started a request beside earlier work names that work" do
    # Routing may start new work and link an earlier request to it as
    # background. The card names the request it was linked to.
    payments_environment!()
    earlier = routed_episode!(slack_message!("earlier", "CPAYMENTS"), start_decision())
    entry = slack_message!("linked", "CPAYMENTS")

    decision = %{
      start_decision()
      | "episode_ref" => "candidate:#{String.duplicate("b", 64)}",
        "relation" => "history_only"
    }

    work = routed_work!("linked", entry, decision, environment_pin(), earlier.id)

    assert fact(rendered(work.episode), work.turn, "Request") ==
             ~s(New · this message started it, with "Payouts are failing for earlier" linked as background)
  end

  test "a direct message runs in the default environment and its setup says why" do
    # A direct message has no environment setting of its own, so Slack runs
    # its work in the default environment (Ryker.Slack.Runtime).
    payments_environment!(default: true)
    entry = slack_message!("direct", "D0PAYMENTS")
    work = routed_work!("direct", entry, start_decision(), environment_pin())

    assert fact(rendered(work.episode), work.turn, "Environment") ==
             "Payments · the default environment, since a direct message has none of its own"
  end

  test "a Chat conversation's work names the environment of that conversation" do
    payments_environment!()
    conversation_id = Ecto.UUID.generate()

    {:ok, %{entry: entry}} =
      ConversationLab.send_message(conversation_id, "Why are payouts failing?", chat_profile(),
        now: fn -> @now end
      )

    work = routed_work!("chat", entry, start_decision(), environment_pin())

    assert fact(rendered(work.episode), work.turn, "Environment") ==
             "Payments · this Chat conversation's environment"
  end

  test "an incident room's work names the environment the room was opened with" do
    payments_environment!()
    entry = slack_message!("room", "CROOMPAY")
    work = routed_work!("room", entry, start_decision(), environment_pin())
    incident_room!(work, "CROOMPAY")

    assert fact(rendered(work.episode), work.turn, "Environment") ==
             "Payments · the environment the incident room was opened with"
  end

  test "a local session row alone is setup selected, not a ready worker" do
    # Pinning creates the Session row before any Work claim; the turn does not
    # exist yet. That row proves configuration was selected and nothing more.
    work = pinned!("selected")
    card = card(rendered(work.episode), work.session)

    assert card =~ "Setup selected"
    assert card =~ "Waiting for a worker to pick it up"
    refute ready?(rendered(work.episode), work.session)
    refute card =~ "Worker"
  end

  test "an old turn with no preparation receipts keeps its outcome unrecorded" do
    work = claimed!("unrecorded")

    Repo.update_all(from(turn in Turn, where: turn.id == ^work.turn.id),
      set: [lease_ref: nil, lease_owner: nil, lease_expires_at: nil]
    )

    html = rendered(work.episode)
    card = card(html, work.turn)
    assert card =~ "Setup selected"
    assert card =~ "Preparation outcome not recorded"
    refute ready?(html, work.turn)
    refute card =~ "Preparing"
  end

  test "a claimed turn with no remote session yet is preparing, at its recorded step" do
    work = claimed!("preparing")
    html = rendered(work.episode)
    card = card(html, work.turn)

    assert card =~ "Preparing"
    assert card =~ "Creating worker session"
    refute ready?(html, work.turn)
  end

  test "a replaced session says so and keeps its reason unknown" do
    work = submitted!("replaced")

    Repo.update_all(from(session in Session, where: session.id == ^work.session.id),
      set: [generation: 2, create_generation: 3]
    )

    card = card(rendered(work.episode), work.turn)
    assert card =~ "New, replacing an earlier session · the reason was not recorded"
    refute card =~ "Generation"
    refute card =~ "reached its limit"
  end

  test "a session replaced for an edited message says the edit was why" do
    # QA re-test, 2026-09-26: after an edit the card said "New, replacing an
    # earlier session · the reason was not recorded", though the reason was
    # the edit. Admission names each run after the input that started it, so
    # a run an edit started is known.
    entry = edit_entry!("edited")

    work =
      submitted!("edited", %{
        native_input_id: entry.native_input_id,
        turn_ref: "ingress-turn:#{entry.id}"
      })

    # As admission leaves it: decided into this request.
    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        status: :decided,
        decision_ref: "decision:edited",
        decision_fingerprint: String.duplicate("f", 64),
        decision_action: :continue_episode,
        decision_document: %{"action" => "continue_episode"},
        episode_id: work.episode.id
      ]
    )

    Repo.update_all(from(session in Session, where: session.id == ^work.session.id),
      set: [generation: 2, create_generation: 3]
    )

    card = card(rendered(work.episode), work.turn)
    assert card =~ "New, replacing the earlier session because a message was edited"
    refute card =~ "the reason was not recorded"
  end

  test "a later turn on the same session says the session was reused" do
    work = submitted!("reused")

    later =
      Repo.insert!(%Turn{
        id: Ecto.UUID.generate(),
        episode_id: work.episode.id,
        session_id: work.session.id,
        turn_ref: "reused-follow-up",
        status: :pending,
        coop_turn_id: "coop-turn-2",
        inserted_at: DateTime.add(DateTime.utc_now(), 1)
      })

    html = rendered(work.episode)
    assert card(html, work.turn) =~ "New · the model starts with only this briefing"

    assert card(html, later) =~
             "Continued · the model still has what it saw in the previous round"
  end

  test "a turn blocked before it started shows the recorded cause, not a ready worker" do
    work = claimed!("blocked")

    # The dispatcher records the fleet's reason code and an inspected term; the
    # card says what that code means and never invents a per-worker breakdown.
    Repo.update_all(from(turn in Turn, where: turn.id == ^work.turn.id),
      set: [
        status: :blocked,
        last_error_code: "coop_worker_capacity_unavailable",
        last_error_detail: "{:coop_worker_capacity_unavailable, \"session\"}",
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    html = rendered(work.episode)
    card = card(html, work.turn)
    assert card =~ "Blocked"
    assert card =~ "No eligible worker with available capacity was found."
    assert card =~ "Failure diagnostics"
    refute card =~ "Policy digest"
    refute card =~ "Authority digest"
    refute card =~ "all workers were busy"
    refute ready?(html, work.turn)
  end

  defp ready?(html, %{id: id}) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-setup-#{id} .work-setup[data-state='ready']")
    |> Enum.count() == 1
  end

  defp card(html, %{id: id}) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-setup-#{id}")
    |> LazyHTML.text()
  end

  defp labels(html, %{id: id}) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#event-setup-#{id} .setup-facts dt")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp fact(html, %{id: id}, label) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#event-setup-#{id} .setup-facts > div")
    |> Enum.find_value(fn row ->
      if LazyHTML.query(row, "dt") |> LazyHTML.text() == label,
        do: row |> LazyHTML.query("dd") |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end)
  end

  defp rendered(episode) do
    {:ok, detail} = EpisodeProjection.fetch(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  # The Payments environment as an operator saves it: two repositories, the
  # first the one work changes, and an Emisar account.
  defp payments_environment!(options \\ []) do
    {:ok, snapshot} = Settings.initialize(@actor)

    snapshot =
      Enum.reduce(["payments", "infra"], snapshot, fn ref, snapshot ->
        {:ok, snapshot} =
          Settings.put_repository(
            %{ref: ref, display_name: "acme/" <> ref, github_repository: "acme/" <> ref},
            snapshot.installation.revision,
            @actor
          )

        snapshot
      end)

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/api/mcp/rpc",
          account_ref: "account-production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: @now
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "payments",
          display_name: "Payments",
          repositories: ["payments", "infra"],
          emisar_connection_ref: "production",
          is_default: Keyword.get(options, :default, false)
        },
        snapshot.installation.revision,
        @actor
      )
  end

  # How admission pins a request that starts in the Payments environment: the
  # first repository is the working copy and the other is mounted beside it.
  defp environment_pin do
    [
      repository: "payments",
      context: %{
        "context_ref" => "payments",
        "parallel_goal_limit" => 1,
        "primary_repository" => "payments",
        "read_only_repositories" => ["infra"]
      },
      environment: "payments",
      workspace: @environment_workspace
    ]
  end

  defp chat_profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    profile
  end

  defp start_decision do
    %{
      "action" => "start_episode",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => nil,
      "reason" => "A new payment failure.",
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => "standard"
    }
  end

  defp slack_message!(suffix, channel) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: channel,
        content: %{"text" => "Payouts are failing for #{suffix}"},
        event_kind: :message,
        event_ref: "Ev-setup-#{suffix}-#{Ecto.UUID.generate()}",
        message_ref: "#{1_788_562_304 + System.unique_integer([:positive])}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TSETUPENV"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  # A request routing started from `entry`, and its first run, submitted.
  defp routed_work!(suffix, entry, decision, pin, linked_episode_id \\ nil) do
    episode = routed_episode!(entry, decision, linked_episode_id)
    submitted!(suffix, %{}, Keyword.put(pin, :episode, episode))
  end

  # The request routing started from `entry`, named after the input the way
  # admission names it, with the input decided into it.
  defp routed_episode!(entry, decision, linked_episode_id \\ nil) do
    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: entry.destination_conversation_ref,
            thread_ref: entry.destination_thread_ref || entry.source_item_ref,
            transport: entry.destination_transport
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          linked_episode_id: linked_episode_id,
          native_input_id: entry.native_input_id,
          occurred_at: @now,
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decide!(entry, episode, decision)
    episode
  end

  defp decide!(entry, episode, decision) do
    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: String.to_existing_atom(decision["action"]),
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        status: :decided
      ]
    )
  end

  defp incident_room!(work, channel) do
    {:ok, record} =
      Records.create(Records.token(work.turn), "incident-room-offer", "progress", %{
        "next_due_at" => nil,
        "phase" => "investigating",
        "summary" => "Payouts are failing."
      })

    %{
      attempt_count: 1,
      bot_user_ref: "U-BOT",
      channel_name: "inc-payouts",
      channel_ref: channel,
      channel_state: :active,
      confirmation_ref: "incident-confirmation:payouts",
      environment_ref: "payments",
      episode_id: work.episode.id,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: ["U123"],
      policy: "incident-investigate",
      policy_digest: String.duplicate("c", 64),
      private: true,
      prompt: "Investigate the failing payouts.",
      record_id: record.id,
      ref: "incident-room:payouts",
      repository_ref: "payments",
      requested_at: @now,
      requested_by_actor_ref: "U123",
      source_channel_ref: "CPAYMENTS",
      source_episode_id: work.episode.id,
      source_message_ref: "1787832000.000100",
      status: :blocked,
      title: "Payouts are failing",
      topic: "Payouts incident room",
      workspace_ref: "TSETUPENV"
    }
    |> IncidentRoomChangeset.insert()
    |> Repo.insert!()
  end

  # An edit as Slack delivers it: the original message's ref, an edit event
  # numbered by its own timestamp.
  defp edit_entry!(suffix) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "What is 5+5? Just the number."},
        event_kind: :edit,
        event_ref: "Ev-edit-#{suffix}",
        message_ref: "1788562304.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1_788_562_310_000_100 * 4 + 1,
        thread_ref: nil,
        workspace_ref: "TSETUPCARD"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp pinned!(suffix, overrides \\ %{}, pin \\ []) do
    episode =
      Keyword.get_lazy(pin, :episode, fn ->
        episode_id = Ecto.UUID.generate()

        {:ok, %{episode: episode}} =
          Episodes.apply(
            EpisodeFixtures.admit_input(
              Map.merge(
                %{
                  episode_id: episode_id,
                  episode_key: "work-setup:#{suffix}:#{episode_id}",
                  native_input_id: "source:#{suffix}:#{episode_id}",
                  turn_ref: "turn:#{suffix}:#{episode_id}"
                },
                overrides
              )
            )
          )

        episode
      end)

    {:ok, session} =
      Custody.pin_episode(
        episode.id,
        "setup-policy",
        String.duplicate("a", 64),
        String.duplicate("c", 64),
        Keyword.get(pin, :repository, "ryker"),
        Keyword.get(pin, :context),
        nil,
        Keyword.get(pin, :environment)
      )

    %{episode: episode, session: session, turn: nil}
  end

  defp claimed!(suffix, overrides \\ %{}, pin \\ []) do
    work = pinned!(suffix, overrides, pin)
    {:ok, claim} = Custody.claim_next("setup:#{suffix}", 120, :work)
    %{work | turn: claim.turn} |> Map.put(:claim, claim)
  end

  defp submitted!(suffix, overrides \\ %{}, pin \\ []) do
    work = claimed!(suffix, overrides, pin)
    claim = work.claim

    {:ok, submission} =
      Submission.new(
        %{"mode" => "full", "workspace" => Keyword.get(pin, :workspace, @workspace)},
        "Investigate",
        %{"type" => "object"},
        "work-final-live-v3"
      )

    {:ok, _frozen} =
      Custody.freeze_submission(work.episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        1,
        1,
        "coop-session-#{suffix}"
      )

    {:ok, turn} =
      Custody.bind_state_tools(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        "http://127.0.0.1:1/state",
        String.duplicate("d", 64)
      )

    {:ok, turn} =
      Custody.bind_turn(
        work.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        session.generation,
        1,
        "coop-turn-#{suffix}"
      )

    %{work | session: session, turn: turn}
  end
end
