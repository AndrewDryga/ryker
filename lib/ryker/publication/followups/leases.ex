defmodule Ryker.Publication.Followups.Leases do
  @moduledoc """
  What runs a follow-up: the worker claims a poll that is due or a lifecycle
  event waiting for delivery, holds it under a lease while it works, renews
  the lease, and after a failure hands the claim back with a delay.

  Every step that writes after a claim first proves the lease is still the
  caller's and still live, so a worker that lost its lease changes nothing.
  """

  import Ecto.Query

  alias Ryker.Publication.{Followup, LifecycleEvent, Publication}
  alias Ryker.Publication.Followups.Store
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

  # A follow-up polls only while its publication is published. A task whose
  # newer change is back in review, or blocked there, leaves its pull request's
  # poll due and waiting on purpose; readiness counts by this same query.
  def pollable_query do
    from(followup in Followup,
      as: :followup,
      join: publication in Publication,
      as: :publication,
      on:
        publication.id == followup.publication_id and
          publication.episode_id == followup.episode_id,
      where: publication.status == :published
    )
  end

  def next_due_at(%DateTime{} = since) do
    polls =
      Repo.one(
        from(followup in pollable_query(),
          select: [
            filter(min(followup.next_poll_at), followup.next_poll_at > ^since),
            filter(min(followup.lease_expires_at), followup.lease_expires_at > ^since)
          ]
        )
      )

    deliveries =
      Repo.one(
        from(event in LifecycleEvent,
          where: event.delivery_state == :pending,
          select: [
            filter(min(event.next_attempt_at), event.next_attempt_at > ^since),
            filter(min(event.lease_expires_at), event.lease_expires_at > ^since)
          ]
        )
      )

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

  def defer_poll(publication_ref, lease_ref, delay_seconds, reason) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(delay_seconds, :delay_seconds) do
      Store.transaction(fn ->
        defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason)
      end)
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
  @spec lock_poll(String.t(), String.t()) ::
          {:ok, Followup.t(), Publication.t(), DateTime.t()} | {:error, atom()}
  def lock_poll(publication_ref, lease_ref) do
    now = Repo.now!()

    query =
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where: publication.ref == ^publication_ref,
        select: {followup, publication},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil ->
        {:error, :publication_followup_not_found}

      {followup, publication} ->
        if followup.lease_ref == lease_ref and is_struct(followup.lease_expires_at, DateTime) and
             DateTime.compare(followup.lease_expires_at, now) == :gt,
           do: {:ok, followup, publication, now},
           else: {:error, :publication_followup_lease_lost}
    end
  end

  @doc "Whether `lease_ref` still holds a live lease on a pending delivery."
  @spec live_event_lease(LifecycleEvent.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :publication_lifecycle_lease_lost}
  def live_event_lease(event, lease_ref, now) do
    if event.delivery_state == :pending and event.lease_ref == lease_ref and
         is_struct(event.lease_expires_at, DateTime) and
         DateTime.compare(event.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :publication_lifecycle_lease_lost}
  end

  # --- claims ---------------------------------------------------------------

  defp claim_poll_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    query =
      from([followup: followup, publication: publication] in pollable_query(),
        where:
          followup.next_poll_at <= ^now and
            (is_nil(followup.lease_expires_at) or followup.lease_expires_at <= ^now),
        order_by: [asc: followup.next_poll_at, asc: followup.id],
        limit: 1,
        select: {followup, publication},
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(query) do
      nil ->
        nil

      {followup, publication} ->
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
      from(event in LifecycleEvent,
        where:
          event.delivery_state == :pending and
            (is_nil(event.next_attempt_at) or event.next_attempt_at <= ^now) and
            (is_nil(event.lease_expires_at) or event.lease_expires_at <= ^now),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(query) do
      nil ->
        nil

      event ->
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
    case lock_poll(publication_ref, lease_ref) do
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

    case Store.lock_lifecycle_event(event_ref) do
      %LifecycleEvent{} = event ->
        renew_locked_event(event, lease_ref, lease_seconds, now)

      nil ->
        Repo.rollback(:publication_lifecycle_event_not_found)
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

  defp defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason) do
    case lock_poll(publication_ref, lease_ref) do
      {:ok, followup, _publication, now} ->
        Store.update_followup!(
          followup,
          %{
            failure_count: followup.failure_count + 1,
            last_error: bounded_error(reason),
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_poll_at: DateTime.add(now, delay_seconds, :second)
          },
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp defer_delivery_locked(event_ref, lease_ref, delay_seconds, reason) do
    now = Repo.now!()

    case Store.lock_lifecycle_event(event_ref) do
      %LifecycleEvent{} = event ->
        defer_locked_event(event, lease_ref, delay_seconds, reason, now)

      nil ->
        Repo.rollback(:publication_lifecycle_event_not_found)
    end
  end

  defp defer_locked_event(event, lease_ref, delay_seconds, reason, now) do
    case live_event_lease(event, lease_ref, now) do
      :ok ->
        Store.update_event!(
          event,
          %{
            last_error: bounded_error(reason),
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

  defp bounded_error(reason) do
    value = inspect(reason, limit: 20, printable_limit: 3_500, width: 120)
    if byte_size(value) <= 4_096, do: value, else: String.byte_slice(value, 0, 4_093) <> "..."
  end
end
