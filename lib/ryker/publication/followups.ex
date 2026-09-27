defmodule Ryker.Publication.Followups do
  @moduledoc """
  Episode-owned custody for a published pull request's remaining lifecycle.

  GitHub webhooks nudge one authoritative refresh; idle repositories are never
  scanned on a timer. External deployment signals must contain an exact recorded
  PR URL, branch, head SHA, or merge SHA before they can wake the source task.

  This module is the follow-up API for the rest of the host, and the custody
  the follow-up dispatcher and executor run against: publication custody, the
  GitHub router, ingress projections, Slack and the control plane call it and
  nothing deeper. The work is split by stage:

    * What starts a follow-up: `Followups.Start` arms one when a publication
      goes out, rearms it after recovery, and makes the next poll due when a
      person asks for a check or a GitHub webhook names its pull request.
    * What runs it: `Followups.Leases` claims, renews and defers the worker's
      polls and deliveries, and `Followups.Delivery` admits a lifecycle
      event's wakeup, builds its message and confirms the receipt.
    * What records its outcome: `Followups.Polls` turns a poll into the
      lifecycle event it means and settles verifications, and
      `Followups.Signals` records deployment signals and review feedback.

  `Followups.Store` holds the follow-up and lifecycle-event rows they share.
  """

  alias Ryker.Ingress.Input
  alias Ryker.Publication.Followups.{Delivery, Leases, Polls, Signals, Start}
  alias Ryker.Publication.LifecycleEvent

  # --- what starts a follow-up ----------------------------------------------

  @doc false
  defdelegate ensure_published_in_transaction(publication, now), to: Start

  @doc false
  defdelegate rearm_stale_in_transaction(publication, now), to: Start

  @doc false
  defdelegate rearm_conflict_in_transaction(publication, now), to: Start

  @doc "Makes the next poll of a publication due now, once per check request."
  defdelegate request_check(publication_ref, request_ref), to: Start

  @doc """
  Makes an open publication's next poll due now when a GitHub event names its
  pull request, unless the event names a different head.
  """
  defdelegate nudge_github_event(repository, event_name, delivery_ref, payload), to: Start

  # --- what runs it ---------------------------------------------------------

  @doc "Claims the next published pull request due for a poll, under a lease."
  defdelegate claim_poll(worker_ref, lease_seconds), to: Leases

  @doc """
  The earliest moment after `since` at which a follow-up poll or a lifecycle
  notice becomes claimable by the clock alone: a poll's interval or a retry's
  backoff ends, or the lease of a claim nobody renewed runs out. Nil when
  nothing waits on the clock.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  defdelegate next_due_at(since), to: Leases

  @doc "Claims the next lifecycle event waiting for delivery, under a lease."
  defdelegate claim_delivery(worker_ref, lease_seconds), to: Leases

  @doc "Extends the lease of a poll still in progress."
  defdelegate renew_poll(publication_ref, lease_ref, lease_seconds), to: Leases

  @doc "Extends the lease of a delivery still in progress."
  defdelegate renew_delivery(event_ref, lease_ref, lease_seconds), to: Leases

  @doc "Hands a failed poll back, due again after `delay_seconds`."
  defdelegate defer_poll(publication_ref, lease_ref, delay_seconds, reason), to: Leases

  @doc "Hands a failed delivery back, due again after `delay_seconds`."
  defdelegate defer_delivery(event_ref, lease_ref, delay_seconds, reason), to: Leases

  @doc "Admits a leased lifecycle event's wakeup into its source task, once."
  defdelegate admit_wakeup(event_ref, lease_ref), to: Delivery

  @doc "The message a pending lifecycle event posts in its publication's conversation."
  defdelegate delivery_request(event), to: Delivery

  @doc "Records a lifecycle event's delivery receipt; a repeated receipt must match the first."
  defdelegate confirm_delivery(event_ref, lease_ref, receipt), to: Delivery

  # --- what records its outcome ---------------------------------------------

  @doc "Stores what a leased poll found and records the lifecycle event it means."
  defdelegate store_poll(publication_ref, lease_ref, status), to: Polls

  @doc "Settles a pending verification, or checks it again after `interval_seconds`."
  defdelegate reconcile_verification(publication_ref, lease_ref, interval_seconds), to: Polls

  @doc """
  Records authenticated human feedback against the exact open published pull request.

  The GitHub adapter has already proved actor and repository authority. This
  boundary owns only publication identity: matching feedback is continued in
  the source engineering episode, while unmatched GitHub conversation remains
  eligible for ordinary admission.
  """
  @spec observe_github_feedback(Input.t()) ::
          {:ok, :unmatched | %{event: LifecycleEvent.t(), status: :recorded | :duplicate}}
          | {:error, term()}
  defdelegate observe_github_feedback(input), to: Signals

  @doc "Records a trusted deployment or Terraform signal against each merged publication named."
  @spec observe_input(Input.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate observe_input(input), to: Signals
end
