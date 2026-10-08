defmodule Ryker.Slack.TaskCards do
  @moduledoc """
  Durable custody for Slack engineering-task card projections.

  The confirmed task record and episode remain canonical. This module repairs
  a missing projection after a crash, then leases in-place card refreshes. It
  never grants repository, publication, or Coop authority.

  Each card created, refreshed, blocked or rearmed is announced after the
  outermost commit (`subscribe_task_cards/0`), on its request's topics too.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.TaskCard
  alias Ryker.Text
  alias Ryker.Work

  @doc """
  Makes the card of `episode_id` due at the next claim: something it shows was
  announced as changed. Unannounced itself, as no page shows when a card was
  last checked.
  """
  @spec check_soon(Ecto.UUID.t()) :: :ok
  def check_soon(episode_id) do
    Repo.update_all(TaskCard.Query.checked_for(episode_id), set: [card_checked_at: nil])

    :ok
  end

  @doc """
  Makes the card of the oldest confirmed engineering task offer that has none,
  passing over the offers in `skip`: nil when every offer has its card. An
  offer whose card cannot be built is `{:task_card_unbuildable, record_id,
  reason}`.
  """
  @spec ensure_one([Ecto.UUID.t()]) :: {:ok, TaskCard.t() | nil} | {:error, term()}
  def ensure_one(skip \\ []) when is_list(skip) do
    Repo.transaction(fn -> ensure_one_locked(skip) end)
    |> transaction_result()
  end

  @doc """
  The earliest moment after `since` at which an active card becomes due by the
  clock alone: its next check after the last (`check_interval_seconds` while
  its task works, ten minutes otherwise), the end of a retry's backoff, or the
  end of an unrenewed lease, whichever it waits on last. Nil when no card
  waits on the clock.
  """
  @spec next_due_at(DateTime.t(), pos_integer()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, check_interval_seconds)
      when is_integer(check_interval_seconds) do
    since
    |> TaskCard.Query.select_next_due_after(check_interval_seconds)
    |> Repo.one()
  end

  @doc """
  The message of the card that shows `episode_id`'s task in exactly this
  Slack conversation and thread, or nil when there is none. A publication's
  review and pull request are that card's to show (`Ryker.Publication.Executor`).
  """
  @spec message_ref(Ecto.UUID.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def message_ref(episode_id, "slack:" <> conversation, thread_ref)
      when is_binary(episode_id) and is_binary(thread_ref) do
    case String.split(conversation, ":") do
      [workspace, channel] ->
        Repo.one(TaskCard.Query.message_in_thread(episode_id, workspace, channel, thread_ref))

      _other ->
        nil
    end
  end

  def message_ref(_episode_id, _conversation_ref, _thread_ref), do: nil

  @doc """
  Settles `request` by the card that shows `episode_id`'s task in the same
  Slack thread: the card's own message is its receipt, and nothing new is
  posted. Nil when the task has no card there, and the request is posted.

  The card shows a publication's review, its pull request, CI and review
  feedback, with every control they need, and refreshes itself in place. A
  message for each said it again underneath: Andrew, 2026-09-28, of four
  identical "Authenticated GitHub review feedback arrived for PR #2" posts,
  "it's bad to have spam that is not actionable by users, especially if last
  message is the task card we are updating anyways!"
  """
  @spec card_receipt(Ecto.UUID.t() | nil, Delivery.Request.t()) ::
          {:ok, Work.DeliveryReceipt.t()} | {:error, term()} | nil
  def card_receipt(episode_id, %Delivery.Request{} = request) do
    case message_ref(episode_id, request.conversation_ref, request.thread_ref) do
      nil ->
        nil

      message_ref ->
        Work.DeliveryReceipt.new(
          request.ref,
          request.transport,
          request.conversation_ref,
          request.thread_ref,
          message_ref
        )
    end
  end

  @spec claim_next(String.t(), pos_integer(), pos_integer()) ::
          {:ok, TaskCard.t() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds, check_interval_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- bounded_integer(lease_seconds, 5..3_600, :lease_seconds),
         :ok <- bounded_integer(check_interval_seconds, 1..86_400, :check_interval_seconds) do
      Repo.transaction(fn ->
        claim_next_locked(worker_ref, lease_seconds, check_interval_seconds)
      end)
      |> transaction_result()
    end
  end

  defp claim_next_locked(worker_ref, lease_seconds, check_interval_seconds) do
    now = Repo.now!()

    query = TaskCard.Query.next_claimable(now, check_interval_seconds)

    case Repo.one(query) do
      nil -> nil
      %TaskCard{} = card -> lease_card(card, worker_ref, lease_seconds, now)
    end
  end

  # A claim only takes the lease, which no page shows. A working task's card is
  # claimed every few seconds; announcing each claim woke every worker that
  # listens to requests as often.
  defp lease_card(card, worker_ref, lease_seconds, now) do
    update!(
      card,
      %{
        attempt_count: card.attempt_count + 1,
        lease_expires_at: DateTime.add(now, lease_seconds, :second),
        lease_owner: worker_ref,
        lease_ref: Ecto.UUID.generate(),
        next_attempt_at: nil
      },
      now,
      :quiet
    )
  end

  @spec mark(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), pos_integer()) ::
          {:ok, TaskCard.t()} | {:error, term()}
  def mark(card_id, lease_ref, fingerprint, ui_revision) do
    with {:ok, card_id} <- uuid(card_id, :card_id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- sha256(fingerprint, :card_fingerprint),
         :ok <- bounded_integer(ui_revision, 1..1_000_000, :card_ui_revision) do
      mutate_claim(card_id, lease_ref, fn card, now ->
        # The attempts count consecutive failures: a card refreshed a hundred
        # times must not wait an hour after its first transient one.
        update!(
          card,
          %{
            attempt_count: 0,
            card_checked_at: now,
            card_fingerprint: fingerprint,
            card_ui_revision: ui_revision,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil
          },
          now,
          check_announcement(card, fingerprint, ui_revision)
        )
      end)
    end
  end

  @doc """
  Stops refreshing one card until a person rearms it: Slack said the message
  or its channel is gone, or the card spent every attempt it had.
  """
  @spec block(Ecto.UUID.t(), Ecto.UUID.t(), term()) :: {:ok, TaskCard.t()} | {:error, term()}
  def block(card_id, lease_ref, reason) do
    with {:ok, card_id} <- uuid(card_id, :card_id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref) do
      mutate_claim(card_id, lease_ref, fn card, now ->
        {code, detail} = describe_error(reason)

        update!(
          card,
          %{
            last_error_code: code,
            last_error_detail: detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: :blocked
          },
          now
        )
      end)
    end
  end

  @doc """
  Rearms one exact blocked card after operator inspection: it is due at once
  with a fresh attempt budget. The card's message and task are unchanged.
  """
  @spec rearm(String.t()) :: {:ok, TaskCard.t()} | {:error, term()}
  def rearm(ref) do
    with :ok <- reference(ref, :ref) do
      Repo.transaction(fn -> rearm_locked(ref) end)
      |> transaction_result()
    end
  end

  defp rearm_locked(ref) do
    now = Repo.now!()

    case Repo.one(ref |> TaskCard.Query.by_ref() |> TaskCard.Query.lock_for_update()) do
      nil ->
        Repo.rollback(:task_card_not_found)

      %TaskCard{status: :blocked} = card ->
        update!(
          card,
          %{
            attempt_count: 0,
            card_checked_at: nil,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: :active
          },
          now
        )

      %TaskCard{} ->
        Repo.rollback(:task_card_not_blocked)
    end
  end

  @doc """
  Refreshes the card again after `retry_seconds`. With `counted: false` the
  attempt just made is given back, for a wait Slack asked for rather than a
  failure.
  """
  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term(), keyword()) ::
          {:ok, TaskCard.t()} | {:error, term()}
  def defer(card_id, lease_ref, retry_seconds, reason, options \\ [])
      when is_integer(retry_seconds) and retry_seconds > 0 do
    with {:ok, card_id} <- uuid(card_id, :card_id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref) do
      mutate_claim(card_id, lease_ref, fn card, now ->
        {code, detail} = describe_error(reason)

        update!(
          card,
          %{
            attempt_count: given_back(card.attempt_count, options),
            last_error_code: code,
            last_error_detail: detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, retry_seconds, :second)
          },
          now
        )
      end)
    end
  end

  defp given_back(attempt_count, options) do
    if Keyword.get(options, :counted, true), do: attempt_count, else: max(attempt_count - 1, 0)
  end

  defp ensure_one_locked(skip) do
    AdvisoryLock.hold!("slack-task-card-repair")

    row = Repo.one(TaskCard.Query.next_uncarded_offer(skip))

    case row do
      nil ->
        nil

      {%Records.Record{} = record, %Work.Turn{} = source_turn, %Episodes.Episode{} = episode} ->
        insert!(record, source_turn, episode)
    end
  end

  defp insert!(record, source_turn, episode) do
    receipt = source_turn.external_receipt

    with {:ok, workspace_ref, channel_ref} <- slack_conversation(receipt["conversation_ref"]),
         :ok <- reference(receipt["message_ref"], :message_ref),
         :ok <- reference(episode.destination_thread_ref, :thread_ref) do
      attributes = %{
        attempt_count: 0,
        channel_ref: channel_ref,
        episode_id: episode.id,
        id: Repo.generate_id(),
        message_ref: receipt["message_ref"],
        record_id: record.id,
        ref: "task-card:#{record.id}",
        thread_ref: episode.destination_thread_ref,
        workspace_ref: workspace_ref
      }

      changeset = TaskCard.Changeset.insert(attributes)

      case Repo.insert(changeset) do
        {:ok, card} ->
          tap(card, &broadcast_task_card_updated/1)

        {:error, changeset} ->
          Repo.rollback(
            {:task_card_unbuildable, record.id, {:task_card_persistence_failed, changeset.errors}}
          )
      end
    else
      {:error, reason} -> Repo.rollback({:task_card_unbuildable, record.id, reason})
    end
  end

  defp mutate_claim(card_id, lease_ref, callback) do
    Repo.transaction(fn ->
      now = Repo.now!()
      card = card_id |> TaskCard.Query.by_id() |> TaskCard.Query.lock_for_update() |> Repo.one()

      cond do
        is_nil(card) ->
          Repo.rollback(:task_card_not_found)

        card.lease_ref != lease_ref ->
          Repo.rollback(:task_card_lease_lost)

        DateTime.compare(card.lease_expires_at, now) != :gt ->
          Repo.rollback(:task_card_lease_lost)

        true ->
          callback.(card, now)
      end
    end)
    |> transaction_result()
  end

  # A check that found the card as it was, with nothing to clear, changed
  # nothing anyone sees.
  defp check_announcement(
         %TaskCard{
           card_fingerprint: fingerprint,
           card_ui_revision: revision,
           last_error_code: nil
         },
         fingerprint,
         revision
       ),
       do: :quiet

  defp check_announcement(_card, _fingerprint, _revision), do: :announce

  defp update!(card, attributes, now, announce \\ :announce) do
    changeset = TaskCard.Changeset.update(card, Map.put(attributes, :updated_at, now))

    case Repo.update(changeset) do
      {:ok, card} when announce == :quiet -> card
      {:ok, card} -> tap(card, &broadcast_task_card_updated/1)
      {:error, changeset} -> Repo.rollback({:task_card_persistence_failed, changeset.errors})
    end
  end

  defp slack_conversation("slack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [workspace_ref, channel_ref] ->
        with :ok <- reference(workspace_ref, :workspace_ref),
             :ok <- reference(channel_ref, :channel_ref) do
          {:ok, workspace_ref, channel_ref}
        end

      _invalid ->
        {:error, :task_card_destination_invalid}
    end
  end

  defp slack_conversation(_value), do: {:error, :task_card_destination_invalid}

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "task_card_error"
      end
      |> Text.bytes(120)

    {code, ErrorDetail.detail(reason)}
  end

  defp sha256(value, field) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_task_card_request, field}}
  end

  defp bounded_integer(value, range, field) do
    if is_integer(value) and value in range,
      do: :ok,
      else: {:error, {:invalid_task_card_request, field}}
  end

  defp reference(value, field),
    do: Reference.check(value, field, :invalid_task_card_request)

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_task_card_request, field}}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to task card changes: `{:task_card_updated, card_id}`
  once a task's Slack card is created, refreshed, deferred, blocked or
  rearmed, and that change has committed.
  """
  def subscribe_task_cards, do: Ryker.PubSub.subscribe(task_cards_topic())

  def unsubscribe_task_cards, do: Ryker.PubSub.unsubscribe(task_cards_topic())

  defp task_cards_topic, do: "slack:task_cards"

  defp broadcast_task_card_updated(%TaskCard{id: id, episode_id: episode_id}) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(task_cards_topic(), {:task_card_updated, id})
    end)
  end
end
