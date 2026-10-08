defmodule Ryker.Publication.Followups.Leases do
  @moduledoc """
  What runs a follow-up: the worker claims a poll that is due or a lifecycle
  event waiting for delivery, holds it under a lease while it works, renews
  the lease, and after a failed delivery hands the claim back with a delay. A
  failed poll is handed back by `Followups.Polls`, which owns the deadline.

  Every step that writes after a claim first proves the lease is still the
  caller's and still live, so a worker that lost its lease changes nothing.
  """
  alias Ryker.ErrorDetail
  alias Ryker.Lease
  alias Ryker.Publication.{Followup, LifecycleEvent}
  alias Ryker.Publication.Followups.Store
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  def claim_poll(worker_ref, lease_seconds) do
    with :ok <- Store.reference(worker_ref, :worker_ref),
         :ok <- Store.positive(lease_seconds, :lease_seconds) do
      Store.transaction(fn -> claim_poll_locked(worker_ref, lease_seconds) end)
    end
  end

  def claim_delivery(worker_ref, lease_seconds) do
    with :ok <- Store.reference(worker_ref, :worker_ref),
         :ok <- Store.positive(lease_seconds, :lease_seconds) do
      Store.transaction(fn -> claim_delivery_locked(worker_ref, lease_seconds) end)
    end
  end

  def next_due_at(%DateTime{} = since) do
    polls = Repo.one(Followup.Query.select_next_due_after(since))
    deliveries = Repo.one(LifecycleEvent.Query.select_next_due_after(since))

    UTCDateTime.earliest(polls ++ deliveries)
  end

  def renew_poll(publication_ref, lease_ref, lease_seconds) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(lease_seconds, :lease_seconds) do
      Store.transaction(fn -> renew_poll_locked(publication_ref, lease_ref, lease_seconds) end)
    end
  end

  def renew_delivery(event_ref, lease_ref, lease_seconds) do
    with :ok <- Store.reference(event_ref, :event_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(lease_seconds, :lease_seconds) do
      Store.transaction(fn -> renew_delivery_locked(event_ref, lease_ref, lease_seconds) end)
    end
  end

  def defer_delivery(event_ref, lease_ref, delay_seconds, reason) do
    with :ok <- Store.reference(event_ref, :event_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(delay_seconds, :delay_seconds) do
      Store.transaction(fn ->
        defer_delivery_locked(event_ref, lease_ref, delay_seconds, reason)
      end)
    end
  end

  # --- the lease fences -----------------------------------------------------

  @doc """
  Locks a publication's follow-up, with the publication, for a poll whose lease
  `lease_ref` still holds; returns the database time the lease was checked at.
  """
  @spec fetch_and_lock_poll(String.t(), String.t()) ::
          {:ok, Followup.t(), Publication.t(), DateTime.t()} | {:error, atom()}
  def fetch_and_lock_poll(publication_ref, lease_ref) do
    now = Repo.now!()

    query =
      publication_ref
      |> Followup.Query.by_publication_ref()
      |> Followup.Query.lock_for_update()

    case Repo.fetch(query) do
      {:error, :not_found} ->
        {:error, :publication_followup_not_found}

      {:ok, {followup, publication}} ->
        if Lease.held?(followup, lease_ref, now),
          do: {:ok, followup, publication, now},
          else: {:error, :publication_followup_lease_lost}
    end
  end

  @doc "Whether `lease_ref` still holds a live lease on a pending delivery."
  @spec live_event_lease(LifecycleEvent.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :publication_lifecycle_lease_lost}
  def live_event_lease(%LifecycleEvent{} = event, lease_ref, now) do
    if event.delivery_state == :pending and Lease.held?(event, lease_ref, now),
      do: :ok,
      else: {:error, :publication_lifecycle_lease_lost}
  end

  # --- claims ---------------------------------------------------------------

  defp claim_poll_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    query =
      Followup.Query.pollable()
      |> Followup.Query.due_unleased_at(now)
      |> Followup.Query.ordered_by_next_poll_at()
      |> Followup.Query.limit_to(1)
      |> Followup.Query.select_with_publications()
      |> Followup.Query.lock_next_free()

    case Repo.fetch(query) do
      {:error, :not_found} ->
        nil

      {:ok, {followup, publication}} ->
        lease_ref = "publication-followup-lease:#{Ecto.UUID.generate()}"

        followup =
          Store.update_followup!(
            followup,
            %{
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref
            },
            now
          )

        %{followup: followup, lease_ref: lease_ref, publication: publication}
    end
  end

  defp claim_delivery_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    query =
      LifecycleEvent.Query.pending()
      |> LifecycleEvent.Query.due_unleased_at(now)
      |> LifecycleEvent.Query.ordered_by_oldest()
      |> LifecycleEvent.Query.limit_to(1)
      |> LifecycleEvent.Query.lock_next_free()

    case Repo.fetch(query) do
      {:error, :not_found} ->
        nil

      {:ok, event} ->
        lease_ref = "publication-lifecycle-lease:#{Ecto.UUID.generate()}"

        event =
          Store.update_event!(
            event,
            %{
              attempt_count: event.attempt_count + 1,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref,
              next_attempt_at: nil
            },
            now
          )

        %{event: event, lease_ref: lease_ref}
    end
  end

  # --- renewals -------------------------------------------------------------

  defp renew_poll_locked(publication_ref, lease_ref, lease_seconds) do
    case fetch_and_lock_poll(publication_ref, lease_ref) do
      {:ok, followup, _publication, now} ->
        Store.update_followup!(
          followup,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp renew_delivery_locked(event_ref, lease_ref, lease_seconds) do
    now = Repo.now!()

    case Store.fetch_and_lock_lifecycle_event(event_ref) do
      {:ok, event} -> renew_locked_event(event, lease_ref, lease_seconds, now)
      {:error, :not_found} -> Repo.rollback(:publication_lifecycle_event_not_found)
    end
  end

  defp renew_locked_event(event, lease_ref, lease_seconds, now) do
    case live_event_lease(event, lease_ref, now) do
      :ok ->
        Store.update_event!(
          event,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # --- deferrals ------------------------------------------------------------

  defp defer_delivery_locked(event_ref, lease_ref, delay_seconds, reason) do
    now = Repo.now!()

    case Store.fetch_and_lock_lifecycle_event(event_ref) do
      {:ok, event} -> defer_locked_event(event, lease_ref, delay_seconds, reason, now)
      {:error, :not_found} -> Repo.rollback(:publication_lifecycle_event_not_found)
    end
  end

  defp defer_locked_event(event, lease_ref, delay_seconds, reason, now) do
    case live_event_lease(event, lease_ref, now) do
      :ok ->
        Store.update_event!(
          event,
          %{
            last_error: ErrorDetail.detail(reason),
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, delay_seconds, :second)
          },
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end
end
