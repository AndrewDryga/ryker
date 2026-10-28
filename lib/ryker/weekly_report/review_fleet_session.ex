defmodule Ryker.WeeklyReport.ReviewFleetSession do
  @moduledoc """
  The worker session one weekly review executes in: workspace-free and
  read-only, like a learning session, and owned by exactly that run
  (execution kind `weekly_review`). Cleanup closes it once the run has stopped
  (`Ryker.Retention.Custody`).
  """
  alias Ryker.Adapter
  alias Ryker.Repo
  alias Ryker.WeeklyReport.Review
  alias Ryker.Work

  @doc "The task reference Coop knows the run's session by."
  @spec external_ref(Review.t()) :: String.t()
  def external_ref(%Review{id: id}), do: "ryker-weekly-review:#{id}"

  @doc """
  Whether a worker would take a new analysis session of this policy now,
  asked without taking a slot. A transport that cannot say is not asked.
  """
  @spec placeable?(map()) :: boolean()
  def placeable?(%{api: api, client: client, policy: policy, policy_digest: digest}) do
    session = %Work.Session{execution_kind: :weekly_review, policy: policy, policy_digest: digest}

    if Adapter.implements?(api, accepts_session?: 2),
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
  @spec ensure(Review.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def ensure(%Review{} = run) do
    Repo.transaction(fn ->
      session = run |> run_session() |> Repo.peek() || create!(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest,
        do: Repo.rollback(:weekly_review_session_authority_conflict)

      session
    end)
  end

  defp create!(run) do
    Repo.insert!(
      %Work.Session{
        execution_kind: :weekly_review,
        weekly_review_id: run.id,
        policy: run.policy,
        policy_digest: run.policy_digest,
        external_ref: external_ref(run)
      },
      on_conflict: :nothing
    )

    run |> run_session() |> Repo.fetch!() |> tap(&Work.Custody.broadcast_session_updated/1)
  end

  @doc "Binds the run's session to the Coop session created for it, once."
  @spec bind(Review.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def bind(%Review{} = run, remote_id)
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

        _other ->
          Repo.rollback(:weekly_review_session_identity_conflict)
      end
    end)
  end

  def bind(_run, _remote_id), do: {:error, :weekly_review_session_identity_conflict}

  @doc "The run's session, which `ensure/1` makes."
  @spec fetch_for_run(Review.t()) :: {:ok, Work.Session.t()} | {:error, :not_found}
  def fetch_for_run(%Review{id: id}),
    do: Repo.fetch(Work.Session.Query.by_weekly_review_id(id))

  @doc "The Coop session the run's session is bound to, or nil before it is."
  @spec coop_session_id(Review.t()) :: String.t() | nil
  def coop_session_id(%Review{id: id}) do
    id
    |> Work.Session.Query.by_weekly_review_id()
    |> Work.Session.Query.select_coop_session_ids()
    |> Repo.one()
  end

  defp run_session(run) do
    run.id |> Work.Session.Query.by_weekly_review_id() |> Work.Session.Query.lock_for_update()
  end
end
