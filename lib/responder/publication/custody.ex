defmodule Responder.Publication.Custody do
  @moduledoc """
  Durable review, approval, publication, and notification custody.

  A model-created publication offer is inert. This module binds it to the
  delivered episode, its immutable Coop session generation, and one trusted
  repository before any review or GitHub mutation can run.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Responder.Delivery.Request
  alias Responder.Episodes.Episode
  alias Responder.Publication.{Card, Changeset, Followups, Publication, Receipt, Review}
  alias Responder.Repo
  alias Responder.Slack.TaskCard
  alias Responder.State.{Record, Records}
  alias Responder.Work.{DeliveryReceipt, Session, Turn}

  @claimable [:review_pending, :review_ready, :publish_pending, :published_ready]
  @request_fields [:actor_ref, :occurred_at, :record_ref, :request_ref, :target]
  @approval_fields [:actor_ref, :approval_ref, :occurred_at, :publication_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @spec request_review(keyword() | map()) ::
          {:ok, %{publication: Publication.t(), status: :requested | :duplicate}}
          | {:error, term()}
  def request_review(attributes) do
    with {:ok, attributes} <- attributes(attributes, @request_fields, :review),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         :ok <- reference(attributes.request_ref, :request_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        request_review_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok,
           nil | %{lease_ref: String.t(), publication: Publication.t(), session: Session.t()}}
          | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def freeze_review_revision(publication_ref, lease_ref, revision) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(revision, :review_expected_revision) do
      Repo.transaction(fn ->
        freeze_review_revision_locked(publication_ref, lease_ref, revision)
      end)
      |> transaction_result()
    end
  end

  def advance_review_generation(publication_ref, lease_ref, generation) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(generation, :review_generation) do
      Repo.transaction(fn ->
        advance_review_generation_locked(publication_ref, lease_ref, generation)
      end)
      |> transaction_result()
    end
  end

  def store_review(publication_ref, lease_ref, generation, review, patch) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(generation, :review_generation) do
      Repo.transaction(fn ->
        store_review_locked(publication_ref, lease_ref, generation, review, patch)
      end)
      |> transaction_result()
    end
  end

  @spec delivery_request(Publication.t()) :: {:ok, Request.t()} | {:error, term()}
  def delivery_request(%Publication{status: :review_ready} = publication) do
    message =
      if Review.publishable?(publication.review_document),
        do:
          "The committed change passed the trusted review. An operator may publish this exact candidate as a draft pull request.",
        else: "The committed change is not publishable. The trusted review details are below."

    delivery_request(
      publication,
      "publication-review:#{publication.id}",
      message,
      Card.review(publication)
    )
  end

  def delivery_request(%Publication{status: :published_ready} = publication) do
    receipt = publication.publication_receipt
    message = "Published draft pull request: #{receipt["pull_request_url"]}"

    delivery_request(
      publication,
      "publication-result:#{publication.id}",
      message,
      Card.published(publication)
    )
  end

  def delivery_request(_publication), do: {:error, :publication_delivery_not_pending}

  def confirm_delivery(publication_ref, lease_ref, external_receipt) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(external_receipt) do
      Repo.transaction(fn -> confirm_delivery_locked(publication_ref, lease_ref, receipt) end)
      |> transaction_result()
    end
  end

  def approve(attributes) do
    with {:ok, attributes} <- attributes(attributes, @approval_fields, :approval),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.approval_ref, :approval_ref),
         :ok <- reference(attributes.publication_ref, :publication_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        approve_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  def store_publication(publication_ref, lease_ref, receipt) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn -> store_publication_locked(publication_ref, lease_ref, receipt) end)
      |> transaction_result()
    end
  end

  def renew(publication_ref, lease_ref, lease_seconds) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(publication_ref, lease_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def defer(publication_ref, lease_ref, retry_seconds, code, detail) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(retry_seconds, :retry_seconds),
         :ok <- bounded_error(code, :last_error_code),
         :ok <- bounded_error(detail, :last_error_detail) do
      Repo.transaction(fn ->
        defer_locked(publication_ref, lease_ref, retry_seconds, code, detail)
      end)
      |> transaction_result()
    end
  end

  defp freeze_review_revision_locked(publication_ref, lease_ref, revision) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending) do
      case publication.review_expected_revision do
        nil -> update!(publication, %{review_expected_revision: revision}, now)
        ^revision -> publication
        _other -> Repo.rollback(:publication_review_revision_conflict)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp advance_review_generation_locked(publication_ref, lease_ref, generation) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending),
         true <- publication.review_generation == generation do
      update!(
        publication,
        %{review_expected_revision: nil, review_generation: generation + 1},
        now
      )
    else
      false -> Repo.rollback(:publication_review_generation_stale)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp store_review_locked(publication_ref, lease_ref, generation, review, patch) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending),
         true <- publication.review_generation == generation,
         {:ok, session} <- session(publication.session_id),
         {:ok, prepared} <-
           Review.prepare(review, %{
             revision: publication.review_expected_revision,
             session_id: session.coop_session_id
           }),
         :ok <- exact_review_policy(prepared, session),
         {:ok, patch} <- exact_patch(prepared, patch) do
      persist_review(publication, prepared, patch, now)
    else
      false -> Repo.rollback(:publication_review_generation_stale)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_review(publication, prepared, patch, now) do
    update!(
      publication,
      %{
        review_document: prepared,
        review_fingerprint: Review.fingerprint(prepared),
        review_patch: patch,
        reviewed_at: now,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        status: :review_ready
      },
      now
    )
  end

  defp store_publication_locked(publication_ref, lease_ref, receipt) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :publish_pending),
         {:ok, receipt} <-
           Receipt.prepare(receipt, publication.review_document, publication.repository) do
      persist_publication(publication, receipt, now)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_publication(publication, receipt, now) do
    update!(
      publication,
      %{
        branch_ref: receipt["branch_ref"],
        commit_sha: receipt["commit_sha"],
        github_repository: github_repository!(receipt["pull_request_url"]),
        publication_receipt: receipt,
        publication_receipt_fingerprint: Receipt.fingerprint(receipt),
        pull_request_number: receipt["pull_request_number"],
        pull_request_url: receipt["pull_request_url"],
        published_at: now,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        status: :published_ready
      },
      now
    )
  end

  defp renew_locked(publication_ref, lease_ref, lease_seconds) do
    case lock_leased(publication_ref, lease_ref) do
      {:ok, publication, now} ->
        update!(
          publication,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp defer_locked(publication_ref, lease_ref, retry_seconds, code, detail) do
    case lock_leased(publication_ref, lease_ref) do
      {:ok, publication, now} ->
        update!(
          publication,
          %{
            last_error_code: code,
            last_error_detail: detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, retry_seconds, :second)
          },
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp request_review_locked(attributes) do
    case publication_for_record(attributes.record_ref) do
      %Publication{} = publication ->
        if publication.review_request_ref == attributes.request_ref and
             publication.review_requested_by_actor_ref == attributes.actor_ref do
          %{publication: publication, status: :duplicate}
        else
          Repo.rollback(:publication_offer_already_requested)
        end

      nil ->
        create_review_request(attributes)
    end
  end

  defp create_review_request(attributes) do
    with {:ok, record, episode, turn, session} <- delivered_offer(attributes.record_ref),
         :ok <- delivered_offer_proof(record, episode, turn, attributes.target),
         {:ok, repository} <- repository(session, episode.id),
         true <- is_binary(session.coop_session_id) do
      id = Ecto.UUID.generate()

      publication =
        Changeset.insert(%{
          body: record.payload["body"],
          destination_conversation_ref: episode.destination_conversation_ref,
          destination_thread_ref: episode.destination_thread_ref,
          destination_transport: episode.destination_transport,
          episode_id: episode.id,
          id: id,
          offer_message_ref: attributes.target.message_ref,
          record_id: record.id,
          ref: "publication:#{id}",
          repository: repository,
          review_request_ref: attributes.request_ref,
          review_requested_at: attributes.occurred_at,
          review_requested_by_actor_ref: attributes.actor_ref,
          session_id: session.id,
          status: :review_pending,
          title: record.payload["title"]
        })
        |> Repo.insert()

      case publication do
        {:ok, publication} -> %{publication: publication, status: :requested}
        {:error, changeset} -> Repo.rollback({:publication_persistence_failed, changeset.errors})
      end
    else
      false -> Repo.rollback(:publication_session_not_bound)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp publication_for_record(record_ref) do
    Repo.one(
      from(publication in Publication,
        join: record in Record,
        on: record.id == publication.record_id,
        where: record.ref == ^record_ref,
        select: publication,
        lock: "FOR UPDATE"
      )
    )
  end

  defp delivered_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        join: session in Session,
        on: session.id == turn.session_id and session.episode_id == record.episode_id,
        where:
          record.ref == ^record_ref and record.kind == "publication_offer" and
            record.status == :open,
        select: {record, episode, turn, session}
      )

    case Repo.one(query) do
      {%Record{} = record, %Episode{} = episode, %Turn{status: :settled} = turn,
       %Session{} = session} ->
        {:ok, record, episode, turn, session}

      nil ->
        {:error, :publication_offer_not_found}

      _not_delivered ->
        {:error, :publication_offer_not_delivered}
    end
  end

  defp delivered_target(episode, %Turn{external_receipt: receipt}, target) when is_map(receipt) do
    expected = %{
      conversation_ref: episode.destination_conversation_ref,
      message_ref: receipt["message_ref"],
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

    if expected == target, do: :ok, else: {:error, :publication_offer_delivery_mismatch}
  end

  defp delivered_target(_episode, _turn, _target),
    do: {:error, :publication_offer_not_delivered}

  defp delivered_offer_proof(
         %Record{operation_id: "host:publication:ready"} = record,
         episode,
         _turn,
         target
       ),
       do: task_card_offer_delivered(record, episode, target)

  defp delivered_offer_proof(record, episode, turn, target) do
    with :ok <- delivered_target(episode, turn, target),
         do: record_was_delivered(turn, record.ref)
  end

  defp task_card_offer_delivered(record, episode, %{transport: "slack"} = target) do
    card =
      Repo.one(
        from(card in TaskCard,
          where:
            card.episode_id == ^episode.id and
              card.rendered_publication_offer_ref == ^record.ref and
              not is_nil(card.card_fingerprint) and not is_nil(card.card_checked_at) and
              card.card_checked_at >= ^record.inserted_at,
          lock: "FOR SHARE"
        )
      )

    case card do
      %TaskCard{} = card ->
        expected = %{
          conversation_ref: "slack:#{card.workspace_ref}:#{card.channel_ref}",
          message_ref: card.message_ref,
          thread_ref: card.thread_ref,
          transport: "slack"
        }

        if expected == target,
          do: :ok,
          else: {:error, :publication_offer_delivery_mismatch}

      nil ->
        {:error, :publication_offer_not_delivered}
    end
  end

  defp task_card_offer_delivered(
         _publication_offer,
         episode,
         %{transport: "control_plane"} = target
       ) do
    row =
      Repo.one(
        from(task_offer in Record,
          join: source_turn in Turn,
          on:
            source_turn.id == task_offer.turn_id and
              source_turn.episode_id == task_offer.episode_id,
          join: source_episode in Episode,
          on: source_episode.id == task_offer.episode_id,
          where:
            task_offer.kind == "task_offer" and task_offer.status == :confirmed and
              task_offer.confirmed_episode_id == ^episode.id,
          select: {task_offer, source_episode, source_turn},
          lock: "FOR SHARE"
        )
      )

    case row do
      {%Record{} = task_offer, %Episode{} = source_episode, %Turn{status: :settled} = source_turn} ->
        with :ok <- same_destination(episode, source_episode),
             :ok <- delivered_target(source_episode, source_turn, target),
             do: record_was_delivered(source_turn, task_offer.ref)

      _missing_or_unsettled ->
        {:error, :publication_offer_not_delivered}
    end
  end

  defp task_card_offer_delivered(_record, _episode, _target),
    do: {:error, :publication_offer_not_delivered}

  defp same_destination(left, right) do
    if left.destination_transport == right.destination_transport and
         left.destination_conversation_ref == right.destination_conversation_ref and
         left.destination_thread_ref == right.destination_thread_ref,
       do: :ok,
       else: {:error, :publication_offer_delivery_mismatch}
  end

  defp record_was_delivered(%Turn{delivery_document: document}, record_ref) do
    if record_ref in get_in(document || %{}, ["outcome", "record_refs"]),
      do: :ok,
      else: {:error, :publication_offer_not_delivered}
  rescue
    Protocol.UndefinedError -> {:error, :publication_offer_not_delivered}
  end

  defp repository(%Session{repository_ref: repository, workspace_task: task}, _episode_id)
       when is_binary(repository) and is_map(task),
       do: {:ok, repository}

  defp repository(_session, episode_id) do
    case Records.repository_write_goals(episode_id) do
      [%{"writable_repository" => repository} | rest] ->
        if Enum.all?(rest, &(&1["writable_repository"] == repository)),
          do: {:ok, repository},
          else: {:error, :publication_repository_conflict}

      [] ->
        {:error, :publication_repository_not_bound}
    end
  end

  defp claim_next_locked(worker_ref, lease_seconds) do
    now = database_now!()

    query =
      from(publication in Publication,
        join: session in Session,
        on: session.id == publication.session_id and session.episode_id == publication.episode_id,
        where:
          publication.status in ^@claimable and
            (is_nil(publication.next_attempt_at) or publication.next_attempt_at <= ^now) and
            (is_nil(publication.lease_expires_at) or publication.lease_expires_at <= ^now),
        order_by: [asc: publication.inserted_at, asc: publication.id],
        limit: 1,
        select: {publication, session},
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(query) do
      nil ->
        nil

      {publication, session} ->
        lease_ref = "publication-lease:#{Ecto.UUID.generate()}"

        publication =
          update!(
            publication,
            %{
              attempt_count: publication.attempt_count + 1,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref,
              next_attempt_at: nil
            },
            now
          )

        %{lease_ref: lease_ref, publication: publication, session: session}
    end
  end

  defp confirm_delivery_locked(publication_ref, lease_ref, receipt) do
    publication = lock_publication(publication_ref)
    fingerprint = DeliveryReceipt.fingerprint(receipt)

    cond do
      publication == nil ->
        Repo.rollback(:publication_not_found)

      publication.review_delivery_receipt_fingerprint == fingerprint and
          publication.status in [:reviewed, :blocked] ->
        publication

      publication.published_delivery_receipt_fingerprint == fingerprint and
          publication.status == :published ->
        publication

      true ->
        now = database_now!()

        with :ok <- live_lease(publication, lease_ref, now),
             :ok <- exact_delivery_receipt(publication, receipt) do
          confirm_phase_delivery(publication, receipt, fingerprint, now)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp confirm_phase_delivery(%Publication{status: :review_ready} = publication, receipt, fp, now) do
    next = if Review.publishable?(publication.review_document), do: :reviewed, else: :blocked

    update!(
      publication,
      %{
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        review_delivery_receipt: receipt,
        review_delivery_receipt_fingerprint: fp,
        status: next
      },
      now
    )
  end

  defp confirm_phase_delivery(
         %Publication{status: :published_ready} = publication,
         receipt,
         fp,
         now
       ) do
    published =
      update!(
        publication,
        %{
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          published_delivery_receipt: receipt,
          published_delivery_receipt_fingerprint: fp,
          status: :published
        },
        now
      )

    _followup = Followups.ensure_published_in_transaction(published, now)
    published
  end

  defp confirm_phase_delivery(_publication, _receipt, _fp, _now),
    do: Repo.rollback(:publication_delivery_not_pending)

  defp approve_locked(attributes) do
    case lock_publication(attributes.publication_ref) do
      nil ->
        Repo.rollback(:publication_not_found)

      %Publication{approval_ref: approval_ref} = publication when is_binary(approval_ref) ->
        if exact_approval?(publication, attributes),
          do: %{publication: publication, status: :duplicate},
          else: Repo.rollback(:publication_approval_conflict)

      %Publication{status: :reviewed} = publication ->
        with true <- Review.publishable?(publication.review_document),
             :ok <- exact_approval_target(publication, attributes.target) do
          approved =
            update!(
              publication,
              %{
                approval_ref: attributes.approval_ref,
                approved_at: attributes.occurred_at,
                approved_by_actor_ref: attributes.actor_ref,
                status: :publish_pending
              },
              database_now!()
            )

          %{publication: approved, status: :approved}
        else
          false -> Repo.rollback(:publication_not_publishable)
          {:error, reason} -> Repo.rollback(reason)
        end

      _not_reviewed ->
        Repo.rollback(:publication_not_reviewed)
    end
  end

  defp exact_approval?(publication, attributes) do
    publication.approval_ref == attributes.approval_ref and
      publication.approved_by_actor_ref == attributes.actor_ref and
      publication.approved_at == attributes.occurred_at and
      exact_approval_target(publication, attributes.target) == :ok
  end

  defp exact_approval_target(publication, target) do
    receipt = publication.review_delivery_receipt

    expected = %{
      conversation_ref: publication.destination_conversation_ref,
      message_ref: receipt && receipt["message_ref"],
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    }

    if expected == target,
      do: :ok,
      else: {:error, :publication_review_delivery_mismatch}
  end

  defp lock_leased(publication_ref, lease_ref) do
    case lock_publication(publication_ref) do
      nil ->
        {:error, :publication_not_found}

      publication ->
        now = database_now!()

        case live_lease(publication, lease_ref, now) do
          :ok -> {:ok, publication, now}
          {:error, _reason} = error -> error
        end
    end
  end

  defp lock_publication(publication_ref) do
    Repo.one(
      from(publication in Publication,
        where: publication.ref == ^publication_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp live_lease(publication, lease_ref, now) do
    if publication.status in @claimable and publication.lease_ref == lease_ref and
         is_struct(publication.lease_expires_at, DateTime) and
         DateTime.compare(publication.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :publication_lease_lost}
  end

  defp exact_delivery_receipt(publication, receipt) do
    expected_ref =
      case publication.status do
        :review_ready -> "publication-review:#{publication.id}"
        :published_ready -> "publication-result:#{publication.id}"
        _other -> nil
      end

    if is_binary(expected_ref) and receipt["delivery_ref"] == expected_ref and
         receipt["transport"] == publication.destination_transport and
         receipt["conversation_ref"] == publication.destination_conversation_ref and
         receipt["thread_ref"] == publication.destination_thread_ref do
      :ok
    else
      {:error, :publication_delivery_receipt_mismatch}
    end
  end

  defp delivery_request(publication, ref, message, record) do
    Request.new(%{
      conversation_ref: publication.destination_conversation_ref,
      document: %{"message" => message, "records" => [record]},
      kind: :message,
      ref: ref,
      source_item_ref: nil,
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    })
  end

  defp exact_review_policy(%{"policy_digest" => digest}, %{policy_digest: digest}), do: :ok

  defp exact_review_policy(_review, _session),
    do: {:error, :publication_review_policy_mismatch}

  defp exact_patch(review, patch) do
    cond do
      Review.publishable?(review) and is_binary(patch) and patch != "" and
        byte_size(patch) == review["patch_bytes"] and digest(patch) == review["patch_digest"] ->
        {:ok, patch}

      not Review.publishable?(review) and is_nil(patch) ->
        {:ok, nil}

      true ->
        {:error, :publication_review_patch_mismatch}
    end
  end

  defp session(session_id) do
    case Repo.get(Session, session_id) do
      %Session{coop_session_id: coop_session_id} = session when is_binary(coop_session_id) ->
        {:ok, session}

      _missing ->
        {:error, :publication_session_not_bound}
    end
  end

  defp status(%Publication{status: expected}, expected), do: :ok
  defp status(_publication, _expected), do: {:error, :publication_status_changed}

  defp update!(publication, attributes, now) do
    publication
    |> Changeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
  end

  defp attributes(attributes, fields, namespace) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(fields, namespace),
       else: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}
  end

  defp attributes(attributes, fields, namespace) when is_map(attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
      do: {:ok, attributes},
      else: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}
  end

  defp attributes(_attributes, _fields, namespace),
    do: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}

  defp target(target) when is_map(target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_publication_target, :fields}}
    end
  end

  defp target(_target), do: {:error, {:invalid_publication_target, :fields}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication, field}}
  end

  defp bounded_error(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..4_096,
      do: :ok,
      else: {:error, {:invalid_publication, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_publication, field}}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_publication, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_publication, :occurred_at}}

  defp database_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp github_repository!(url) do
    %URI{host: "github.com", path: path} = URI.parse(url)
    [owner, repository, "pull", _number] = String.split(String.trim_leading(path, "/"), "/")
    "#{owner}/#{repository}"
  end
end
