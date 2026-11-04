defmodule Ryker.Learning.FleetSession do
  @moduledoc "A source-free execution session owned by one frozen learning judgment."
  alias Ryker.Adapter
  alias Ryker.Learning.{Batches, LearningRun}
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Work

  def external_ref(%LearningRun{id: id}), do: "ryker-learning:#{id}"

  defp create_generation(%LearningRun{id: id}) do
    generation =
      id
      |> Work.Session.Query.by_learning_run_id()
      |> Work.Session.Query.select_create_generation()
      |> Repo.one()

    generation || 1
  end

  def create_key(%LearningRun{id: id} = run), do: create_key(id, create_generation(run))

  def create_key(%Work.Session{learning_run_id: id, create_generation: generation})
      when is_binary(id),
      do: create_key(id, generation)

  defp create_key(id, 1), do: "ryker:learning:create:#{id}"
  defp create_key(id, generation), do: "ryker:learning:create:#{id}:g#{generation}"

  # The native failed-create receipt proves no session or model exists under
  # this exact key. Retry only physical creation, keeping the logical start.
  def advance_create(claim, %LearningRun{id: id}, key, operation) do
    Batches.with_lease(claim, fn -> advance_create_locked(claim, id, key, operation) end)
  end

  defp advance_create_locked(claim, id, key, operation) do
    run = id |> LearningRun.Query.by_id() |> LearningRun.Query.lock_for_update() |> Repo.fetch!()
    session = run |> run_session() |> Repo.fetch!()

    unless unsubmitted_create?(claim, run, session, key) and storage_refusal?(operation),
      do: Repo.rollback(:learning_storage_refusal_unconfirmed)

    run |> Ecto.Changeset.change(create_window_started_at: nil) |> Repo.update!()

    updated =
      session
      |> Work.Session.Changeset.advance_create(session.create_generation + 1)
      |> Repo.update!()

    Work.Custody.broadcast_session_updated(updated)
    {:ok, updated}
  end

  defp unsubmitted_create?(claim, run, session, key) do
    run.batch_id == claim.batch.id and not is_nil(run.started_at) and
      run.status == :prepared and is_nil(run.remote_stopped_at) and
      is_nil(run.submit_revision) and is_nil(run.coop_turn_id) and
      is_nil(session.coop_session_id) and key == create_key(run.id, session.create_generation)
  end

  defp storage_refusal?(
         %{
           "id" => id,
           "method" => "CreateRemoteSession",
           "state" => "failed",
           "error_code" => "storage_unavailable"
         } = operation
       ) do
    Reference.valid?(id) and is_nil(operation["resource_id"]) and
      operation["resource_type"] in [nil, ""]
  end

  defp storage_refusal?(_operation), do: false

  @doc """
  Whether a worker would take a new learning session of this policy now, asked
  without taking a slot. A transport that cannot say is not asked.
  """
  def placeable?(%{api: api, client: client, policy: policy, policy_digest: digest}) do
    session = %Work.Session{execution_kind: :learning, policy: policy, policy_digest: digest}

    if Adapter.implements?(api, accepts_session?: 2),
      do: api.accepts_session?(client, session),
      else: true
  end

  def placeable?(_settings), do: true

  def ensure(%LearningRun{} = run) do
    Repo.transaction(fn ->
      current =
        run.id |> LearningRun.Query.by_id() |> LearningRun.Query.lock_for_share() |> Repo.fetch!()

      unless current.policy == run.policy and current.policy_digest == run.policy_digest,
        do: Repo.rollback(:learning_session_authority_conflict)

      session = run |> run_session() |> Repo.peek() || create!(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest,
        do: Repo.rollback(:learning_session_authority_conflict)

      session
    end)
  end

  # Announced when it is made: every step asks for it, and each one announced
  # it, so every page listing sessions redrew while a batch was out.
  defp create!(run) do
    Repo.insert!(
      %Work.Session{
        execution_kind: :learning,
        learning_run_id: run.id,
        policy: run.policy,
        policy_digest: run.policy_digest,
        external_ref: external_ref(run)
      },
      on_conflict: :nothing
    )

    run |> run_session() |> Repo.fetch!() |> tap(&Work.Custody.broadcast_session_updated/1)
  end

  def bind(%LearningRun{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = run |> run_session() |> Repo.fetch!()

      case session.coop_session_id do
        nil ->
          session
          |> Ecto.Changeset.change(coop_session_id: remote_id)
          |> Repo.update!()
          |> tap(&Work.Custody.broadcast_session_updated/1)

        ^remote_id ->
          session

        _ ->
          Repo.rollback(:learning_session_identity_conflict)
      end
    end)
  end

  defp run_session(run),
    do: run.id |> Work.Session.Query.by_learning_run_id() |> Work.Session.Query.lock_for_update()
end
