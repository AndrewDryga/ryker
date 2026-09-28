defmodule Ryker.ControlPlane.BackgroundSectionsTest do
  @moduledoc """
  Background work that belongs to a request: learning, and cleanup.

  Learning reads decided inputs whether or not the request ever replied, so it
  is a peer of the work rather than a step inside it. It appears here only when
  one of this request's own inputs is a recorded member of the batch — sharing
  a channel is not membership — and an attempt that read other requests too
  says how much of it came from this one instead of claiming the rest. Each
  attempt is a model call with its briefing and result, like routing and work.

  Cleanup says what actually happened to the temporary session and workspace.
  Closing is not removing, a kept workspace is not a failure, a session that
  never bound a remote one had nothing to delete, and blocked cleanup does not
  invalidate an answer that was already delivered. Which worker held it, the
  close request, the removal plan and the receipt sit behind Details.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.CoopFleet.{ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.FakeRetentionCoopAPI
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning.{Batch, InputMembership}
  alias Ryker.Learning.LearningRun
  alias Ryker.Retention.Dispatcher, as: Cleanup
  alias Ryker.Slack.Input
  alias Ryker.Work.{Custody, Session}

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "a batch that read this request's input appears as background learning" do
    %{episode: episode, entry: entry} = admitted!("saved")
    run = learning!(entry, updates: [created(entry, "Deployment target")])

    result = learning_card(episode, run, "-result")
    assert text(result, "h3") == "Knowledge updated"
    assert text(result, ".request-decision") =~ "Deployment target"
    assert text(result, ".call-run") =~ "gpt-5.6-sol"

    assert result |> LazyHTML.query(".request-identity a") |> LazyHTML.attribute("href") == [
             "/memory/learning?batch=#{run.batch_id}"
           ]
  end

  test "a batch that only shares a channel is not this request's learning" do
    %{episode: episode} = admitted!("unrelated")
    %{entry: elsewhere} = admitted!("elsewhere")
    learning!(elsewhere, updates: [created(elsewhere, "Other work")])

    assert episode |> timeline() |> LazyHTML.query("section.phase-learning") |> Enum.empty?()
  end

  test "a cross-request batch says how much of it came from this request" do
    %{episode: episode, entry: entry} = admitted!("shared")

    run =
      learning!(entry,
        updates: [created(entry, "Retry behavior")],
        others: [Ecto.UUID.generate(), Ecto.UUID.generate()]
      )

    assert text(learning_card(episode, run, "-result"), ".request-decision") =~
             "1 of 3 from this request"
  end

  test "an all-defer judgment saved nothing and is not a failed batch" do
    %{episode: episode, entry: entry} = admitted!("deferred")

    run =
      learning!(entry,
        updates: [
          %{
            "action" => "defer",
            "reason" => "Conflicting reports",
            "source_input_ids" => [entry.id]
          },
          %{
            "action" => "defer",
            "reason" => "Conflicting reports",
            "source_input_ids" => [entry.id]
          }
        ]
      )

    result = learning_card(episode, run, "-result")
    assert text(result, "h3") == "No change needed"
    decision = text(result, ".request-decision")
    assert decision =~ "Nothing saved"
    assert decision =~ "the model deferred every judgment"
    assert decision =~ "Conflicting reports"
    refute decision =~ "Saved"
  end

  test "a rejected learning result saved nothing and says so" do
    %{episode: episode, entry: entry} = admitted!("rejected")

    run =
      learning!(entry,
        status: :rejected,
        error_code: "learning_match_required",
        updates: [created(entry, "Checkout outage")]
      )

    result = learning_card(episode, run, "-result")
    assert text(result, "h3") == "Response rejected"
    decision = text(result, ".request-decision")
    assert decision =~ "Nothing saved"
    assert decision =~ "A possible existing topic was found"
    assert decision =~ "Proposed, not saved"
    assert decision =~ "Checkout outage"
    refute text(result, ".request-decision dt") =~ "learning_match_required"
    assert text(result, ".request-identity") =~ "learning_match_required"
  end

  # The Learned page now opens how a topic was learned on the Timeline. A
  # relearning pass reads messages a person chose, outside the batch that
  # first read them, and an attempt prepared before batches has none: finding
  # learning only through batch membership left both links with no card.
  test "a relearning attempt and one from before batches show beside the messages they read" do
    %{episode: episode, entry: entry} = admitted!("relearned")
    relearned = learning!(entry, batch: :rebuild, updates: [created(entry, "Relearned topic")])
    older = learning!(entry, batch: :none, updates: [created(entry, "Older topic")])

    page = timeline(episode)

    for run <- [relearned, older],
        do: assert(page |> LazyHTML.query("#learning-#{run.id}-result") |> Enum.count() == 1)

    assert text(page, "#learning-#{relearned.id}-result .request-decision") =~ "Relearned topic"
    assert text(page, "#learning-#{older.id}-result .request-decision") =~ "Older topic"
  end

  test "closing a session is not removing its working copy" do
    %{episode: episode} = admitted!("closed")
    cleanup!(episode, coop_session_id: "remote-closed", cleanup_status: :grace, closed_at: @now)

    step = maintenance_step(episode, "Worker session closed")
    assert step.summary =~ "Closing it does not remove its working copy"
    assert maintenance_step(episode, "Working copy removed") == nil
  end

  test "a kept working copy names why it was kept and is not a failure" do
    %{episode: episode} = admitted!("kept")

    cleanup!(episode,
      coop_session_id: "remote-kept",
      cleanup_status: :retained,
      closed_at: @now,
      retained_reason: "dirty_worktree"
    )

    step = maintenance_step(episode, "Working copy kept")
    # One story: the close, then why the copy stayed.
    assert step.summary =~ "closed"
    assert step.summary =~ "uncommitted changes"
    assert step.tone == nil
  end

  test "a session that never started on a worker has no cleanup card" do
    # The step read the receipt under "outcome", a key cleanup never writes: it
    # writes "kind". Every settled cleanup therefore said "The temporary
    # workspace was discarded", including a session Ryker never bound. Then it
    # said "Nothing to remove" (2026-09-28: one of four contradicting cards);
    # a session no worker knew has nothing to tell.
    %{episode: episode} = admitted!("never-bound")

    cleanup!(episode,
      cleanup_status: :discarded,
      closed_at: @now,
      discarded_at: @now,
      cleanup_receipt: %{
        "kind" => "never_bound",
        "local_session_id" => Ecto.UUID.generate(),
        "remote_session_id" => nil,
        "remote_state" => "unknown"
      },
      cleanup_receipt_fingerprint: String.duplicate("c", 64)
    )

    assert maintenance_steps(episode) == []
  end

  test "a session left on a removed worker says it could not be removed" do
    %{episode: episode} = admitted!("worker-removed")

    cleanup!(episode,
      coop_session_id: "coop-session-removed",
      cleanup_status: :discarded,
      closed_at: @now,
      discarded_at: @now,
      cleanup_receipt: %{
        "kind" => "worker_removed",
        "local_session_id" => Ecto.UUID.generate(),
        "remote_session_id" => "coop-session-removed",
        "remote_state" => "unreachable",
        "worker_id" => "worker-gone"
      },
      cleanup_receipt_fingerprint: String.duplicate("c", 64)
    )

    step = maintenance_step(episode, "Working copy left on a removed worker")
    assert step.summary =~ "removed from Ryker"
    assert Enum.find(step.details, &(&1.label == "Worker")).value == "worker-gone"
  end

  test "blocked cleanup does not invalidate the delivered answer" do
    %{episode: episode} = admitted!("blocked")

    cleanup!(episode,
      coop_session_id: "remote-blocked",
      cleanup_status: :blocked,
      closed_at: @now,
      cleanup_attempt_count: 3,
      cleanup_blocked_from: :discard_pending,
      cleanup_last_error_code: "coop_unavailable",
      cleanup_last_error_detail: "{:coop_unavailable, :econnrefused}"
    )

    step = maintenance_step(episode, "Cleanup blocked")
    assert step.summary =~ "delivered answer is unaffected"
    # The error in words on the card; its code and the saved detail in Details.
    assert step.summary =~ "The worker could not be reached"
    refute step.summary =~ ~r/coop/i
    details = Map.new(step.details, &{&1.label, &1.value})
    assert details["Stopped while"] == "Removing the working copy"
    assert details["Tries"] == "3"
    assert details["Error code"] == "coop_unavailable"
    assert details["Error detail"] =~ "econnrefused"
    assert step.tone == :warn
  end

  # Andrew, 2026-09-28, of one request's Cleanup: "Nothing to remove",
  # "Worker session closed", "Working copy already gone" and "Working copy
  # removed" read as four contradicting answers. They were three sessions, one
  # of which never started on a worker, and no card said which it was about.
  test "a request's cleanup is one card per session that ran, each naming its session" do
    %{episode: episode} = admitted!("sessions")
    first = Repo.one!(from(s in Session, where: s.episode_id == ^episode.id))
    receipt = &%{"kind" => &1, "remote_state" => &2}
    fingerprint = String.duplicate("c", 64)

    cleanup!(episode,
      coop_session_id: "remote-first",
      cleanup_status: :discarded,
      discarded_at: @now,
      cleanup_receipt: receipt.("remote_absent", "absent"),
      cleanup_receipt_fingerprint: fingerprint
    )

    first = Repo.get!(Session, first.id)

    copy_session!(first, 2,
      coop_session_id: nil,
      cleanup_receipt: receipt.("never_bound", "unknown")
    )

    last =
      copy_session!(first, 3,
        coop_session_id: "remote-last",
        closed_at: DateTime.add(@now, 60, :second),
        discarded_at: DateTime.add(@now, 120, :second),
        cleanup_receipt: receipt.("discarded", "discarded"),
        discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => false}},
        discard_plan_fingerprint: fingerprint,
        discard_plan_operation_id: "plan:last"
      )

    steps = maintenance_steps(episode)

    assert Enum.map(steps, & &1.title) == [
             "Working copy already gone · first session",
             "Working copy removed · second session"
           ]

    assert Enum.map(steps, & &1.id) == ["maintenance-#{first.id}", "maintenance-#{last.id}"]
    [gone, removed] = Enum.map(steps, & &1.summary)
    assert gone =~ "the worker no longer knew this session"
    assert removed =~ "closed"
    assert removed =~ "removed the temporary working copy"
    refute Enum.any?(steps, &(&1.title =~ "Nothing to remove"))
  end

  # Andrew, 2026-09-26, of "B2 Cleanup — Worker session closed · Working copy
  # removed": it should be forensic and detailed like everything else. The two
  # cards said a session closed and a copy was removed, and nothing about which
  # worker held it, the close request, what the removal plan found, or the
  # receipt that proved the removal, though cleanup records each of them.
  test "a request's cleanup cards show the session and working copy details behind Details" do
    %{episode: episode} = admitted!("forensic")
    session = finished_session!(episode, "remote-forensic")
    place!(session, "worker-forensic")

    {:ok, api} =
      FakeRetentionCoopAPI.start_link(
        sessions: [
          %{
            "external_ref" => session.external_ref,
            "id" => session.coop_session_id,
            "policy" => session.policy,
            "policy_digest" => session.policy_digest,
            "revision" => 7,
            "state" => "open"
          }
        ]
      )

    for phase <- [:closed, :planned, :discarded],
        do: assert({:ok, {:executed, %{phase: ^phase}}} = clean!(api))

    stored = Repo.get!(Session, session.id)
    chapter = episode |> timeline() |> LazyHTML.query("section.phase-maintenance")

    # One card tells the session's cleanup: the close, then the removal.
    assert [_card] = chapter |> LazyHTML.query("article") |> Enum.to_list()
    card = LazyHTML.query(chapter, "#event-maintenance-#{session.id}")
    summary = text(card, ".case-event-summary")
    assert summary =~ "closed"
    assert summary =~ "no uncommitted changes"
    assert summary =~ "no unpublished commits"
    assert text(card, ".case-event-details") =~ "Closed at revision 7"
    assert text(card, ".case-event-details") =~ "Branch coop/session"
    # An identifier shows shortened and carries its exact value to hover and copy.
    details = html(card, ".case-event-details")

    for exact <- ["worker-forensic", "remote-forensic", "ryker:retention:close:#{session.id}:g1"],
        do: assert(details =~ exact)

    for exact <- [
          String.duplicate("a", 40),
          stored.discard_plan_fingerprint,
          stored.discard_plan_operation_id,
          stored.cleanup_receipt_fingerprint,
          "ryker:retention:discard:#{session.id}:g1"
        ],
        do: assert(details =~ exact)

    # Exact identifiers only inside Details; the lines on the face are words.
    face = text(chapter, ".case-card-heading, .case-event-summary")

    for exact <- [session.coop_session_id, "worker-forensic", stored.cleanup_receipt_fingerprint],
        do: refute(face =~ exact)

    refute face =~ ~r/\b(coop|episode|lease|receipt|fingerprint|digest)\b/i
  end

  defp learning_card(episode, run, suffix) do
    card = episode |> timeline() |> LazyHTML.query("#learning-#{run.id}#{suffix}")
    assert Enum.count(card) == 1, "no learning card for attempt #{run.id}"
    card
  end

  defp maintenance_step(episode, title),
    do: Enum.find(maintenance_steps(episode), &(&1.title == title))

  defp maintenance_steps(episode) do
    {:ok, detail} = EpisodeProjection.fetch(episode.key)
    Enum.filter(detail.trace.steps, &(&1.stage == "Maintenance"))
  end

  defp timeline(episode) do
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})
    |> LazyHTML.from_fragment()
  end

  defp text(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  defp html(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.to_html()
  defp squish(value), do: value |> String.split() |> Enum.join(" ")

  defp cleanup!(episode, fields) do
    session = Repo.one!(from(s in Session, where: s.episode_id == ^episode.id))
    Repo.update_all(from(s in Session, where: s.id == ^session.id), set: fields)
  end

  # The request ends, so its pinned worker session becomes cleanup's to close.
  defp finished_session!(episode, remote) do
    session = Repo.one!(from(s in Session, where: s.episode_id == ^episode.id))
    session = session |> Ecto.Changeset.change(coop_session_id: remote) |> Repo.update!()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{episode.id}",
                 episode_key: episode.key,
                 expected_owner: %{kind: :turn, ref: episode.owner_ref},
                 occurred_at: DateTime.add(@now, 1, :second)
               })
             )

    session
  end

  # Another session of the same request, as a continuation or a replacement
  # leaves one: the first's row under a new generation.
  defp copy_session!(session, generation, fields) do
    %Session{session | id: Ecto.UUID.generate(), generation: generation}
    |> Ecto.put_meta(state: :built)
    |> Ecto.Changeset.change(Map.new(fields))
    |> Repo.insert!()
  end

  defp place!(session, worker_id) do
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               worker_id,
               "workspace-background",
               :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)
             )

    now = DateTime.utc_now()
    requirements = %{"workspace_ref" => "workspace-background"}

    # Structural fixture: the durable record of which worker held the session.
    Repo.insert!(%Placement{
      episode_id: session.episode_id,
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: now,
      lease_expires_at: DateTime.add(now, 3_600, :second),
      lease_ref: "placement-lease:#{session.id}",
      requirements: requirements,
      requirements_fingerprint: CanonicalJSON.digest(requirements),
      session_id: session.id,
      state: :retired,
      updated_at: now,
      worker_id: worker_id
    })
  end

  # One cleanup pass with no grace period, as the retention dispatcher tests run it.
  defp clean!(api) do
    options = [
      api: FakeRetentionCoopAPI,
      client: api,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "background-cleanup:#{System.unique_integer([:positive])}"
    ]

    case Cleanup.run_once(options) do
      {:ok, {:executed, %{phase: :grace}}} -> Cleanup.run_once(options)
      outcome -> outcome
    end
  end

  defp created(entry, title) do
    %{
      "action" => "create",
      "source_input_ids" => [entry.id],
      "topic_key" => title |> String.downcase() |> String.replace(" ", "-"),
      "title" => title,
      "summary" => "#{title} is recorded from this request.",
      "topics" => [],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }
  end

  # A structural learning attempt over the request's message: the frozen
  # manifest names it, and the response is the host-contract shape.
  defp learning!(entry, options) do
    updates = Keyword.get(options, :updates, [])
    others = Keyword.get(options, :others, [])
    batch_id = batch!(entry, Keyword.get(options, :batch, :member), 1 + length(others))

    result =
      Jason.encode!(%{"reason" => "Keep what the request settled.", "updates" => updates})

    prompt =
      CanonicalJSON.encode!(%{
        "instructions" => "Learn from these messages without replying.",
        "custom_instructions" => %{"global" => nil, "channel" => nil},
        "inputs" => [%{"source_input_id" => entry.id, "content" => entry.content}],
        "knowledge" => [],
        "previous_attempt_error" => nil
      })

    Repo.insert!(%LearningRun{
      id: Ecto.UUID.generate(),
      batch_key: "batch:#{batch_id || Ecto.UUID.generate()}",
      batch_id: batch_id,
      generation: 1,
      status: Keyword.get(options, :status, :applied),
      inputs: Enum.map([entry.id | others], &%{"source_input_id" => &1}),
      source_dependencies: [],
      knowledge: [],
      omissions: [],
      policy: "learning",
      policy_digest: String.duplicate("a", 64),
      prompt: prompt,
      prompt_sha256: CanonicalJSON.digest(prompt),
      output_schema: %{"type" => "object"},
      result: result,
      result_sha256: CanonicalJSON.digest(result),
      producer: %{"target" => "codex:gpt-5.6-sol/medium@default"},
      error_code: Keyword.get(options, :error_code),
      applied_at: DateTime.add(@now, 120, :second)
    })
  end

  # The batch an attempt ran in: the one holding the message, a relearning
  # batch whose chosen messages name it, or none for an attempt from before
  # learning batches.
  defp batch!(_entry, :none, _count), do: nil

  defp batch!(entry, kind, count) do
    id = Ecto.UUID.generate()

    rebuild =
      if kind == :rebuild,
        do: %{
          rebuild_target_id: topic!(entry),
          rebuild_target_version: 1,
          rebuild_target_generation: 1,
          rebuild_selection: [
            %{"source_input_id" => entry.id, "revision" => 1, "fingerprint" => "relearn"}
          ]
        },
        else: %{}

    Repo.insert!(
      struct!(
        Batch,
        Map.merge(
          %{
            id: id,
            scope_key: "slack:TC9F5B40D364C:C456:live:#{kind}:#{id}",
            transport: "slack",
            conversation_ref: "slack:TC9F5B40D364C:C456",
            execution_mode: :live,
            policy: "learning",
            policy_digest: String.duplicate("a", 64),
            status: :applied,
            input_count: count
          },
          rebuild
        )
      )
    )

    if kind == :member, do: Repo.insert!(%InputMembership{input_id: entry.id, batch_id: id})
    id
  end

  # Structural fixture: the learned topic a person asked Ryker to relearn.
  defp topic!(entry) do
    Repo.insert!(%ConversationKnowledge{
      id: Ecto.UUID.generate(),
      scope_key: "relearn:#{entry.id}",
      topic_key: "relearned-topic",
      transport: "slack",
      workspace_ref: "TC9F5B40D364C",
      conversation_ref: "slack:TC9F5B40D364C:C456",
      visibility: :public,
      state: %{"title" => "Relearned topic", "summary" => "Kept from the request."},
      version: 1,
      source_generation: 1,
      source_dependencies: [],
      source_input_id: entry.id,
      latest_source_at: @now
    }).id
  end

  defp admitted!(suffix) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Investigate #{suffix}"},
        event_kind: :message,
        event_ref: "Ev-background-#{Ecto.UUID.generate()}",
        message_ref: "#{1_788_562_304 + System.unique_integer([:positive])}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: entry.id,
          episode_key: "background:#{suffix}:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @now,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    {:ok, _session} =
      Custody.pin_episode(episode.id, "background", String.duplicate("a", 64), "ryker")

    decision = %{"action" => "reply", "reason" => "A direct reply."}

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        status: :decided
      ]
    )

    %{episode: episode, entry: Repo.get!(Entry, entry.id)}
  end
end
