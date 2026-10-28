defmodule Ryker.WeeklyReport.ReviewCustody do
  @moduledoc "One frozen weekly review, leased and resumed without replacement model calls."
  @behaviour Ryker.Coop.RunStep.Store
  alias Ryker.{CanonicalJSON, Coop, Crypto, Lease, Reference, Repo, RoutingExamples, WeeklyReport}
  alias Ryker.CoopFleet
  alias Ryker.WeeklyReport.{Report, Review, ReviewEvidence, ReviewFleetSession, ReviewPrompt}
  alias Ryker.WeeklyReport.ReviewTransport
  alias Ryker.Work

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)

  @doc "Creates the interval's only review, or returns the frozen row already present."
  def prepare(period, settings) do
    identity =
      CanonicalJSON.digest(%{
        "from" => DateTime.to_iso8601(period.week.from),
        "until" => DateTime.to_iso8601(period.week.to),
        "destination" => period.conversation_ref,
        "timezone" => period.week.timezone,
        "saved_at" => period.saved_at && DateTime.to_iso8601(period.saved_at)
      })

    case Repo.fetch(Review.Query.by_identity(identity)) do
      {:ok, review} -> {:ok, review}
      {:error, :not_found} -> prepare_new(period, settings, identity)
    end
  end

  defp prepare_new(period, settings, identity) do
    Repo.transaction(fn ->
      # Copying and forgetting share the same lock; no prompt can reappear after erasure.
      :ok = RoutingExamples.copy_lock_in_transaction()
      evidence = ReviewEvidence.gather(period.week, period.conversation_ref)

      manifest = %{
        "from" => DateTime.to_iso8601(period.week.from),
        "until" => DateTime.to_iso8601(period.week.to),
        "coverage" => "Retained public conversation evidence; no new live health scan.",
        "evidence" => evidence.items,
        "omitted" => evidence.omitted,
        "more_available" => evidence.more_available
      }

      prompt = ReviewPrompt.render(manifest)

      attributes = %{
        identity: identity,
        conversation_ref: period.conversation_ref,
        settings_saved_at: period.saved_at,
        period_start: period.week.from,
        period_end: period.week.to,
        timezone: period.week.timezone,
        deadline_at: period.deadline_at,
        policy: settings.policy,
        policy_digest: settings.policy_digest,
        prompt: prompt,
        prompt_sha256: Crypto.sha256_hex(prompt),
        output_schema: ReviewPrompt.output_schema(),
        manifest: manifest,
        source_turn_ids: evidence.turn_ids,
        source_identities: evidence.identities,
        message_keys: evidence.keys,
        source_conversation_refs: evidence.conversations
      }

      attributes |> Review.Changeset.insert() |> Repo.insert!(on_conflict: :nothing)
      Repo.fetch!(Review.Query.by_identity(identity))
    end)
  end

  @doc "Reads a saved review for this exact period and destination; never schedules one."
  def fetch_for_report(week, destination) do
    week.from
    |> Review.Query.by_period(week.to, destination)
    |> Review.Query.ordered_by_recent()
    |> Review.Query.limit_to(1)
    |> Repo.fetch()
  end

  @doc "Erases copied evidence and derived reports under the caller's exclusive forgetting lock."
  def forget_in_transaction(identities, keys) do
    identities |> Review.Query.from_sources_or_messages(keys) |> erase()
  end

  @doc "Revokes reviews that quoted a conversation which was deleted or ceased to be public."
  def forget_conversation_in_transaction(conversation) do
    :ok = RoutingExamples.exclusive_copy_lock_in_transaction()
    conversation |> Review.Query.by_source_conversation() |> erase()
  end

  defp erase(query) do
    now = Repo.now!()
    query = query |> Review.Query.kept() |> Review.Query.select_ids()

    {_count, ids} =
      Repo.update_all(query,
        set: [
          prompt: nil,
          result: nil,
          manifest: nil,
          recommendations: [],
          forgotten_at: now,
          updated_at: now
        ]
      )

    if ids != [] do
      :ok = revoke_transport_in_transaction(ids)

      # This is explicit deletion, not regeneration from later facts. Already delivered
      # history retains its receipt and a visible redaction; retries cannot post old words.
      document = %{
        "message" =>
          "This weekly report's content was removed because source evidence was forgotten or is no longer public."
      }

      Repo.update_all(Report.Query.by_review_ids(ids),
        set: [document: document, review_redacted_at: now, updated_at: now]
      )
    end

    :ok
  end

  @doc "Fences unsent prompts and scrubs stopped copies for both forgetting and retention."
  def revoke_transport_in_transaction(ids) do
    sessions = ids |> Work.Session.Query.by_weekly_review_ids() |> Repo.all()

    :ok =
      CoopFleet.ControlPlane.Commands.revoke_unsubmitted_in_transaction(
        Enum.map(sessions, & &1.id)
      )

    ReviewTransport.scrub_in_transaction(ids)
  end

  @doc "Checks a queued submission at the actual worker delivery boundary."
  def submission_allowed?(session_id) do
    case Repo.fetch(Work.Session.Query.by_id(session_id)) do
      {:ok, %Work.Session{weekly_review_id: nil}} ->
        true

      {:ok, %Work.Session{weekly_review_id: id}} ->
        review = current(id)

        review.status == :prepared and body_available?(review) and
          DateTime.before?(Repo.now!(), review.deadline_at) and
          WeeklyReport.review_current?(review) and
          ReviewEvidence.publishable?(review.manifest, review.conversation_ref)

      _missing ->
        false
    end
  end

  @doc "Rechecks the persisted review before publication, including a source audience change."
  def delivery_allowed?(nil), do: true

  def delivery_allowed?(id) do
    case Repo.fetch(Review.Query.by_id(id) |> Review.Query.lock_for_share()) do
      {:ok, %Review{forgotten_at: nil, pruned_at: nil, status: :applied} = review} ->
        ReviewEvidence.publishable?(review.manifest, review.conversation_ref)

      _missing_or_revoked ->
        false
    end
  end

  @doc "Claims the next outstanding review, including reconciliation after reporting is disabled."
  def claim(owner, seconds) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case Repo.fetch(Review.Query.next_claimable(now)) do
        {:error, :not_found} ->
          :idle

        {:ok, review} ->
          lease_ref = Repo.generate_id()

          review =
            review
            |> Review.Changeset.claim(owner, lease_ref, DateTime.add(now, seconds))
            |> Repo.update!()

          %{review: review, lease_ref: lease_ref}
      end
    end)
  end

  @impl true
  def current(id), do: Repo.fetch!(Review.Query.by_id(id))

  @doc "Reads and pins the review body until a copying transaction ends."
  def current_for_copy(id),
    do: id |> Review.Query.by_id() |> Review.Query.lock_for_share() |> Repo.fetch!()

  @doc "Serializes a fresh read and its copying effect with explicit evidence revocation."
  def with_evidence(callback) do
    case Repo.transaction(fn ->
           :ok = RoutingExamples.copy_lock_in_transaction()
           callback.()
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Checks the saved prompt again while holding the forgetting fence through submission."
  def with_submission(review, settings, callback) do
    with_evidence(fn ->
      current =
        review.id |> Review.Query.by_id() |> Review.Query.lock_for_share() |> Repo.fetch!()

      if settings.enabled and WeeklyReport.review_current?(current) and
           current.status == :prepared and body_available?(current) and
           DateTime.before?(Repo.now!(), current.deadline_at) and
           current.prompt_sha256 == review.prompt_sha256 and
           ReviewEvidence.publishable?(current.manifest, current.conversation_ref),
         do: callback.(),
         else: {:error, :weekly_review_source_revoked}
    end)
  end

  @impl true
  def renew(claim, seconds) do
    mutate(claim, claim.review.id, fn review ->
      expires = Lease.renewed(review.lease_expires_at, Repo.now!(), seconds)
      review |> Review.Changeset.renew(expires) |> Repo.update!()
    end)
  end

  @impl true
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _review = owned!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def fetch_and_lock_owned_in_transaction!(claim), do: owned!(claim)

  @doc "Releases the lease; an unknown remote outcome stays on this same review."
  def release(claim, delay) do
    mutate(claim, claim.review.id, fn review ->
      review |> Review.Changeset.release(DateTime.add(Repo.now!(), delay)) |> Repo.update!()
    end)
  end

  @doc "Freezes the single start before any remote operation can be sent."
  def begin_execution(claim) do
    mutate(claim, claim.review.id, fn review ->
      cond do
        not is_nil(review.started_at) ->
          review

        review.status != :prepared or is_nil(review.prompt) ->
          Repo.rollback(:weekly_review_unavailable)

        DateTime.compare(Repo.now!(), review.deadline_at) != :lt ->
          Repo.rollback(:weekly_review_deadline)

        true ->
          review |> Review.Changeset.begin(Repo.now!()) |> Repo.update!()
      end
    end)
  end

  @doc "Ends a review that never made a remote request, without consuming a model call."
  def skip_unstarted(claim, reason) do
    mutate(claim, claim.review.id, fn review ->
      unless is_nil(review.started_at), do: Repo.rollback(:weekly_review_remote_unresolved)
      review = review |> Review.Changeset.end_attempt(reason) |> Repo.update!()
      store_stop(review, %{"kind" => "never_started"})
    end)
  end

  @doc "Counts failed reconciliation reads without starting a new turn."
  def reconciliation_failed(claim) do
    mutate(claim, claim.review.id, fn review ->
      review |> Review.Changeset.reconciliation_failed() |> Repo.update!()
    end)
  end

  @impl true
  def operation_key(%Review{id: id}, phase) when phase in [:create, :submit, :cancel],
    do: "ryker:weekly-review:#{phase}:#{id}"

  @impl true
  def freeze_submit(claim, id, revision) when is_integer(revision) and revision > 0 do
    mutate(claim, id, fn review ->
      cond do
        review.submit_revision == revision ->
          review

        not is_nil(review.submit_revision) ->
          Repo.rollback(:weekly_review_submission_conflict)

        review.status != :prepared or is_nil(review.prompt) or is_nil(review.started_at) or
            not is_nil(review.remote_stopped_at) ->
          Repo.rollback(:weekly_review_attempt_not_running)

        true ->
          review |> Review.Changeset.freeze_submit(revision) |> Repo.update!()
      end
    end)
  end

  @impl true
  def bind_turn(claim, id, session_id, turn_id) do
    mutate(claim, id, fn review ->
      unless owned_session?(review, session_id) and Reference.valid?(turn_id, 1024),
        do: Repo.rollback(:weekly_review_remote_identity_conflict)

      case review.coop_turn_id do
        nil -> review |> Review.Changeset.bind_turn(turn_id) |> Repo.update!()
        ^turn_id -> review
        _different -> Repo.rollback(:weekly_review_remote_identity_conflict)
      end
    end)
  end

  @impl true
  def record_candidate(claim, id, turn, producer) do
    with {:ok, message, digest, attempt} <- Coop.Documents.candidate(turn["candidate"]),
         true <- byte_size(message) <= 16_384,
         :ok <- CanonicalJSON.validate(producer, max_bytes: 4096) do
      mutate(claim, id, &keep_candidate(&1, turn, message, digest, attempt, producer))
    else
      _invalid -> {:error, :invalid_weekly_review_result}
    end
  end

  defp keep_candidate(review, turn, message, digest, attempt, producer) do
    require_body!(review)
    require_turn!(review, turn)

    cond do
      review.result == message and review.candidate_attempt == attempt ->
        review

      review.status in [:prepared, :responded] ->
        review |> Review.Changeset.candidate(message, digest, attempt, producer) |> Repo.update!()

      true ->
        Repo.rollback(:weekly_review_attempt_finished)
    end
  end

  @impl true
  def confirm_candidate(claim, id, turn) do
    mutate(claim, id, fn review ->
      require_turn!(review, turn)
      require_accepted!(review, turn)

      receipt =
        Map.take(
          turn,
          ~w(id session_id validation_attempt validation_candidate_sha256 validation_receipt)
        )

      cond do
        review.validation_receipt == receipt -> review
        not is_nil(review.validation_receipt) -> Repo.rollback(:weekly_review_validation_conflict)
        true -> review |> Review.Changeset.confirm(receipt) |> Repo.update!()
      end
    end)
  end

  @impl true
  def apply_result(claim, id, turn) do
    mutate(claim, id, fn review ->
      require_body!(review)
      require_turn!(review, turn)
      require_accepted!(review, turn)

      unless is_map(review.validation_receipt),
        do: Repo.rollback(:weekly_review_validation_unconfirmed)

      case ReviewPrompt.parse(review.result, review.manifest) do
        {:ok, recommendations} ->
          receipt = Coop.Documents.terminal_receipt(turn)
          review = store_stop(review, receipt)
          review |> Review.Changeset.apply_result(recommendations) |> Repo.update!()

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def end_attempt(claim, id, reason) do
    mutate(claim, id, fn review ->
      if review.status in [:prepared, :responded] do
        saved = review |> Review.Changeset.end_attempt(reason) |> Repo.update!()
        :ok = revoke_transport_in_transaction([review.id])
        saved
      else
        review
      end
    end)
  end

  @impl true
  def record_stop(claim, id, %{"state" => state} = turn) when state in @terminal do
    mutate(claim, id, fn review ->
      require_turn!(review, turn)
      store_stop(review, Coop.Documents.terminal_receipt(turn))
    end)
  end

  def record_stop(_claim, _id, _turn), do: {:error, :weekly_review_remote_not_stopped}

  @impl true
  def fail(claim, id, reason, %{"state" => state} = turn) when state in @terminal do
    mutate(claim, id, fn review ->
      require_turn!(review, turn)
      review = review |> Review.Changeset.end_attempt(reason) |> Repo.update!()
      store_stop(review, Coop.Documents.failure_receipt(turn))
    end)
  end

  @impl true
  def record_unsubmitted_stop(claim, id, session_id) do
    mutate(claim, id, fn review ->
      unless review.status in [:stale, :rejected] and is_nil(review.coop_turn_id) and
               owned_session?(review, session_id),
             do: Repo.rollback(:weekly_review_absence_unconfirmed)

      store_stop(review, %{
        "kind" => "never_submitted",
        "session_id" => session_id,
        "submit_revision" => review.submit_revision
      })
    end)
  end

  @impl true
  def record_unaddressable_stop(claim, id, reason) do
    mutate(claim, id, fn review ->
      unless review.status in [:stale, :rejected] and is_nil(review.submit_revision) and
               is_nil(review.coop_turn_id),
             do: Repo.rollback(:weekly_review_absence_unconfirmed)

      store_stop(review, %{
        "kind" => "never_submitted",
        "reason" => reason,
        "session" => "unaddressable",
        "session_id" => ReviewFleetSession.coop_session_id(review)
      })
    end)
  end

  @impl true
  def record_uncreated_stop(claim, id) do
    mutate(claim, id, fn review ->
      unless review.status in [:stale, :rejected] and is_nil(review.coop_turn_id) and
               is_nil(ReviewFleetSession.coop_session_id(review)),
             do: Repo.rollback(:weekly_review_absence_unconfirmed)

      store_stop(review, %{"kind" => "never_created"})
    end)
  end

  @impl true
  def record_failed_operation(
        claim,
        id,
        phase,
        %{"state" => "failed", "id" => operation_id} = operation
      )
      when phase in [:create, :submit] do
    mutate(claim, id, fn review ->
      method = if phase == :create, do: "CreateRemoteSession", else: "SubmitTurn"

      unless is_nil(review.coop_turn_id) and operation["method"] == method and
               Reference.valid?(operation_id, 1024) and is_nil(operation["resource_id"]),
             do: Repo.rollback(:weekly_review_absence_unconfirmed)

      review =
        review |> Review.Changeset.end_attempt(:weekly_review_provider_failed) |> Repo.update!()

      store_stop(review, %{
        "kind" => "failed_operation",
        "phase" => Atom.to_string(phase),
        "operation_id" => operation_id,
        "method" => method,
        "session_id" => ReviewFleetSession.coop_session_id(review)
      })
    end)
  end

  @impl true
  def record_expired_stop(claim, id, seconds) do
    mutate(claim, id, fn review ->
      unless not is_nil(review.started_at) and
               DateTime.diff(Repo.now!(), review.started_at) >= seconds,
             do: Repo.rollback(:weekly_review_remote_unresolved)

      review =
        review |> Review.Changeset.end_attempt(:weekly_review_attempt_expired) |> Repo.update!()

      store_stop(review, %{
        "kind" => "attempt_expired",
        "closed_after_seconds" => seconds,
        "session_id" => ReviewFleetSession.coop_session_id(review),
        "turn_id" => review.coop_turn_id
      })
    end)
  end

  defp body_available?(review),
    do: is_nil(review.forgotten_at) and is_nil(review.pruned_at) and is_binary(review.prompt)

  defp require_body!(review) do
    unless body_available?(review), do: Repo.rollback(:weekly_review_forgotten)
  end

  defp require_turn!(review, turn) do
    unless Coop.Documents.exact_turn?(
             turn,
             ReviewFleetSession.coop_session_id(review),
             review.coop_turn_id
           ) and
             not is_nil(review.coop_turn_id),
           do: Repo.rollback(:weekly_review_remote_identity_conflict)
  end

  defp require_accepted!(review, turn) do
    unless turn["state"] == "completed" and is_binary(review.result) and
             turn["assistant_message"] == review.result and
             turn["validation_attempt"] == review.candidate_attempt and
             turn["validation_candidate_sha256"] == review.result_sha256 and
             Reference.valid?(turn["validation_receipt"], 1024),
           do: Repo.rollback(:weekly_review_validation_unconfirmed)
  end

  defp store_stop(review, receipt) do
    receipt = Map.reject(receipt, fn {_key, value} -> is_nil(value) end)

    unless CanonicalJSON.validate(receipt, max_bytes: 4096) == :ok,
      do: Repo.rollback(:weekly_review_stop_receipt_invalid)

    cond do
      review.stop_receipt == receipt ->
        review

      not is_nil(review.stop_receipt) ->
        Repo.rollback(:weekly_review_stop_conflict)

      true ->
        saved = review |> Review.Changeset.stop(receipt, Repo.now!()) |> Repo.update!()
        :ok = ReviewTransport.scrub_in_transaction([review.id])
        saved
    end
  end

  defp owned_session?(review, id),
    do: Reference.valid?(id, 1024) and ReviewFleetSession.coop_session_id(review) == id

  defp mutate(claim, id, callback) do
    Repo.transaction(fn ->
      review = owned!(claim)
      unless review.id == id, do: Repo.rollback(:weekly_review_identity_conflict)
      callback.(review)
    end)
  end

  defp owned!(claim) do
    review =
      claim.review.id |> Review.Query.by_id() |> Review.Query.lock_for_update() |> Repo.peek()

    unless review && Lease.held?(review, claim.lease_ref, Repo.now!()),
      do: Repo.rollback(:weekly_review_lease_lost)

    review
  end
end
