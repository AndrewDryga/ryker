defmodule Ryker.Learning.FleetSession do
  @moduledoc "A workspace-free execution session owned by one frozen learning judgment."
  import Ecto.Query
  alias Ryker.Repo
  alias Ryker.State.LearningRun
  alias Ryker.Work.Session

  def external_ref(%LearningRun{id: id}), do: "ryker-learning:#{id}"

  def ensure(%LearningRun{} = run) do
    Repo.transaction(fn ->
      current = Repo.one!(from(r in LearningRun, where: r.id == ^run.id, lock: "FOR SHARE"))

      unless current.policy == run.policy and current.policy_digest == run.policy_digest,
        do: Repo.rollback(:learning_session_authority_conflict)

      Repo.insert!(
        %Session{
          id: Ecto.UUID.generate(),
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

      session
    end)
  end

  def bind(%LearningRun{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = locked(run)

      case session.coop_session_id do
        nil -> session |> Ecto.Changeset.change(coop_session_id: remote_id) |> Repo.update!()
        ^remote_id -> session
        _ -> Repo.rollback(:learning_session_identity_conflict)
      end
    end)
  end

  defp locked(run),
    do:
      Repo.one!(
        from(s in Session,
          where: s.execution_kind == :learning and s.learning_run_id == ^run.id,
          lock: "FOR UPDATE"
        )
      )
end
