defmodule Responder.Slack.TaskCards do
  @moduledoc """
  Durable custody for Slack engineering-task card projections.

  The confirmed task record and episode remain canonical. This module repairs
  a missing projection after a crash, then leases in-place card refreshes. It
  never grants repository, publication, or Coop authority.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.{TaskCard, TaskCardChangeset}
  alias Responder.State.Record
  alias Responder.Work.Turn

  @maximum_error_detail_bytes 4_096

  @spec ensure_one() :: {:ok, TaskCard.t() | nil} | {:error, term()}
  def ensure_one do
    Repo.transaction(&ensure_one_locked/0)
    |> transaction_result()
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

    query =
      from(card in TaskCard,
        where:
          (is_nil(card.card_checked_at) or card.card_checked_at <= ^due_at) and
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
      now
    )
  end

  @spec mark(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, TaskCard.t()} | {:error, term()}
  def mark(card_id, lease_ref, fingerprint, ui_revision, publication_offer_ref) do
    with {:ok, card_id} <- uuid(card_id, :card_id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- sha256(fingerprint, :card_fingerprint),
         :ok <- bounded_integer(ui_revision, 1..1_000_000, :card_ui_revision),
         :ok <- publication_offer_ref(publication_offer_ref) do
      mutate_claim(card_id, lease_ref, fn card, now ->
        update!(
          card,
          %{
            card_checked_at: now,
            card_fingerprint: fingerprint,
            card_ui_revision: ui_revision,
            rendered_publication_offer_ref: publication_offer_ref,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil
          },
          now
        )
      end)
    end
  end

  defp publication_offer_ref(nil), do: :ok

  defp publication_offer_ref(value) when is_binary(value) do
    if Regex.match?(~r/\Arecord:publication_offer:[A-Za-z0-9_.:-]{1,220}\z/, value),
      do: :ok,
      else: {:error, {:invalid_task_card_request, :rendered_publication_offer_ref}}
  end

  defp publication_offer_ref(_value),
    do: {:error, {:invalid_task_card_request, :rendered_publication_offer_ref}}

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
        {:ok, card} -> card
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

  defp update!(card, attributes, now) do
    case card
         |> TaskCardChangeset.update(Map.put(attributes, :updated_at, now))
         |> Repo.update() do
      {:ok, card} -> card
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
end
