defmodule Ryker.ControlPlane.WorkspaceProjection do
  @moduledoc """
  Every retained worker session with its cleanup state and the safe action
  for it, plus read-only storage accounting and the exact next cleanup
  targets.

  Task sessions are the repository checkouts the Working copies page lists
  (`copies/1`); background learning sessions hold no checkout and are listed
  on the Learning page (`learning_sessions/0`). Both share one cleanup
  custody, so one confirmed action serves both pages.
  """
  alias Ryker.Config
  alias Ryker.ControlPlane.{Activity, PagedRelation, RepositoryNames, WorkingCopy}
  alias Ryker.CoopFleet
  alias Ryker.Episodes
  alias Ryker.Learning
  alias Ryker.Repo
  alias Ryker.Retention
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @preview_limit 25

  @doc """
  The working copies tasks hold, for the Working copies page: every copy in
  use, newest change first, and the removed ones a page at a time under
  `params["page"]`, newest first, with how many there are.

  One 100-row list held both and the Learning page's sessions, so the page
  counted only the removed copies that fitted beside them: 33 of 48 live on
  2026-10-05, the learning sessions taking the other rows (2026-10-04
  review).
  """
  @spec copies(map()) :: %{current: [map()], removed: PagedRelation.t()}
  def copies(params) do
    names = RepositoryNames.all()

    copies = WorkingCopy.Query.working_copies(WorkingCopy.Query.sessions())

    current =
      copies
      |> WorkingCopy.Query.kept()
      |> WorkingCopy.Query.ordered_by_recently_updated()
      |> Repo.all()
      |> items(names)

    removed =
      copies
      |> WorkingCopy.Query.removed()
      |> PagedRelation.read([desc: :updated_at, desc: :id], "page", params)

    %{current: current, removed: %{removed | items: items(removed.items, names)}}
  end

  @doc """
  The worker sessions background learning holds, for the Learning page: every
  one not removed yet, newest change first. Learning sessions hold no
  checkout, so the Working copies page does not list them.
  """
  @spec learning_sessions() :: [map()]
  def learning_sessions do
    WorkingCopy.Query.sessions()
    |> WorkingCopy.Query.learning()
    |> WorkingCopy.Query.kept()
    |> WorkingCopy.Query.ordered_by_recently_updated()
    |> Repo.all()
    |> items(RepositoryNames.all())
  end

  defp items(rows, names),
    do: rows |> Enum.map(&workspace_item(&1, names)) |> Activity.with_request_titles()

  @doc "One worker session by its external reference."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    row = WorkingCopy.Query.sessions() |> WorkingCopy.Query.listed(ref) |> Repo.peek()
    if row, do: {:ok, hd(items([row], RepositoryNames.all()))}, else: :not_found
  end

  def fetch(_ref), do: :not_found

  @doc """
  Read-only workspace storage accounting and the exact next cleanup targets:
  the first #{@preview_limit} copies cleanup claims, and how many are due
  (`preview_total`).

  Preview never mutates anything and never estimates a byte no worker measured:
  a worker that reported nothing is unknown, and a worker whose heartbeat has
  gone stale is reporting a stale measurement.
  """
  @spec storage() :: map()
  def storage do
    now = Repo.now!()
    {next, due} = Retention.Custody.eligible_copies(now, @preview_limit)
    settings = Config.get_env(:retention, %{})
    names = RepositoryNames.all()

    %{
      budget:
        Map.new(
          ~w(disposable_bytes_limit reclaim_target_seconds)a,
          &{&1, safe_setting(settings, &1)}
        ),
      preview: next |> Enum.map(&preview_item(&1, now, names)) |> with_requests(),
      preview_total: due,
      workers:
        CoopFleet.Worker.Query.all()
        |> CoopFleet.Worker.Query.ordered_by_id()
        |> Repo.all()
        |> Enum.map(&storage_item(&1, now))
    }
  end

  defp safe_setting(settings, key) when is_map(settings), do: Map.get(settings, key)
  defp safe_setting(_settings, _key), do: nil

  defp storage_item(%CoopFleet.Worker{} = worker, now) do
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

  defp measurement_state(%CoopFleet.Worker{storage: storage}, _now) when not is_map(storage),
    do: :unknown

  defp measurement_state(%CoopFleet.Worker{last_seen_at: %DateTime{} = last_seen_at}, now) do
    if DateTime.diff(now, last_seen_at, :second) <= 60, do: :fresh, else: :stale
  end

  defp measurement_state(_worker, _now), do: :stale

  defp preview_item({%Work.Session{} = session, eligible_at}, now, names) do
    %{
      eligible_age_seconds: UTCDateTime.age_seconds(now, eligible_at),
      episode_id: session.episode_id,
      kind: session.execution_kind,
      reason: preview_reason(session.cleanup_status),
      ref: session.external_ref,
      repository: workspace_label(session, names),
      status: session.cleanup_status,
      target: session.coop_session_id
    }
  end

  # The request each copy was made for, named as the Activity page names it: two copies of
  # one repository ready for cleanup read alike without it (2026-10-09).
  defp with_requests(items) do
    keys =
      items
      |> Enum.map(& &1.episode_id)
      |> Enum.reject(&is_nil/1)
      |> then(&Episodes.Episode.Query.by_ids/1)
      |> Episodes.Episode.Query.select_id_keys()
      |> Repo.all()
      |> Map.new()

    items
    |> Enum.map(&Map.put(&1, :episode_ref, Map.get(keys, &1.episode_id)))
    |> Activity.with_request_titles()
  end

  defp workspace_label(%Work.Session{execution_kind: :learning}, _names),
    do: "Background learning"

  defp workspace_label(%Work.Session{repository_ref: ref}, names) when is_binary(ref),
    do: Map.get(names, ref, ref)

  defp workspace_label(%Work.Session{}, _names), do: nil

  # What cleanup does next, in the words a person reading the page uses.
  defp preview_reason(:active), do: "Keep it briefly for follow-up questions, then remove it"
  defp preview_reason(:close_pending), do: "Close the worker session again"
  defp preview_reason(:grace), do: "The follow-up window ended; close the worker session"
  defp preview_reason(:plan_pending), do: "Check again what is safe to remove"
  defp preview_reason(:discard_pending), do: "Remove the copy"
  defp preview_reason(:retained), do: "Check again whether the kept changes can be removed"
  defp preview_reason(status), do: Atom.to_string(status)

  defp workspace_item(
         {%Work.Session{} = session, episode_state, episode_ref, learning_run, learning_batch},
         names
       ) do
    %{
      action: workspace_action(session),
      kind: "coop_session",
      episode_id: session.episode_id,
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

  defp learning_state(%Work.Session{execution_kind: kind}, _run, _batch) when kind != :learning,
    do: nil

  defp learning_state(
         %Work.Session{execution_kind: :learning},
         %Learning.LearningRun{remote_stopped_at: %DateTime{}},
         _batch
       ),
       do: :cleanup_pending

  defp learning_state(
         %Work.Session{execution_kind: :learning},
         %Learning.LearningRun{error_code: "learning_remote_unresolved"},
         %Learning.Batch{status: :deferred}
       ),
       do: :retry_scheduled

  defp learning_state(
         %Work.Session{execution_kind: :learning},
         %Learning.LearningRun{error_code: "learning_remote_unresolved"},
         _batch
       ),
       do: :checking_worker

  defp learning_state(%Work.Session{execution_kind: :learning}, _run, _batch), do: :active

  defp learning_retry_at(%Learning.Batch{status: :deferred, next_attempt_at: retry_at}),
    do: retry_at

  defp learning_retry_at(_batch), do: nil

  defp workspace_action(%Work.Session{
         cleanup_status: :blocked,
         cleanup_blocked_from: blocked_from
       })
       when blocked_from in [:close_pending, :plan_pending, :discard_pending],
       do: :rearm

  defp workspace_action(%Work.Session{
         cleanup_status: :retained,
         discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => true}},
         discard_plan_fingerprint: fingerprint,
         retained_reason: "unpublished_unmerged"
       })
       when is_binary(fingerprint),
       do: :discard_unmerged

  defp workspace_action(%Work.Session{}), do: nil
end
