defmodule Ryker.Slack.TaskCards do
  @moduledoc """
  Durable custody for Slack engineering-task card projections.

  The confirmed task record and episode remain canonical. This module repairs
  a missing projection after a crash, then leases in-place card refreshes. It
  never grants repository, publication, or Coop authority.

  Each card created, refreshed, blocked or rearmed is announced after the
  outermost commit (`subscribe_task_cards/0`), on its request's topics too.
  """

  import Ecto.Query

  alias Ryker.Delivery.Request
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.{TaskCard, TaskCardChangeset}
  alias Ryker.Work.{DeliveryReceipt, Turn}

  @maximum_error_detail_bytes 4_096

  # A card shows its task. While the task works its progress moves, so the card
  # is checked every few seconds (`check_interval_seconds`); otherwise only a
  # person, an event or GitHub moves it, and the card is checked once a minute.
  # Every active card was rebuilt every 2 seconds, finished tasks' too: five
  # cards kept an idle install at about 350 queries a second (2026-10-04).
  @quiet_check_seconds 60

  @spec ensure_one() :: {:ok, TaskCard.t() | nil} | {:error, term()}
  def ensure_one do
    Repo.transaction(&ensure_one_locked/0)
    |> transaction_result()
  end

  @doc """
  The earliest moment after `since` at which an active card becomes due by the
  clock alone: its next check after the last (`check_interval_seconds` while
  its task works, a minute otherwise), the end of a retry's backoff, or the
  end of an unrenewed lease, whichever it waits on last. Nil when no card
  waits on the clock.
  """
  @spec next_due_at(DateTime.t(), pos_integer()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, check_interval_seconds)
      when is_integer(check_interval_seconds) do
    due =
      from(card in TaskCard,
        left_join: episode in Episode,
        on: episode.id == card.episode_id,
        where: card.status == :active,
        select: %{
          due_at:
            type(
              fragment(
                "GREATEST(CASE WHEN ? = 'working' THEN ? ELSE ? END, ?, ?)",
                episode.state,
                datetime_add(card.card_checked_at, ^check_interval_seconds, "second"),
                datetime_add(card.card_checked_at, ^@quiet_check_seconds, "second"),
                card.next_attempt_at,
                card.lease_expires_at
              ),
              :utc_datetime_usec
            )
        }
      )

    Repo.one(from(card in subquery(due), where: card.due_at > ^since, select: min(card.due_at)))
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
        Repo.one(
          from(card in TaskCard,
            where:
              card.episode_id == ^episode_id and card.workspace_ref == ^workspace and
                card.channel_ref == ^channel and card.thread_ref == ^thread_ref and
                not is_nil(card.message_ref),
            order_by: [desc: card.inserted_at],
            limit: 1,
            select: card.message_ref
          )
        )

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
  @spec card_receipt(Ecto.UUID.t() | nil, Request.t()) ::
          {:ok, DeliveryReceipt.t()} | {:error, term()} | nil
  def card_receipt(episode_id, %Request{} = request) do
    case message_ref(episode_id, request.conversation_ref, request.thread_ref) do
      nil ->
        nil

      message_ref ->
        DeliveryReceipt.new(
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
    now = database_now!()
    due_at = DateTime.add(now, -check_interval_seconds, :second)
    quiet_due_at = DateTime.add(now, -@quiet_check_seconds, :second)

    working =
      from(episode in Episode,
        where: episode.id == parent_as(:card).episode_id and episode.state == :working
      )

    query =
      from(card in TaskCard,
        as: :card,
        where:
          card.status == :active and
            (is_nil(card.card_checked_at) or card.card_checked_at <= ^quiet_due_at or
               (card.card_checked_at <= ^due_at and exists(working))) and
            (is_nil(card.next_attempt_at) or card.next_attempt_at <= ^now) and
            (is_nil(card.lease_expires_at) or card.lease_expires_at <= ^now),
        order_by: [asc_nulls_first: card.card_checked_at, asc: card.updated_at, asc: card.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

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
    now = database_now!()

    case Repo.one(from(card in TaskCard, where: card.ref == ^ref, lock: "FOR UPDATE")) do
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

  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term()) ::
          {:ok, TaskCard.t()} | {:error, term()}
  def defer(card_id, lease_ref, retry_seconds, reason)
      when is_integer(retry_seconds) and retry_seconds > 0 do
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
            next_attempt_at: DateTime.add(now, retry_seconds, :second)
          },
          now
        )
      end)
    end
  end

  defp ensure_one_locked do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "slack-task-card-repair"
    ])

    row =
      Repo.one(
        from(record in Record,
          join: source_turn in Turn,
          on: source_turn.id == record.turn_id and source_turn.episode_id == record.episode_id,
          join: episode in Episode,
          on: episode.id == record.confirmed_episode_id,
          left_join: card in TaskCard,
          on: card.record_id == record.id,
          where:
            record.kind == "task_offer" and record.status == :confirmed and
              fragment("(?::jsonb)->>'kind' = 'engineering'", record.payload) and
              fragment("(?::jsonb)->>'transport' = 'slack'", source_turn.external_receipt) and
              is_nil(card.id),
          order_by: [asc: record.confirmed_at, asc: record.id],
          limit: 1,
          select: {record, source_turn, episode}
        )
      )

    case row do
      nil ->
        nil

      {%Record{} = record, %Turn{} = source_turn, %Episode{} = episode} ->
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
        id: Ecto.UUID.generate(),
        message_ref: receipt["message_ref"],
        record_id: record.id,
        ref: "task-card:#{record.id}",
        thread_ref: episode.destination_thread_ref,
        workspace_ref: workspace_ref
      }

      case attributes |> TaskCardChangeset.insert() |> Repo.insert() do
        {:ok, card} -> tap(card, &broadcast_task_card_updated/1)
        {:error, changeset} -> Repo.rollback({:task_card_persistence_failed, changeset.errors})
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp mutate_claim(card_id, lease_ref, callback) do
    Repo.transaction(fn ->
      now = database_now!()
      card = Repo.one(from(card in TaskCard, where: card.id == ^card_id, lock: "FOR UPDATE"))

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
    case card
         |> TaskCardChangeset.update(Map.put(attributes, :updated_at, now))
         |> Repo.update() do
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

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "task_card_error"
      end
      |> byte_slice(120)

    detail =
      reason
      |> inspect(limit: 30, printable_limit: 3_000)
      |> byte_slice(@maximum_error_detail_bytes)

    {code, detail}
  end

  defp byte_slice(value, maximum) do
    if byte_size(value) <= maximum do
      value
    else
      value
      |> String.graphemes()
      |> Enum.reduce_while("", fn grapheme, output ->
        append_grapheme(output, grapheme, maximum)
      end)
    end
  end

  defp append_grapheme(output, grapheme, maximum) do
    if byte_size(output) + byte_size(grapheme) <= maximum,
      do: {:cont, output <> grapheme},
      else: {:halt, output}
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

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_task_card_request, field}}
  end

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
