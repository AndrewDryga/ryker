defmodule Ryker.ControlPlane.WorkspaceProjection do
  @moduledoc """
  Every retained worker session with its cleanup state and the safe action
  for it, plus read-only storage accounting and the exact next cleanup
  targets.

  Task sessions are the repository checkouts the Working copies page lists;
  background learning sessions hold no checkout and are listed on the
  Learning page. Both share one cleanup custody, so one list and one
  confirmed action serve both pages, and each page shows only its own.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Activity, RepositoryProjection}
  alias Ryker.CoopFleet.Worker, as: FleetWorker
  alias Ryker.Episodes.Episode
  alias Ryker.Learning.Batch, as: LearningBatch
  alias Ryker.Repo
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.State.LearningRun
  alias Ryker.Work.Session

  @doc "Current worker sessions followed by recent removed history, with safe actions."
  def list(_params) do
    names = RepositoryProjection.names()

    # A learning session has no episode; an inner join left every learning
    # session, and any blocked cleanup of one, off both pages. Admission
    # sessions are routing, not sessions a task or a learning run keeps.
    Repo.all(
      from(session in Session,
        left_join: episode in Episode,
        on: episode.id == session.episode_id,
        left_join: learning_run in LearningRun,
        on: learning_run.id == session.learning_run_id,
        left_join: learning_batch in LearningBatch,
        on: learning_batch.id == learning_run.batch_id,
        where:
          session.execution_kind == :learning or
            (session.execution_kind == :work and not is_nil(session.repository_ref)),
        order_by: [
          asc: fragment("? = 'discarded'", session.cleanup_status),
          desc: session.updated_at,
          desc: session.id
        ],
        limit: 100,
        select: {session, episode.state, episode.key, learning_run, learning_batch}
      )
    )
    |> Enum.map(&workspace_item(&1, names))
    |> Activity.with_request_titles()
  end

  @doc "One worker session by its external reference."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             left_join: episode in Episode,
             on: episode.id == session.episode_id,
             left_join: learning_run in LearningRun,
             on: learning_run.id == session.learning_run_id,
             left_join: learning_batch in LearningBatch,
             on: learning_batch.id == learning_run.batch_id,
             where: session.external_ref == ^ref,
             where: session.execution_kind in [:work, :learning],
             select: {session, episode.state, episode.key, learning_run, learning_batch}
           )
         ) do
      nil ->
        :not_found

      row ->
        {:ok,
         row
         |> workspace_item(RepositoryProjection.names())
         |> then(&Activity.with_request_titles([&1]))
         |> hd()}
    end
  end

  def fetch(_ref), do: :not_found

  @doc """
  Read-only workspace storage accounting and the exact next cleanup targets.

  Preview never mutates anything and never estimates a byte no worker measured:
  a worker that reported nothing is unknown, and a worker whose heartbeat has
  gone stale is reporting a stale measurement.
  """
  @spec storage() :: map()
  def storage do
    now = Repo.now!()
    settings = Application.get_env(:ryker, :retention, %{})
    names = RepositoryProjection.names()

    %{
      budget:
        Map.new(
          ~w(disposable_bytes_limit reclaim_target_seconds storage_high_watermark_bytes
             storage_low_watermark_bytes storage_reserve_bytes)a,
          &{&1, safe_setting(settings, &1)}
        ),
      preview:
        Enum.map(RetentionCustody.eligible_preview(now, 25), &preview_item(&1, now, names)),
      workers:
        from(worker in FleetWorker, order_by: [asc: worker.id])
        |> Repo.all()
        |> Enum.map(&storage_item(&1, now))
    }
  end

  defp safe_setting(settings, key) when is_map(settings), do: Map.get(settings, key)
  defp safe_setting(_settings, _key), do: nil

  defp storage_item(%FleetWorker{} = worker, now) do
    storage = worker.storage

    %{
      allocation: storage && storage["allocation"],
      bytes:
        Map.new(
          ~w(capacity_bytes free_bytes reserve_bytes disposable_bytes protected_bytes
             unattributed_bytes),
          &{&1, storage && storage[&1]}
        ),
      id: worker.id,
      last_seen_at: worker.last_seen_at,
      measured_at: storage && storage["measured_at"],
      measurement: measurement_state(worker, now),
      reclaimed_bytes: worker.storage_reclaimed_bytes,
      refusal_reason: storage && storage["refusal_reason"],
      state: worker.state
    }
  end

  defp measurement_state(%FleetWorker{storage: storage}, _now) when not is_map(storage),
    do: :unknown

  defp measurement_state(%FleetWorker{last_seen_at: %DateTime{} = last_seen_at}, now) do
    if DateTime.diff(now, last_seen_at, :second) <= 60, do: :fresh, else: :stale
  end

  defp measurement_state(_worker, _now), do: :stale

  defp preview_item({%Session{} = session, eligible_at}, now, names) do
    %{
      eligible_age_seconds: age_seconds(now, eligible_at),
      kind: session.execution_kind,
      reason: preview_reason(session.cleanup_status),
      ref: session.external_ref,
      repository: workspace_label(session, names),
      status: session.cleanup_status,
      target: session.coop_session_id
    }
  end

  defp workspace_label(%Session{execution_kind: :learning}, _names), do: "Background learning"

  defp workspace_label(%Session{repository_ref: ref}, names) when is_binary(ref),
    do: Map.get(names, ref, ref)

  defp workspace_label(%Session{}, _names), do: nil

  # What cleanup does next, in the words a person reading the page uses.
  defp preview_reason(:active), do: "Keep it briefly for follow-up questions, then remove it"
  defp preview_reason(:close_pending), do: "Close the worker session again"
  defp preview_reason(:grace), do: "The follow-up window ended; close the worker session"
  defp preview_reason(:plan_pending), do: "Check again what is safe to remove"
  defp preview_reason(:discard_pending), do: "Remove the copy"
  defp preview_reason(:retained), do: "Check again whether the kept changes can be removed"
  defp preview_reason(status), do: Atom.to_string(status)

  defp age_seconds(_now, nil), do: 0

  defp age_seconds(%DateTime{} = now, %NaiveDateTime{} = value),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), value, :second), 0)

  defp age_seconds(now, value), do: max(DateTime.diff(now, value, :second), 0)

  defp workspace_item(
         {%Session{} = session, episode_state, episode_ref, learning_run, learning_batch},
         names
       ) do
    %{
      action: workspace_action(session),
      kind: "coop_session",
      episode_ref: episode_ref,
      execution_kind: session.execution_kind,
      learning_state: learning_state(session, learning_run, learning_batch),
      learning_retry_at: learning_retry_at(learning_batch),
      repository: workspace_label(session, names),
      discard_after: session.discard_after,
      ref: session.external_ref,
      state: episode_state,
      status: session.cleanup_status,
      summary:
        session.cleanup_last_error_code || session.retained_reason || session.repository_ref ||
          "no repository",
      updated_at: session.updated_at
    }
  end

  defp learning_state(%Session{execution_kind: kind}, _run, _batch) when kind != :learning,
    do: nil

  defp learning_state(
         %Session{execution_kind: :learning},
         %LearningRun{remote_stopped_at: %DateTime{}},
         _batch
       ),
       do: :cleanup_pending

  defp learning_state(
         %Session{execution_kind: :learning},
         %LearningRun{error_code: "learning_remote_unresolved"},
         %LearningBatch{status: :deferred}
       ),
       do: :retry_scheduled

  defp learning_state(
         %Session{execution_kind: :learning},
         %LearningRun{error_code: "learning_remote_unresolved"},
         _batch
       ),
       do: :checking_worker

  defp learning_state(%Session{execution_kind: :learning}, _run, _batch), do: :active

  defp learning_retry_at(%LearningBatch{status: :deferred, next_attempt_at: retry_at}),
    do: retry_at

  defp learning_retry_at(_batch), do: nil

  defp workspace_action(%Session{
         cleanup_status: :blocked,
         cleanup_blocked_from: blocked_from
       })
       when blocked_from in [:close_pending, :plan_pending, :discard_pending],
       do: :rearm

  defp workspace_action(%Session{
         cleanup_status: :retained,
         discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => true}},
         discard_plan_fingerprint: fingerprint,
         retained_reason: "unpublished_unmerged"
       })
       when is_binary(fingerprint),
       do: :discard_unmerged

  defp workspace_action(%Session{}), do: nil
end
