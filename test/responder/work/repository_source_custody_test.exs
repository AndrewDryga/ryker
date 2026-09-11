defmodule Responder.Work.RepositorySourceCustodyTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Custody, Session}

  @policy_digest String.duplicate("a", 64)
  @branch %{"kind" => "branch", "name" => "feature/payments"}
  @commit %{"kind" => "commit", "sha" => String.duplicate("b", 40)}

  test "a new repository-backed session carries the default source when nobody chose one" do
    command = create_kernel_episode!("source-default")

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder"
             )

    assert session.repository_source == %{"kind" => "default"}
  end

  test "workspace-free work carries no source at all" do
    command = create_kernel_episode!("source-workspace-free")

    assert {:ok, session} =
             Custody.pin_episode(command.episode_id, "work-read-only", @policy_digest)

    assert session.repository_source == nil
  end

  test "a selected source is frozen in the same transaction that pins policy and repository" do
    command = create_kernel_episode!("source-frozen")

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder",
               nil,
               @branch
             )

    assert session.repository_source == @branch
    assert session.repository_ref == "responder"
    assert session.policy_digest == @policy_digest
  end

  test "an already pinned episode cannot be rebound to another source" do
    command = create_kernel_episode!("source-no-rebind")

    assert {:ok, original} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder",
               nil,
               @branch
             )

    assert {:ok, unchanged} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder",
               nil,
               @commit
             )

    assert unchanged.id == original.id
    assert unchanged.repository_source == @branch
  end

  test "a rotated session keeps the exact source its predecessor pinned" do
    command = create_kernel_episode!("source-rotation")

    assert {:ok, _session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder",
               nil,
               @commit
             )

    assert {:ok, claim} = Custody.claim_next("worker:source-rotation", 60)

    assert {:ok, bound} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:source-rotation"
             )

    assert {:ok, %{session: replacement}} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               bound.generation
             )

    assert replacement.generation == 2
    assert replacement.repository_source == @commit
  end

  test "a failover replacement keeps the exact source its predecessor pinned" do
    command = create_kernel_episode!("source-failover")

    assert {:ok, _session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder",
               nil,
               @branch
             )

    assert {:ok, claim} = Custody.claim_next("worker:source-failover", 60)

    assert {:ok, %{session: replacement}} =
             Custody.replace_session_after_placement_loss(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation
             )

    assert replacement.generation == 2
    assert replacement.repository_source == @branch
  end

  # Responder never persisted a pull-request-only session binding, so no row can
  # prove one. A session pinned before this contract stays already-bound with no
  # selector; rotating it must not synthesize `default` and quietly re-resolve
  # work that is already running somewhere else.
  test "a historical session without a selector is never relabeled or re-resolved" do
    command = create_kernel_episode!("source-historical")

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder"
             )

    {1, nil} =
      Repo.update_all(
        from(candidate in Session, where: candidate.id == ^session.id),
        set: [repository_source: nil]
      )

    assert {:ok, claim} = Custody.claim_next("worker:source-historical", 60)
    assert claim.session.repository_source == nil

    assert {:ok, bound} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:source-historical"
             )

    assert {:ok, %{session: replacement}} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               bound.generation
             )

    assert replacement.repository_source == nil
  end

  test "a malformed or workspace-free selector is refused before durable custody" do
    command = create_kernel_episode!("source-malformed")

    assert Custody.pin_episode(
             command.episode_id,
             "work-contributor",
             @policy_digest,
             nil,
             "responder",
             nil,
             %{"kind" => "branch", "name" => "refs/heads/main"}
           ) == {:error, {:invalid_work_custody, :repository_source}}

    assert Custody.pin_episode(
             command.episode_id,
             "work-contributor",
             @policy_digest,
             nil,
             "responder",
             nil,
             %{"kind" => "tag", "name" => "v1"}
           ) == {:error, {:invalid_work_custody, :repository_source}}

    assert Custody.pin_episode(
             command.episode_id,
             "work-read-only",
             @policy_digest,
             nil,
             nil,
             nil,
             @branch
           ) == {:error, {:invalid_work_custody, :repository_source}}

    assert Repo.aggregate(from(session in Session), :count) == 0
  end

  test "PostgreSQL refuses a source that no repository backs or that is not the union" do
    command = create_kernel_episode!("source-constraint")

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-contributor",
               @policy_digest,
               nil,
               "responder"
             )

    for invalid <- [
          ~s({"kind":"tag","name":"v1"}),
          ~s({"kind":"branch"}),
          ~s({"kind":"branch","name":"main","remote":"upstream"}),
          ~s({"kind":"pull_request","number":0}),
          ~s({"kind":"pull_request","number":1000001}),
          ~s({"kind":"commit","sha":"#{String.duplicate("A", 40)}"}),
          ~s({"kind":"commit","sha":"#{String.duplicate("a", 12)}"})
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE episode_work_sessions SET repository_source = $1 WHERE id = $2",
          [invalid, Ecto.UUID.dump!(session.id)]
        )
      end
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE episode_work_sessions SET repository_ref = NULL WHERE id = $1",
        [Ecto.UUID.dump!(session.id)]
      )
    end
  end

  test "a confirmed task offer carries its selector into the new linked session" do
    command = create_kernel_episode!("source-task-offer")

    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "instruction_ref" => "",
      "offer_ref" => "record:task_offer:source-task-offer",
      "prompt" => "Review the selected branch.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Review the selected branch"
    }

    assert {:ok, {:ok, pinned}} =
             Repo.transaction(fn ->
               Custody.pin_task_episode_in_transaction(
                 command.episode_id,
                 "work-contributor",
                 @policy_digest,
                 "responder",
                 nil,
                 workspace_task,
                 @branch
               )
             end)

    assert pinned.repository_source == @branch
    assert pinned.workspace_task == workspace_task
  end

  defp create_kernel_episode!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "work:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: ~U[2026-09-11 12:00:00.000000Z],
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end
end
