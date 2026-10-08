defmodule Ryker.Learning.FleetSession do
  @moduledoc "A workspace-free execution session owned by one frozen learning judgment."
  alias Ryker.Adapter
  alias Ryker.Learning.LearningRun
  alias Ryker.Repo
  alias Ryker.Work

  def external_ref(%LearningRun{id: id}), do: "ryker-learning:#{id}"

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
        run.id |> LearningRun.Query.by_id() |> LearningRun.Query.lock_for_share() |> Repo.one!()

      unless current.policy == run.policy and current.policy_digest == run.policy_digest,
        do: Repo.rollback(:learning_session_authority_conflict)

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

      session = locked(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest,
        do: Repo.rollback(:learning_session_authority_conflict)

      Work.Custody.broadcast_session_updated(session)
      session
    end)
  end

  def bind(%LearningRun{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = locked(run)

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

  defp locked(run) do
    run.id
    |> Work.Session.Query.by_learning_run_id()
    |> Work.Session.Query.lock_for_update()
    |> Repo.one!()
  end
end
