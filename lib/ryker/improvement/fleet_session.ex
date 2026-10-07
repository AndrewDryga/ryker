defmodule Ryker.Improvement.FleetSession do
  @moduledoc """
  The worker session one analysis run executes in: workspace-free and
  read-only, like a learning session, and owned by exactly that run
  (execution kind `improvement`). Cleanup closes it once the run has stopped
  (`Ryker.Retention.Custody`).
  """

  alias Ryker.Improvement.AnalysisRun
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Session}

  @doc "The task reference Coop knows the run's session by."
  @spec external_ref(AnalysisRun.t()) :: String.t()
  def external_ref(%AnalysisRun{id: id}), do: "ryker-improvement:#{id}"

  @doc """
  Whether a worker would take a new analysis session of this policy now,
  asked without taking a slot. A transport that cannot say is not asked.
  """
  @spec placeable?(map()) :: boolean()
  def placeable?(%{api: api, client: client, policy: policy, policy_digest: digest}) do
    session = %Session{execution_kind: :improvement, policy: policy, policy_digest: digest}

    if Code.ensure_loaded?(api) and function_exported?(api, :accepts_session?, 2),
      do: api.accepts_session?(client, session),
      else: true
  end

  def placeable?(_settings), do: true

  @doc """
  The run's session, created once with the run's exact policy, and announced
  when it is: every step asks for it, and each one announced it, so every
  page listing sessions redrew every two seconds while a run was out
  (2026-10-04 review).
  """
  @spec ensure(AnalysisRun.t()) :: {:ok, Session.t()} | {:error, term()}
  def ensure(%AnalysisRun{} = run) do
    Repo.transaction(fn ->
      session = existing(run) || create!(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest,
        do: Repo.rollback(:improvement_session_authority_conflict)

      session
    end)
  end

  defp create!(run) do
    Repo.insert!(
      %Session{
        id: Ecto.UUID.generate(),
        execution_kind: :improvement,
        improvement_run_id: run.id,
        policy: run.policy,
        policy_digest: run.policy_digest,
        external_ref: external_ref(run)
      },
      on_conflict: :nothing
    )

    run |> locked() |> tap(&Custody.broadcast_session_updated/1)
  end

  @doc "Binds the run's session to the Coop session created for it, once."
  @spec bind(AnalysisRun.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def bind(%AnalysisRun{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = locked(run)

      case session.coop_session_id do
        nil ->
          session
          |> Ecto.Changeset.change(coop_session_id: remote_id)
          |> Repo.update!()
          |> tap(&Custody.broadcast_session_updated/1)

        ^remote_id ->
          session

        _other ->
          Repo.rollback(:improvement_session_identity_conflict)
      end
    end)
  end

  def bind(_run, _remote_id), do: {:error, :improvement_session_identity_conflict}

  @doc "The run's session, which `ensure/1` makes."
  @spec fetch_for_run(AnalysisRun.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def fetch_for_run(%AnalysisRun{id: id}), do: Repo.fetch(Session.Query.by_improvement_run_id(id))

  @doc "The Coop session the run's session is bound to, or nil before it is."
  @spec coop_session_id(AnalysisRun.t()) :: String.t() | nil
  def coop_session_id(%AnalysisRun{id: id}) do
    id
    |> Session.Query.by_improvement_run_id()
    |> Session.Query.select_coop_session_ids()
    |> Repo.one()
  end

  defp existing(run), do: run |> run_session() |> Repo.one()
  defp locked(run), do: run |> run_session() |> Repo.one!()

  defp run_session(run),
    do: run.id |> Session.Query.by_improvement_run_id() |> Session.Query.lock_for_update()
end
