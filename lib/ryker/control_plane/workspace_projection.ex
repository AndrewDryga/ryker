defmodule Ryker.ControlPlane.WorkspaceProjection do
  @moduledoc """
  The Workspaces page: every retained worker session with its cleanup state
  and the safe operator action for it, plus read-only storage accounting and
  the exact next cleanup targets.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.Activity
  alias Ryker.CoopFleet.Worker, as: FleetWorker
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Work.Session

  @doc "The newest hundred worker sessions with their cleanup state and safe action."
  def list(_params) do
    # A learning session has no episode; an inner join left every learning
    # working copy, and any blocked cleanup of one, off this page. Admission
    # sessions are routing, not working copies a task or a learning run keeps.
    Repo.all(
      from(session in Session,
        left_join: episode in Episode,
        on: episode.id == session.episode_id,
        where: session.execution_kind in [:work, :learning],
        order_by: [desc: session.updated_at, desc: session.id],
        limit: 100,
        select: {session, episode.state, episode.key}
      )
    )
    |> Enum.map(&workspace_item/1)
    |> Activity.with_request_titles()
  end

  @doc "One worker session by its external reference."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             left_join: episode in Episode,
             on: episode.id == session.episode_id,
             where: session.external_ref == ^ref,
             where: session.execution_kind in [:work, :learning],
             select: {session, episode.state, episode.key}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> workspace_item() |> then(&Activity.with_request_titles([&1])) |> hd()}
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

    %{
      budget:
        Map.new(
          ~w(disposable_bytes_limit reclaim_target_seconds storage_high_watermark_bytes
             storage_low_watermark_bytes storage_reserve_bytes)a,
          &{&1, safe_setting(settings, &1)}
        ),
      preview: Enum.map(RetentionCustody.eligible_preview(now, 25), &preview_item(&1, now)),
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

  defp preview_item({%Session{} = session, eligible_at}, now) do
    %{
      eligible_age_seconds: age_seconds(now, eligible_at),
      kind: session.execution_kind,
      reason: preview_reason(session.cleanup_status),
      ref: session.external_ref,
      repository: session.repository_ref,
      status: session.cleanup_status,
      target: session.coop_session_id
    }
  end

  defp preview_reason(:active), do: "close the remote session"
  defp preview_reason(:close_pending), do: "retry the exact close"
  defp preview_reason(:grace), do: "grace expired; ask Coop for a discard plan"
  defp preview_reason(:plan_pending), do: "retry the exact discard plan"
  defp preview_reason(:discard_pending), do: "discard the planned workspace"
  defp preview_reason(:retained), do: "replan from fresh workspace evidence"
  defp preview_reason(status), do: Atom.to_string(status)

  defp age_seconds(_now, nil), do: 0

  defp age_seconds(%DateTime{} = now, %NaiveDateTime{} = value),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), value, :second), 0)

  defp age_seconds(now, value), do: max(DateTime.diff(now, value, :second), 0)

  defp workspace_item({%Session{} = session, episode_state, episode_ref}) do
    %{
      action: workspace_action(session),
      kind: "coop_session",
      episode_ref: episode_ref,
      execution_kind: session.execution_kind,
      repository: session.repository_ref,
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
