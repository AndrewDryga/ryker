defmodule Ryker.ControlPlane.BackgroundSectionsTest do
  @moduledoc """
  Background work that belongs to a request: learning, and cleanup.

  Learning reads decided inputs whether or not the request ever replied, so it
  is a peer of the work rather than a step inside it. It appears here only when
  one of this request's own inputs is a recorded member of the batch — sharing
  a channel is not membership — and a batch that read other requests too says
  how much of it came from this one instead of claiming the rest.

  Cleanup says what actually happened to the temporary session and workspace.
  Closing is not removing, a kept workspace is not a failure, a session that
  never bound a remote one had nothing to delete, and blocked cleanup does not
  invalidate an answer that was already delivered.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.Projection
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, InputMembership}
  alias Ryker.Slack.Input
  alias Ryker.State.LearningRun
  alias Ryker.Work.{Custody, Session}

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "a batch that read this request's input appears as background learning" do
    %{episode: episode, entry: entry} = admitted!("saved")
    learning!(entry, updates: [%{"action" => "create", "subject" => "Deployment target"}])

    step = learning_step(episode)
    assert step.state == "knowledge saved"
    assert step.summary =~ "Saved 1 topic update"
    assert step.tone == :good
    assert step.href =~ "/memory/learning?"
    assert Enum.find(step.details, &(&1.label == "Model")).presentation == :execution_target
    refute Enum.any?(step.details, &(&1.label in ["Prompt", "Result"]))
  end

  test "a batch that only shares a channel is not this request's learning" do
    %{episode: episode} = admitted!("unrelated")
    %{entry: elsewhere} = admitted!("elsewhere")
    learning!(elsewhere, updates: [%{"action" => "create", "subject" => "Other work"}])

    assert learning_step(episode) == nil
  end

  test "a cross-request batch says how much of it came from this request" do
    %{episode: episode, entry: entry} = admitted!("shared")

    learning!(entry,
      updates: [%{"action" => "update", "subject" => "Retry behavior"}],
      manifest: ["one", "two", "three"]
    )

    details = learning_step(episode).details |> Map.new(&{&1.label, &1.value})
    assert details["Messages read"] == "1 of 3 from this request"
  end

  test "an all-defer judgment saved nothing and is not a failed batch" do
    %{episode: episode, entry: entry} = admitted!("deferred")

    learning!(entry,
      updates: [
        %{"action" => "defer", "reason" => "Conflicting reports"},
        %{"action" => "defer", "reason" => "Conflicting reports"}
      ]
    )

    step = learning_step(episode)
    assert step.state == "deferred"
    assert step.summary =~ "deferred every judgment"
    refute step.summary =~ "Saved"
    assert step.tone == nil
  end

  test "a rejected learning result saved nothing and says so" do
    %{episode: episode, entry: entry} = admitted!("rejected")
    learning!(entry, status: :rejected, error_code: "learning_match_required")

    step = learning_step(episode)
    assert step.state == "rejected"
    assert step.summary =~ "Nothing was saved"
    assert step.tone == :warn
  end

  test "closing a session is not removing its workspace" do
    %{episode: episode} = admitted!("closed")
    cleanup!(episode, cleanup_status: :grace, closed_at: @now)

    step = maintenance_step(episode, "Session closed")
    assert step.summary =~ "Closing is not removing"
    assert maintenance_step(episode, "Workspace removed") == nil
  end

  test "a kept workspace names why it was kept and is not a failure" do
    %{episode: episode} = admitted!("kept")

    cleanup!(episode,
      cleanup_status: :retained,
      closed_at: @now,
      retained_reason: "dirty_worktree"
    )

    step = maintenance_step(episode, "Workspace kept")
    assert step.summary =~ "uncommitted changes"
    assert step.tone == nil
  end

  test "a session that never bound a remote one is not a deleted workspace" do
    # The step read the receipt under "outcome", a key cleanup never writes: it
    # writes "kind". Every settled cleanup therefore said "The temporary
    # workspace was discarded", including a session Ryker never bound, one its
    # worker had already lost, and one left on a worker removed from Ryker.
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
      }
    )

    assert maintenance_step(episode, "Workspace removed") == nil
    step = maintenance_step(episode, "Nothing to remove")
    assert step.summary =~ "never learned a worker session"
    refute step.summary =~ "discarded"
  end

  test "a session left on a removed worker says it could not be removed" do
    %{episode: episode} = admitted!("worker-removed")

    cleanup!(episode,
      cleanup_status: :discarded,
      closed_at: @now,
      discarded_at: @now,
      cleanup_receipt: %{
        "kind" => "worker_removed",
        "local_session_id" => Ecto.UUID.generate(),
        "remote_session_id" => "coop-session-removed",
        "remote_state" => "unreachable",
        "worker_id" => "worker-gone"
      }
    )

    step = maintenance_step(episode, "Workspace left on a removed worker")
    assert step.summary =~ "removed from Ryker"
  end

  test "blocked cleanup does not invalidate the delivered answer" do
    %{episode: episode} = admitted!("blocked")

    cleanup!(episode,
      cleanup_status: :blocked,
      closed_at: @now,
      cleanup_blocked_from: :discard_pending,
      cleanup_last_error_code: "coop_unavailable"
    )

    step = maintenance_step(episode, "Cleanup blocked")
    assert step.summary =~ "delivered answer is unaffected"
    assert step.summary =~ "Coop unavailable"
    assert step.tone == :warn
  end

  defp learning_step(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    Enum.find(detail.trace.steps, &(&1.stage == "Learning"))
  end

  defp maintenance_step(episode, title) do
    {:ok, detail} = Projection.episode(episode.key)
    Enum.find(detail.trace.steps, &(&1.stage == "Maintenance" and &1.title == title))
  end

  defp cleanup!(episode, fields) do
    session = Repo.one!(from(s in Session, where: s.episode_id == ^episode.id))
    Repo.update_all(from(s in Session, where: s.id == ^session.id), set: fields)
  end

  defp learning!(entry, options) do
    batch_id = Ecto.UUID.generate()
    updates = Keyword.get(options, :updates, [])
    manifest = Keyword.get(options, :manifest, ["one"])
    result = if updates == [], do: nil, else: Jason.encode!(%{"updates" => updates})

    Repo.insert!(%Batch{
      id: batch_id,
      scope_key: "slack:TC9F5B40D364C:C456:live",
      transport: "slack",
      conversation_ref: "slack:TC9F5B40D364C:C456",
      execution_mode: :live,
      policy: "learning",
      policy_digest: String.duplicate("a", 64),
      status: :applied,
      input_count: length(manifest)
    })

    Repo.insert!(%InputMembership{input_id: entry.id, batch_id: batch_id})

    Repo.insert!(%LearningRun{
      id: Ecto.UUID.generate(),
      batch_key: "batch:#{batch_id}",
      batch_id: batch_id,
      generation: 1,
      status: Keyword.get(options, :status, :applied),
      inputs: Enum.map(manifest, &%{"input_ref" => &1}),
      source_dependencies: [],
      knowledge: [],
      omissions: [],
      policy: "learning",
      policy_digest: String.duplicate("a", 64),
      prompt: "Read these messages.",
      prompt_sha256: String.duplicate("b", 64),
      output_schema: %{"type" => "object"},
      result: result,
      result_sha256: if(result, do: CanonicalJSON.digest(result)),
      producer: %{"target" => "codex:gpt-5.6-sol/medium@default"},
      error_code: Keyword.get(options, :error_code),
      applied_at: DateTime.add(@now, 120, :second)
    })
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
