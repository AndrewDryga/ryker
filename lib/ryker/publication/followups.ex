defmodule Ryker.Publication.Followups do
  @moduledoc """
  Episode-owned custody for a published pull request's remaining lifecycle.

  GitHub webhooks nudge one authoritative refresh; idle repositories are never
  scanned on a timer. External deployment signals must contain an exact recorded
  PR URL, branch, head SHA, or merge SHA before they can wake the source task.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.Request
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Event}
  alias Ryker.Ingress.Input

  alias Ryker.Publication.{
    DeploymentSignal,
    Followup,
    FollowupChangeset,
    LifecycleEvent,
    LifecycleEventChangeset,
    LifecycleStatus,
    Publication
  }

  alias Ryker.Publication.Changeset, as: PublicationChangeset
  alias Ryker.Repo
  alias Ryker.State.Observations
  alias Ryker.Work.{Custody, DeliveryReceipt}

  @default_deadline_seconds 30 * 24 * 60 * 60
  @far_future ~U[9999-01-01 00:00:00.000000Z]

  @doc false
  def ensure_published_in_transaction(%Publication{status: :published} = publication, now) do
    attributes = %{
      deadline_at: DateTime.add(now, @default_deadline_seconds, :second),
      episode_id: publication.episode_id,
      id: Ecto.UUID.generate(),
      last_event_key: "baseline",
      next_poll_at: now,
      publication_id: publication.id
    }

    case Repo.one(from(followup in Followup, where: followup.publication_id == ^publication.id)) do
      %Followup{pr_state: "stale"} = followup ->
        reset_followup!(followup, publication, now)

      %Followup{} = followup ->
        followup

      nil ->
        case Repo.insert(FollowupChangeset.insert(attributes)) do
          {:ok, %Followup{} = followup} ->
            followup

          {:error, changeset} ->
            Repo.rollback({:publication_followup_persistence_failed, changeset.errors})
        end
    end
  end

  def ensure_published_in_transaction(_publication, _now),
    do: Repo.rollback(:publication_not_delivered)

  @doc false
  def rearm_stale_in_transaction(%Publication{} = publication, now) do
    case Repo.one(
           from(followup in Followup,
             where: followup.publication_id == ^publication.id,
             lock: "FOR UPDATE"
           )
         ) do
      %Followup{pr_state: "stale"} = followup ->
        _followup = reset_followup!(followup, publication, now)
        :ok

      %Followup{} ->
        {:error, :publication_recovery_not_stale}

      nil ->
        {:error, :publication_followup_not_found}
    end
  end

  @doc false
  def rearm_conflict_in_transaction(%Publication{} = publication, now) do
    case Repo.one(
           from(followup in Followup,
             where: followup.publication_id == ^publication.id,
             lock: "FOR UPDATE"
           )
         ) do
      %Followup{} = followup ->
        _followup = reset_followup!(followup, publication, now)
        :ok

      nil when is_nil(publication.publication_receipt) ->
        :ok

      nil ->
        {:error, :publication_followup_not_found}
    end
  end

  def claim_poll(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_poll_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def claim_delivery(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_delivery_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def request_check(publication_ref, request_ref) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(request_ref, :request_ref) do
      Repo.transaction(fn -> request_check_locked(publication_ref, request_ref) end)
      |> transaction_result()
    end
  end

  def nudge_github_event(repository, event_name, delivery_ref, payload)
      when is_binary(repository) and is_binary(event_name) and is_binary(delivery_ref) and
             is_map(payload) do
    with true <- event_name in ~w(check_run check_suite pull_request status workflow_run),
         {:ok, number, head_sha} <- github_event_identity(event_name, payload) do
      Repo.transaction(fn -> nudge_github_locked(repository, number, head_sha) end)
      |> transaction_result()
    else
      false -> {:ok, :ignored}
      {:error, _reason} -> {:ok, :ignored}
    end
  end

  def nudge_github_event(_repository, _event_name, _delivery_ref, _payload), do: {:ok, :ignored}

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
  def observe_github_feedback(%Input{} = input) do
    case github_feedback_identity(input) do
      {:ok, repository, pull_request_number} ->
        Repo.transaction(fn ->
          observe_github_feedback_locked(input, repository, pull_request_number)
        end)
        |> transaction_result()

      :unmatched ->
        {:ok, :unmatched}

      {:error, _reason} = error ->
        error
    end
  end

  def observe_github_feedback(_input),
    do: {:error, {:invalid_publication_review_feedback, :input}}

  @spec observe_input(Input.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe_input(
        %Input{
          actor: %{kind: :system},
          source: %{kind: "webhook"},
          source_capabilities: %{"publication_lifecycle" => authority}
        } = input
      ) do
    with {:ok, signal} <- DeploymentSignal.prepare(input.content),
         :ok <- DeploymentSignal.authorize(signal, authority) do
      Repo.transaction(fn -> observe_input_locked(input, signal) end)
      |> transaction_result()
    else
      _untrusted_or_untyped -> {:ok, 0}
    end
  end

  def observe_input(%Input{}), do: {:ok, 0}
  def observe_input(_input), do: {:error, {:invalid_publication_lifecycle_input, :input}}

  def store_poll(publication_ref, lease_ref, status, interval_seconds) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(interval_seconds, :interval_seconds),
         {:ok, status} <- LifecycleStatus.prepare(status) do
      Repo.transaction(fn ->
        store_poll_locked(publication_ref, lease_ref, status, interval_seconds)
      end)
      |> transaction_result()
    end
  end

  def defer_poll(publication_ref, lease_ref, delay_seconds, reason) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(delay_seconds, :delay_seconds) do
      Repo.transaction(fn ->
        defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason)
      end)
      |> transaction_result()
    end
  end

  def reconcile_verification(publication_ref, lease_ref, interval_seconds) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(interval_seconds, :interval_seconds) do
      Repo.transaction(fn ->
        reconcile_verification_locked(publication_ref, lease_ref, interval_seconds)
      end)
      |> transaction_result()
    end
  end

  def renew_poll(publication_ref, lease_ref, lease_seconds) do
    renew_followup(publication_ref, lease_ref, lease_seconds)
  end

  def renew_delivery(event_ref, lease_ref, lease_seconds) do
    with :ok <- reference(event_ref, :event_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_delivery_locked(event_ref, lease_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def admit_wakeup(event_ref, lease_ref) do
    with :ok <- reference(event_ref, :event_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn -> admit_wakeup_locked(event_ref, lease_ref) end)
      |> transaction_result()
    end
  end

  def delivery_request(%LifecycleEvent{delivery_state: :pending} = event) do
    case Repo.get(Publication, event.publication_id) do
      %Publication{} = publication -> publication_delivery_request(publication, event)
      nil -> {:error, :publication_not_found}
    end
  end

  def delivery_request(_event), do: {:error, :publication_lifecycle_delivery_not_pending}

  def confirm_delivery(event_ref, lease_ref, receipt) do
    with :ok <- reference(event_ref, :event_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(receipt) do
      Repo.transaction(fn -> confirm_delivery_locked(event_ref, lease_ref, receipt) end)
      |> transaction_result()
    end
  end

  def defer_delivery(event_ref, lease_ref, delay_seconds, reason) do
    with :ok <- reference(event_ref, :event_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(delay_seconds, :delay_seconds) do
      Repo.transaction(fn ->
        defer_delivery_locked(event_ref, lease_ref, delay_seconds, reason)
      end)
      |> transaction_result()
    end
  end

  defp request_check_locked(publication_ref, request_ref) do
    now = database_now!()

    case lock_followup_by_publication_ref(publication_ref) do
      nil ->
        Repo.rollback(:publication_followup_not_found)

      %Followup{manual_check_ref: ^request_ref} = followup ->
        %{followup: followup, status: :duplicate}

      %Followup{} = followup ->
        updated =
          update_followup!(followup, %{manual_check_ref: request_ref, next_poll_at: now}, now)

        %{followup: updated, status: :requested}
    end
  end

  defp defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason) do
    case lock_poll(publication_ref, lease_ref) do
      {:ok, followup, _publication, now} ->
        update_followup!(
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

  defp reconcile_verification_locked(publication_ref, lease_ref, interval_seconds) do
    with {:ok, followup, _publication, now} <- lock_poll(publication_ref, lease_ref),
         true <- verification_pending?(followup) do
      verified = verification_recorded?(followup)

      update_followup!(
        followup,
        verification_attributes(verified, now, interval_seconds),
        now
      )
    else
      false -> Repo.rollback(:publication_verification_not_pending)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verification_pending?(followup) do
    is_binary(followup.verification_event_ref) and is_integer(followup.verification_sequence)
  end

  defp verification_recorded?(followup) do
    Repo.exists?(
      from(event in Event,
        where:
          event.episode_id == ^followup.episode_id and
            event.sequence > ^followup.verification_sequence and event.kind == :result_accepted and
            fragment(
              "(?::jsonb ->> 'expected_turn_ref') = ?",
              event.payload,
              ^followup.verification_turn_ref
            )
      )
    )
  end

  defp verification_attributes(verified, now, interval_seconds) do
    %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_poll_at:
        if(verified, do: @far_future, else: DateTime.add(now, interval_seconds, :second)),
      verified_at: if(verified, do: now, else: nil)
    }
  end

  defp renew_delivery_locked(event_ref, lease_ref, lease_seconds) do
    now = database_now!()

    case lock_lifecycle_event(event_ref) do
      %LifecycleEvent{} = event ->
        renew_locked_event(event, lease_ref, lease_seconds, now)

      nil ->
        Repo.rollback(:publication_lifecycle_event_not_found)
    end
  end

  defp renew_locked_event(event, lease_ref, lease_seconds, now) do
    case live_event_lease(event, lease_ref, now) do
      :ok ->
        update_event!(
          event,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp publication_delivery_request(publication, event) do
    Request.new(%{
      conversation_ref: publication.destination_conversation_ref,
      document: %{"message" => event.summary},
      kind: :message,
      ref: event.delivery_ref,
      source_item_ref: nil,
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    })
  end

  defp defer_delivery_locked(event_ref, lease_ref, delay_seconds, reason) do
    now = database_now!()

    case lock_lifecycle_event(event_ref) do
      %LifecycleEvent{} = event ->
        defer_locked_event(event, lease_ref, delay_seconds, reason, now)

      nil ->
        Repo.rollback(:publication_lifecycle_event_not_found)
    end
  end

  defp defer_locked_event(event, lease_ref, delay_seconds, reason, now) do
    case live_event_lease(event, lease_ref, now) do
      :ok ->
        update_event!(
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

  defp claim_poll_locked(worker_ref, lease_seconds) do
    now = database_now!()

    query =
      from(followup in Followup,
        join: publication in Publication,
        on:
          publication.id == followup.publication_id and
            publication.episode_id == followup.episode_id,
        where:
          publication.status == :published and
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
          update_followup!(
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
    now = database_now!()

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
          update_event!(
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

  defp store_poll_locked(publication_ref, lease_ref, status, interval_seconds) do
    with {:ok, followup, publication, now} <- lock_poll(publication_ref, lease_ref),
         :ok <- exact_status(publication, status) do
      cond do
        DateTime.compare(now, followup.deadline_at) != :lt and followup.pr_state == "open" ->
          transition_poll(
            followup,
            publication,
            status,
            %{
              checks_state: status["checks_state"],
              checks_total: status["checks_total"],
              checks_passed: status["checks_passed"],
              checks_failed: status["checks_failed"],
              checks_url: status["checks_url"],
              pr_state: "expired"
            },
            {"deadline", "failed", "Automatic pull-request tracking reached its hard deadline."},
            @far_future,
            now
          )

        status["head_sha"] != publication.commit_sha and not status["merged"] ->
          _publication = mark_stale_publication!(publication, status["head_sha"], now)

          transition_poll(
            followup,
            publication,
            status,
            %{pr_state: "stale"},
            {"status", "failed",
             "The pull-request head changed outside this exact reviewed publication. Automatic tracking stopped until a new exact candidate is reviewed."},
            @far_future,
            now
          )

        true ->
          poll_transition(followup, publication, status, interval_seconds, now)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp poll_transition(followup, publication, status, _interval_seconds, now) do
    pr_state =
      cond do
        status["merged"] -> "merged"
        status["state"] == "closed" -> "closed"
        true -> "open"
      end

    attributes = %{
      checks_failed: status["checks_failed"],
      checks_passed: status["checks_passed"],
      checks_state: status["checks_state"],
      checks_total: status["checks_total"],
      checks_url: status["checks_url"],
      merge_sha: status["merge_sha"],
      merged_at: parse_optional_datetime!(status["merged_at"]),
      pr_state: pr_state
    }

    transition = transition(followup, publication, status, pr_state)

    transition_poll(followup, publication, status, attributes, transition, @far_future, now)
  end

  defp transition(followup, publication, _status, "merged") when followup.pr_state != "merged" do
    {"merged", "succeeded",
     "Draft PR ##{publication.pull_request_number} was merged. I’ll keep this task linked only to deployment or Terraform signals carrying its exact PR, branch, head SHA, or merge SHA."}
  end

  defp transition(followup, publication, _status, "closed") when followup.pr_state != "closed" do
    {"closed", "stopped",
     "Draft PR ##{publication.pull_request_number} was closed without merging. Automatic delivery tracking stopped."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "failing"}, _pr)
       when old != "failing" do
    {"checks", "failed",
     "GitHub checks are failing for PR ##{publication.pull_request_number}. Open the PR for the exact failures."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "passing"} = status, _pr)
       when old != "passing" do
    {"checks", "succeeded",
     "GitHub checks passed for PR ##{publication.pull_request_number} (#{status["checks_passed"]} of #{status["checks_total"]}). It is ready for human review or merge."}
  end

  defp transition(%{manual_check_ref: ref}, publication, status, pr_state) when is_binary(ref) do
    {"status", status_state(pr_state, status["checks_state"]),
     current_summary(publication, pr_state, status)}
  end

  defp transition(_followup, _publication, _status, _pr_state), do: nil

  # Failing checks on the exact reviewed head are the agent's own work to finish
  # inside the scope the task already granted, so they resume the episode. The
  # hard deadline, a head that moved outside this publication, a close and a
  # merge are not fixable there: they are facts a person owns, and they stay
  # history. The lifecycle key carries the head SHA, so one red run wakes the
  # task once however often it is polled.
  defp correction_wakeup?("checks", "failed"), do: true
  defp correction_wakeup?(_kind, _state), do: false

  defp transition_poll(followup, publication, status, attributes, transition, next_poll_at, now) do
    attributes =
      Map.merge(attributes, %{
        failure_count: 0,
        last_error: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        manual_check_ref: nil,
        next_poll_at: next_poll_at
      })

    {attributes, event} =
      case transition do
        {kind, state, summary} ->
          key =
            lifecycle_key([
              publication.id,
              kind,
              state,
              status["head_sha"],
              status["merge_sha"] || "",
              followup.manual_check_ref || ""
            ])

          event =
            lifecycle_event(publication, %{
              key: key,
              kind: kind,
              observation: status,
              occurred_at: now,
              source: nil,
              state: state,
              summary: summary,
              wakeup?: correction_wakeup?(kind, state)
            })

          {Map.put(attributes, :last_event_key, key), event}

        nil ->
          {attributes, nil}
      end

    updated = update_followup!(followup, attributes, now)
    if event, do: insert_lifecycle_event!(event)
    updated
  end

  defp observe_input_locked(input, signal) do
    now = database_now!()
    references = signal["payload"]["references"]
    repository = signal["payload"]["repository"]
    branch_references = Enum.map(references, &("refs/heads/" <> &1))

    active = matching_lifecycle_followups(repository, references, branch_references, now)

    Enum.reduce(active, 0, fn publication_pair, count ->
      observe_publication_input(publication_pair, input, signal, references, count)
    end)
  end

  defp matching_lifecycle_followups(repository, references, branch_references, now) do
    reference_match = lifecycle_reference_match(references, branch_references)

    Repo.all(
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where:
          publication.status == :published and publication.repository == ^repository and
            followup.pr_state == "merged" and followup.deadline_at > ^now and
            not is_nil(followup.merge_sha),
        where: ^reference_match,
        order_by: [asc: publication.id],
        select: {followup, publication}
      )
    )
  end

  defp lifecycle_reference_match(references, branch_references) do
    dynamic(
      [followup, publication],
      publication.pull_request_url in ^references or
        publication.branch_ref in ^references or
        publication.branch_ref in ^branch_references or
        publication.commit_sha in ^references or followup.merge_sha in ^references
    )
  end

  defp observe_github_feedback_locked(input, repository, pull_request_number) do
    matches = github_feedback_publications(repository, pull_request_number)

    case matches do
      [] ->
        :unmatched

      [%Publication{} = publication] ->
        {status, stored} = record_github_feedback(input, publication)

        case Observations.record_publication_feedback_in_transaction(stored, publication) do
          :ok -> %{event: stored, status: if(status == :ok, do: :recorded, else: :duplicate)}
          {:error, reason} -> Repo.rollback(reason)
        end

      [_first, _second] ->
        Repo.rollback(:publication_review_feedback_ambiguous)
    end
  end

  defp record_github_feedback(input, publication) do
    # The publication lock serializes equivalent deliveries. Preserve the first
    # receipt: another serialization must not create a competing wakeup for the
    # same native revision, nor replace the source receipt used by warm Work.
    # READ COMMITTED is required so the lookup after a lock wait sees the
    # preceding transaction's committed receipt.
    document = input |> Input.document() |> feedback_document()

    existing =
      Repo.all(
        from(event in LifecycleEvent,
          where:
            event.publication_id == ^publication.id and event.kind == "review_feedback" and
              event.occurred_at == ^input.occurred_at,
          order_by: [asc: event.inserted_at, asc: event.id]
        )
      )
      |> Enum.find(&(not is_nil(document) and feedback_document(&1.observation) == document))

    case existing do
      nil ->
        publication
        |> lifecycle_event(github_feedback_event(input, publication))
        |> insert_lifecycle_event()

      event ->
        {:duplicate, event}
    end
  end

  defp feedback_document(%{"content" => %{}, "event_ref" => ref} = document) do
    if reference(ref, :event_ref) == :ok do
      document
      |> Map.delete("event_ref")
      |> update_in(["content"], &Map.delete(&1, "delivery_ref"))
      |> CanonicalJSON.encode!()
    end
  end

  defp feedback_document(_document), do: nil

  defp github_feedback_publications(repository, pull_request_number) do
    Repo.all(
      from(publication in Publication,
        join: followup in Followup,
        on:
          followup.publication_id == publication.id and
            followup.episode_id == publication.episode_id,
        where:
          publication.status == :published and
            publication.github_repository == ^repository and
            publication.pull_request_number == ^pull_request_number and
            followup.pr_state == "open",
        order_by: [asc: publication.id],
        limit: 2,
        select: publication,
        lock: "FOR UPDATE"
      )
    )
  end

  defp github_feedback_event(input, publication) do
    key =
      lifecycle_key([
        publication.id,
        input.source.kind,
        input.source.ref,
        input.event_ref,
        Integer.to_string(input.revision),
        "review_feedback"
      ])

    %{
      key: key,
      kind: "review_feedback",
      observation: Input.document(input),
      occurred_at: input.occurred_at,
      source: %{
        conversation_ref: input.destination.conversation_ref,
        item_ref: input.source_item_ref || input.event_ref,
        transport: input.destination.transport
      },
      state: "pending",
      summary:
        "Authenticated GitHub review feedback arrived for PR ##{publication.pull_request_number}; continuing the exact engineering task.",
      wakeup?: true
    }
  end

  defp observe_publication_input(
         {followup, publication},
         input,
         signal,
         references,
         count
       ) do
    if exact_reference?(references, publication, followup) do
      event = lifecycle_event(publication, source_event(input, publication, signal))

      case insert_lifecycle_event(event) do
        {:ok, _event} -> count + 1
        {:duplicate, _event} -> count
      end
    else
      count
    end
  end

  defp source_event(input, publication, signal) do
    %{"kind" => kind, "state" => state} = signal["payload"]

    key =
      lifecycle_key([
        publication.id,
        input.source.kind,
        input.source.ref,
        input.event_ref,
        Integer.to_string(input.revision),
        kind,
        state
      ])

    %{
      key: key,
      kind: kind,
      observation: signal,
      occurred_at: input.occurred_at,
      source: %{
        conversation_ref: input.destination.conversation_ref,
        item_ref: input.source_item_ref || input.event_ref,
        transport: input.destination.transport
      },
      state: state,
      summary: source_summary(publication, kind, state),
      wakeup?: state in ~w(succeeded failed)
    }
  end

  defp admit_wakeup_locked(event_ref, lease_ref) do
    now = database_now!()

    with %LifecycleEvent{} = event <- lock_lifecycle_event(event_ref),
         :ok <- live_event_lease(event, lease_ref, now) do
      admit_wakeup_event(event, now)
    else
      nil -> Repo.rollback(:publication_lifecycle_event_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp admit_wakeup_event(%LifecycleEvent{wakeup_state: state} = event, _now)
       when state in [:none, :admitted],
       do: event

  defp admit_wakeup_event(%LifecycleEvent{wakeup_state: :pending} = event, now) do
    publication = Repo.get!(Publication, event.publication_id)
    episode = Repo.get!(Episode, event.episode_id)
    input = wakeup_input(publication, episode, event)
    command = admit_command(episode, input, event)

    case Episodes.apply_batch_in_transaction([command]) do
      {:ok, [transition]} ->
        case Custody.resume_blocked_in_transaction(
               transition.episode,
               transition.event.dedupe_key
             ) do
          {:ok, _episode} ->
            record_wakeup_admission(event, publication, command, transition, now)

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, :episode_cancelled} ->
        update_event!(event, %{wakeup_state: :admitted}, now)

      {:error, {:stale_input_revision, _details}} ->
        update_event!(event, %{wakeup_state: :admitted}, now)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_wakeup_admission(event, publication, command, transition, now) do
    updated_event = update_event!(event, %{wakeup_state: :admitted}, now)
    followup = lock_followup(publication.id)

    attributes =
      if event.kind == "review_feedback" do
        %{next_poll_at: DateTime.add(now, 60, :second)}
      else
        %{
          next_poll_at: DateTime.add(now, 60, :second),
          verification_event_ref: event.ref,
          verification_sequence: transition.event.sequence,
          verification_turn_ref: command.turn_ref
        }
      end

    update_followup!(followup, attributes, now)

    updated_event
  end

  defp confirm_delivery_locked(event_ref, lease_ref, receipt) do
    now = database_now!()

    case lock_lifecycle_event(event_ref) do
      nil ->
        Repo.rollback(:publication_lifecycle_event_not_found)

      %LifecycleEvent{delivery_state: :delivered} = event ->
        if event.delivery_receipt_fingerprint == DeliveryReceipt.fingerprint(receipt),
          do: event,
          else: Repo.rollback(:publication_lifecycle_delivery_conflict)

      %LifecycleEvent{} = event ->
        publication = Repo.get!(Publication, event.publication_id)

        with :ok <- live_event_lease(event, lease_ref, now),
             :ok <- exact_delivery_receipt(event, publication, receipt) do
          update_event!(
            event,
            %{
              delivery_receipt: receipt,
              delivery_receipt_fingerprint: DeliveryReceipt.fingerprint(receipt),
              delivery_state: :delivered,
              lease_expires_at: nil,
              lease_owner: nil,
              lease_ref: nil
            },
            now
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp renew_followup(publication_ref, lease_ref, lease_seconds) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_followup_locked(publication_ref, lease_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  defp renew_followup_locked(publication_ref, lease_ref, lease_seconds) do
    case lock_poll(publication_ref, lease_ref) do
      {:ok, followup, _publication, now} ->
        update_followup!(
          followup,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp lock_poll(publication_ref, lease_ref) do
    now = database_now!()

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

  defp exact_status(publication, status) do
    expected_branch = String.replace_prefix(publication.branch_ref || "", "refs/heads/", "")

    if status["number"] == publication.pull_request_number and
         status["url"] == publication.pull_request_url and status["head_ref"] == expected_branch,
       do: :ok,
       else: {:error, :publication_lifecycle_identity_mismatch}
  end

  defp nudge_github_locked(repository, number, head_sha) do
    now = database_now!()

    query =
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where:
          publication.status == :published and publication.github_repository == ^repository and
            publication.pull_request_number == ^number and followup.pr_state == "open",
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil ->
        :ignored

      followup ->
        publication = Repo.get!(Publication, followup.publication_id)

        if is_nil(head_sha) or head_sha == publication.commit_sha do
          update_followup!(followup, %{next_poll_at: now}, now)
          :nudged
        else
          :ignored
        end
    end
  end

  defp github_event_identity("pull_request", %{"pull_request" => pull}) do
    github_pull_identity(pull)
  end

  defp github_event_identity(event, payload)
       when event in ~w(check_run check_suite workflow_run) do
    item = payload[event]

    with %{} <- item,
         [%{"number" => number} | _rest] <- item["pull_requests"],
         true <- is_integer(number) and number > 0 do
      {:ok, number, get_in(item, ["head_sha"]) || get_in(item, ["head_commit", "id"])}
    else
      _invalid -> {:error, :identity}
    end
  end

  defp github_event_identity(_event, _payload), do: {:error, :identity}

  defp github_feedback_identity(%Input{
         source: %{kind: "github"},
         content: %{
           "event_name" => "issue_comment",
           "payload" => %{
             "issue" => %{"number" => number, "pull_request" => %{}},
             "repository" => %{"full_name" => repository}
           }
         }
       })
       when is_binary(repository) and is_integer(number) and number > 0,
       do: {:ok, repository, number}

  defp github_feedback_identity(%Input{
         source: %{kind: "github"},
         content: %{
           "event_name" => event_name,
           "payload" => %{
             "pull_request" => %{"number" => number},
             "repository" => %{"full_name" => repository}
           }
         }
       })
       when event_name in ~w(pull_request_review pull_request_review_comment) and
              is_binary(repository) and is_integer(number) and number > 0,
       do: {:ok, repository, number}

  defp github_feedback_identity(%Input{source: %{kind: "github"}}), do: :unmatched

  defp github_feedback_identity(_input),
    do: {:error, {:invalid_publication_review_feedback, :source}}

  defp github_pull_identity(%{"head" => %{"sha" => sha}, "number" => number})
       when is_integer(number) and number > 0 and is_binary(sha),
       do: {:ok, number, sha}

  defp github_pull_identity(_pull), do: {:error, :identity}

  defp lifecycle_event(publication, attributes) do
    key = attributes.key
    source = attributes.source
    id = deterministic_uuid(key)

    %{
      delivery_ref: "publication-lifecycle:#{key}",
      episode_id: publication.episode_id,
      id: id,
      kind: attributes.kind,
      observation: attributes.observation,
      occurred_at: attributes.occurred_at,
      publication_id: publication.id,
      ref: "publication-event:#{key}",
      source_conversation_ref: source && source.conversation_ref,
      source_item_ref: source && source.item_ref,
      source_transport: source && source.transport,
      state: attributes.state,
      summary: attributes.summary,
      wakeup_state: if(attributes.wakeup?, do: :pending, else: :none)
    }
  end

  defp insert_lifecycle_event!(attributes) do
    case insert_lifecycle_event(attributes) do
      {:ok, event} -> event
      {:duplicate, event} -> event
    end
  end

  defp insert_lifecycle_event(attributes) do
    changeset = LifecycleEventChangeset.insert(attributes)

    if changeset.valid? do
      now = database_now!()

      row =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.from_struct()
        |> Map.drop([:__meta__, :episode, :publication])
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {count, _rows} =
        Repo.insert_all(LifecycleEvent, [row],
          conflict_target: [:ref],
          on_conflict: :nothing
        )

      event = Repo.one!(from(event in LifecycleEvent, where: event.ref == ^attributes.ref))
      if count == 1, do: {:ok, event}, else: {:duplicate, event}
    else
      Repo.rollback({:publication_lifecycle_persistence_failed, changeset.errors})
    end
  end

  defp exact_reference?(supplied, publication, followup) do
    references =
      [
        publication.pull_request_url,
        publication.branch_ref,
        String.replace_prefix(publication.branch_ref || "", "refs/heads/", ""),
        publication.commit_sha,
        followup.merge_sha
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    Enum.any?(supplied, &(&1 in references))
  end

  defp source_summary(publication, kind, state) do
    label = if kind == "terraform", do: "Terraform", else: "Deployment"

    "#{label} #{state} for draft PR ##{publication.pull_request_number}; the source carried an exact publication reference."
  end

  defp status_state("merged", _checks), do: "succeeded"
  defp status_state("closed", _checks), do: "stopped"
  defp status_state(_pr, "failing"), do: "failed"
  defp status_state(_pr, _checks), do: "pending"

  defp current_summary(publication, pr_state, status) do
    checks = status["checks_state"]
    "PR ##{publication.pull_request_number} is #{pr_state}; GitHub checks are #{checks}."
  end

  defp wakeup_input(_publication, episode, %LifecycleEvent{kind: "review_feedback"} = event) do
    observation = event.observation

    {:ok, input} =
      Input.new(%{
        actor: feedback_actor(observation),
        content: Map.fetch!(observation, "content"),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        event_kind: feedback_event_kind(observation),
        event_ref: event.ref,
        native_input_id: Map.fetch!(observation, "native_input_id"),
        occurred_at: event.occurred_at,
        occurred_at_source: :source,
        revision: Map.fetch!(observation, "revision"),
        source: feedback_source(observation),
        source_capabilities: %{},
        source_item_ref: nil
      })

    input
  end

  defp wakeup_input(publication, episode, event) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :system, ref: "publication-lifecycle"},
        content:
          Map.merge(
            %{
              "kind" => "publication_lifecycle",
              "lifecycle" => %{
                "kind" => event.kind,
                "observation" => event.observation,
                "publication_event_ref" => event.ref,
                "state" => event.state,
                "summary" => event.summary
              },
              "publication" => %{
                "branch_ref" => publication.branch_ref,
                "head_sha" => publication.commit_sha,
                "merge_sha" => publication_followup_merge(publication.id),
                "pull_request_number" => publication.pull_request_number,
                "pull_request_url" => publication.pull_request_url,
                "repository" => publication.repository
              }
            },
            wakeup_request(event)
          ),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        event_kind: :event,
        event_ref: event.ref,
        native_input_id: "publication-lifecycle:#{event.id}",
        occurred_at: event.occurred_at,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "system", ref: "publication-lifecycle"},
        source_capabilities: %{},
        source_item_ref: nil
      })

    input
  end

  # A red check asks the agent to finish its own change; a deployment or
  # Terraform signal asks it to verify one that already shipped. Naming the two
  # differently is what keeps a correction from being reported as a verification.
  defp wakeup_request(%LifecycleEvent{kind: "checks"}),
    do: %{
      "correction_request" =>
        "The checks on this exact pull request are failing. Fix them inside the task's existing scope and update the same branch, or say precisely what is blocking them. Do not widen the task, and do not merge or deploy."
    }

  defp wakeup_request(_event),
    do: %{
      "verification_request" =>
        "Verify the deployed change against current authoritative evidence and report the result in the source task thread."
    }

  defp admit_command(episode, input, event) do
    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode.id,
      episode_key: episode.key,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: publication_turn_ref(event)
    }
  end

  defp publication_turn_ref(%LifecycleEvent{kind: "review_feedback", id: id}),
    do: "turn:publication-feedback:#{id}"

  defp publication_turn_ref(%LifecycleEvent{id: id}),
    do: "turn:publication-verification:#{id}"

  defp feedback_actor(%{"actor" => %{"kind" => kind, "ref" => ref}}),
    do: %{kind: feedback_actor_kind(kind), ref: ref}

  defp feedback_actor_kind("user"), do: :user
  defp feedback_actor_kind("app"), do: :app
  defp feedback_actor_kind("bot"), do: :bot
  defp feedback_actor_kind("system"), do: :system

  defp feedback_event_kind(%{"event_kind" => "message"}), do: :message
  defp feedback_event_kind(%{"event_kind" => "edit"}), do: :edit
  defp feedback_event_kind(%{"event_kind" => "delete"}), do: :delete
  defp feedback_event_kind(%{"event_kind" => "event"}), do: :event

  defp feedback_source(%{"source" => %{"kind" => kind, "ref" => ref}}),
    do: %{kind: kind, ref: ref}

  defp publication_followup_merge(publication_id), do: lock_followup(publication_id).merge_sha

  defp exact_delivery_receipt(event, publication, receipt) do
    if receipt["delivery_ref"] == event.delivery_ref and
         receipt["transport"] == publication.destination_transport and
         receipt["conversation_ref"] == publication.destination_conversation_ref and
         receipt["thread_ref"] == publication.destination_thread_ref,
       do: :ok,
       else: {:error, :publication_lifecycle_delivery_receipt_mismatch}
  end

  defp live_event_lease(event, lease_ref, now) do
    if event.delivery_state == :pending and event.lease_ref == lease_ref and
         is_struct(event.lease_expires_at, DateTime) and
         DateTime.compare(event.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :publication_lifecycle_lease_lost}
  end

  defp lock_followup(publication_id) do
    Repo.one!(
      from(followup in Followup,
        where: followup.publication_id == ^publication_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_followup_by_publication_ref(publication_ref) do
    Repo.one(
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where: publication.ref == ^publication_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_lifecycle_event(event_ref) do
    Repo.one(from(event in LifecycleEvent, where: event.ref == ^event_ref, lock: "FOR UPDATE"))
  end

  defp update_followup!(followup, attributes, now) do
    followup
    |> FollowupChangeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
  end

  defp mark_stale_publication!(publication, observed_head_sha, now) do
    publication
    |> PublicationChangeset.update(%{
      expected_remote_head_sha: observed_head_sha,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp reset_followup!(followup, publication, now) do
    update_followup!(
      followup,
      %{
        checks_failed: 0,
        checks_passed: 0,
        checks_state: "unknown",
        checks_total: 0,
        checks_url: nil,
        deadline_at: DateTime.add(now, @default_deadline_seconds, :second),
        failure_count: 0,
        last_error: nil,
        last_event_key: "baseline:#{String.slice(publication.commit_sha || "pending", 0, 64)}",
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        manual_check_ref: nil,
        merge_sha: nil,
        merged_at: nil,
        next_poll_at: now,
        pr_state: "open",
        verification_event_ref: nil,
        verification_sequence: nil,
        verification_turn_ref: nil,
        verified_at: nil
      },
      now
    )
  end

  defp update_event!(event, attributes, now) do
    event
    |> LifecycleEventChangeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
  end

  defp parse_optional_datetime!(nil), do: nil

  defp parse_optional_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp lifecycle_key(parts), do: CanonicalJSON.digest(parts) |> binary_part(0, 32)

  defp deterministic_uuid(key) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _rest::binary>> =
      :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp bounded_error(reason) do
    value = inspect(reason, limit: 20, printable_limit: 3_500, width: 120)
    if byte_size(value) <= 4_096, do: value, else: String.byte_slice(value, 0, 4_093) <> "..."
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_publication_followup, field}}

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication_followup, field}}
  end

  defp database_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
