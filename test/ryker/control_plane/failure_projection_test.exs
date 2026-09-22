defmodule Ryker.ControlPlane.FailureProjectionTest do
  use Ryker.DataCase, async: true

  # Admission context reads under REPEATABLE READ; the fixture keeps its own
  # workspace so the conversation lock never waits on another suite.
  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.ControlPlane.{FailureProjection, HTML, Projection, WorkspaceProjection}
  alias Ryker.Delivery.ReactionCustody
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Batch, as: LearningBatch
  alias Ryker.Learning.FleetSession, as: LearningFleetSession
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.State.Learning

  @now ~U[2026-08-28 12:00:00.000000Z]

  # A reaction is the one delivery that belongs to an input rather than an
  # episode. The failures page looked its conversation up through that input,
  # but the delivery row dropped the input id on the way in, so a blocked
  # reaction said "reaction delivery" with no destination to open.
  test "a blocked reaction delivery names the conversation it was reacting in" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please acknowledge this."},
               event_kind: :message,
               event_ref: "Ev-blocked-reaction",
               message_ref: "1787832001.000200",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "TBLOCKEDREACTION"
             })

    assert {:ok, %{entry: entry, status: :recorded}} = Inbox.record(input, execution_mode: :live)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "Acknowledge the source item without starting work.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:blocked-reaction")
    assert {:ok, claim} = ReactionCustody.claim_next("delivery:reaction:blocked", 60)

    assert {:ok, _blocked} =
             ReactionCustody.block(
               claim.reaction.delivery_ref,
               claim.lease_ref,
               "slack_reaction_rejected",
               "private reaction diagnostic"
             )

    assert {:ok, failures} = Projection.failures(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == claim.reaction.delivery_ref))
    assert row.kind == "delivery"
    assert row.destination == "slack:TBLOCKEDREACTION:C456 / 1787832000.000100"
    assert row.source == "slack:TBLOCKEDREACTION · Ev-blocked-reaction"
    refute inspect(row) =~ "private reaction diagnostic"
  end

  # A learning session has no episode, and every retention row here was read
  # through an inner join on one. On 2026-09-18 three learning cleanups sat
  # blocked in the metrics while this page said nothing needed attention, and
  # no operator could open one to retry it.
  test "a blocked learning cleanup is listed and can be opened for retry" do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = LearningFleetSession.ensure(run)
    remote_id = "coop-learning-blocked-#{System.unique_integer([:positive])}"
    assert {:ok, session} = LearningFleetSession.bind(run, remote_id)

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup:learning-blocked", 60)
    assert claim.session.id == session.id

    assert {:ok, _blocked} =
             RetentionCustody.block(
               session.id,
               claim.lease_ref,
               "coop_protocol_error",
               "close refused"
             )

    assert {:ok, failures} = Projection.failures(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == session.external_ref))
    assert row.kind == "retention"
    assert row.action == :rearm

    html = [row] |> HTML.failures() |> IO.iodata_to_binary()
    assert html =~ "Background learning"
    refute html =~ "Before admission"

    assert {:ok, %{kind: "retention", action: :rearm} = exact} =
             FailureProjection.fetch("retention", session.external_ref)

    detail = exact |> HTML.failure() |> IO.iodata_to_binary()
    assert detail =~ "/actions/retention/"
    refute detail =~ "Related request"

    # The Workspaces page promises every retained worker session, and read
    # them through the same inner join.
    assert %{action: :rearm} =
             workspace =
             Enum.find(WorkspaceProjection.list(%{}), &(&1.ref == session.external_ref))

    storage = %{budget: %{}, preview: [], workers: []}
    page = [workspace] |> HTML.workspaces(storage) |> IO.iodata_to_binary()
    assert page =~ "Background learning"
    assert page =~ "/actions/retention/"
  end

  test "an unresolved learning worker reports the scheduled retry instead of being in use" do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("b", 64)
             })

    assert {:ok, session} = LearningFleetSession.ensure(run)
    retry_at = ~U[2026-08-28 13:00:00.000000Z]

    batch =
      Repo.insert!(%LearningBatch{
        id: Ecto.UUID.generate(),
        scope_key: "workspace-learning-retry-#{System.unique_integer([:positive])}",
        transport: "lab",
        conversation_ref: "conversation:workspace-learning-retry",
        execution_mode: :live,
        policy: "recorded-read-only-policy",
        policy_digest: String.duplicate("b", 64),
        status: :deferred,
        input_count: 1,
        next_attempt_at: retry_at,
        error_code: "learning_remote_unresolved"
      })

    run
    |> Ecto.Changeset.change(
      batch_id: batch.id,
      status: :rejected,
      reconcile_attempt_count: 4,
      error_code: "learning_remote_unresolved"
    )
    |> Repo.update!()

    workspace =
      WorkspaceProjection.list(%{})
      |> Enum.find(&(&1.ref == session.external_ref))

    assert workspace.learning_state == :retry_scheduled
    assert workspace.learning_retry_at == retry_at

    page = HTML.workspaces([workspace], %{budget: %{}, preview: [], workers: []})
    html = IO.iodata_to_binary(page)
    document = LazyHTML.from_fragment(html)
    lifecycle = LazyHTML.query(document, "section.workspace-learning td[data-label='Lifecycle']")
    assert LazyHTML.text(lifecycle) =~ "Retry scheduled"
    assert LazyHTML.text(lifecycle) =~ "Retry after 28 Aug, 13:00 UTC"
    refute LazyHTML.text(lifecycle) =~ "In use"
  end
end
