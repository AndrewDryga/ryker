defmodule Ryker.Ingress.Inbox do
  @moduledoc """
  Transactional, idempotent custody for normalized source inputs.

  Recording does not classify content and does not create an episode. It only
  proves which exact source occurrence a later model decision is about.

  A voice message is recorded before it is transcribed, so Slack hears its
  acknowledgement at once. Routing does not take it until its words are
  filled in (`transcribed/2`), or until it has waited
  `Ryker.Transcription.wait_seconds/0`, when routing reads that Ryker could
  not transcribe it.

  Every custody step a message takes (recorded, transcribed, claimed for
  routing, retried, blocked, rearmed, routed or superseded) is announced after
  its commit on the topics this module owns (`subscribe_inputs/0`,
  `subscribe_input/1`).
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Artifacts
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Ingress.InputCustodyTransition
  alias Ryker.Ingress.Projections
  alias Ryker.Ingress.WorkProfile
  alias Ryker.InspectionRedactor
  alias Ryker.Learning
  alias Ryker.Lease
  alias Ryker.Memories
  alias Ryker.People
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Slack
  alias Ryker.Transcription
  alias Ryker.UTCDateTime

  @ref_prefix "ingress-input:"

  @type receipt :: %{entry: Entry.t(), status: :recorded | :duplicate}
  @type claim :: %{entry: Entry.t(), lease_ref: String.t()}
  @maximum_record_batch 500
  @maximum_revision 9_223_372_036_854_775_807

  @spec record(Input.t(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def record(%Input{} = input, options \\ []) do
    case record_many([input], options) do
      {:ok, [receipt]} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Atomically records a bounded provider batch.

  Every input is validated before the transaction. A conflict or persistence
  failure on any member rolls back the entire batch, including projections.
  """
  @spec record_many([Input.t()], keyword()) :: {:ok, [receipt()]} | {:error, term()}
  def record_many(inputs, options \\ []) do
    with {:ok, settings} <- record_options(options),
         {:ok, inputs} <- prepare_inputs(inputs),
         :ok <- slack_addressing_sources(inputs, settings.slack_addressing) do
      Repo.transaction(fn -> record_batch_locked(inputs, settings) end)
      |> record_rule_inventories(inputs)
      |> observe_feedback()
    end
  end

  # What a person's new message, edit or deletion says about an answer Ryker
  # already gave (`Ryker.Feedback.Messages`), read after the custody commit
  # like the rule inventories: it is evidence about the message, never a
  # reason to refuse it. A duplicate delivery was read the first time.
  defp observe_feedback({:ok, receipts}) do
    for %{status: :recorded, entry: entry} <- receipts, do: Feedback.Messages.observe(entry)
    {:ok, receipts}
  end

  defp observe_feedback(result), do: result

  # Written after the custody transaction commits, deliberately outside it.
  # This is evidence about a decision that has already been made: a failed
  # insert inside the transaction would abort the whole batch, which would turn
  # "we could not write down why" into "the message was never accepted". A
  # duplicate delivery's inventory was written the first time; every
  # redelivery read the workspace's rules again (2026-10-04 review).
  defp record_rule_inventories({:ok, receipts}, inputs) do
    for {input, %{status: :recorded, entry: entry}} <- Enum.zip(inputs, receipts) do
      _evidence = Projections.observe_rules(input, ref(entry))
      # The Standing rules card of the message's page reads it.
      broadcast_input_updated(entry)
    end

    {:ok, receipts}
  end

  defp record_rule_inventories(result, _inputs), do: result

  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(@ref_prefix <> id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{} = entry <- Repo.one(Entry.Query.by_id(id)) do
      {:ok, entry}
    else
      _other -> :error
    end
  end

  def fetch(_ref), do: :error

  # The pending input that currently keeps `entry` out of the claimable set, if
  # any. This is the same lane predicate the dispatcher claims by: an earlier
  # pending input in the same transport, conversation and execution mode, or
  # one whose routing lease is still live. It is a current fact about the
  # queue, not a history of what blocked the input earlier, and it says nothing
  # once the input has left the queue. Recording names the predecessor in the
  # saved transition; tests call this directly to check the lane rule.
  @doc false
  @spec fetch_queue_predecessor(Entry.t(), DateTime.t()) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def fetch_queue_predecessor(%Entry{status: :pending} = entry, %DateTime{} = now) do
    entry |> Entry.Query.queue_predecessor(now) |> Repo.fetch()
  end

  def fetch_queue_predecessor(%Entry{}, %DateTime{}), do: {:error, :not_found}

  @doc """
  Freezes one exact model-visible admission context for the current execution generation.

  Retries return the original snapshot. A changed snapshot cannot replace it until a
  confirmed terminal execution advances the generation.
  """
  @spec bind_context(String.t(), String.t(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def bind_context(input_ref, lease_ref, context) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         :ok <- valid_context(context) do
      fingerprint = CanonicalJSON.digest(context)

      Repo.transaction(fn -> bind_context_locked(id, lease_ref, context, fingerprint) end)
    end
  end

  @doc """
  Claims the oldest eligible input without waiting behind work another executor owns.

  Expired leases are eligible again. The opaque lease reference fences the later
  admission commit or retry update.
  """
  @spec claim_next(String.t(), DateTime.t(), pos_integer()) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, now, lease_seconds) do
    with :ok <- bounded_reference(worker_ref, :worker_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn ->
        now
        |> claimable()
        |> claim_entry(worker_ref, now, lease_seconds)
      end)
    end
  end

  @doc """
  Extends the current fenced lease without changing its owner or attempt count.

  Long Coop operations renew this lease while they are making progress so a
  second worker cannot reclaim healthy in-flight work.
  """
  @spec renew(String.t(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, Entry.t()} | {:error, term()}
  def renew(input_ref, lease_ref, now, lease_seconds) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(id, lease_ref, now, lease_seconds) end)
    end
  end

  @doc """
  Releases one failed claim for a later retry. Only the current lease holder can do this.
  """
  @spec defer(String.t(), String.t(), DateTime.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :same)
  end

  @doc """
  Releases a claim whose Coop operation or turn was still running when the
  claim's decision window closed.

  The next claim reattaches to the same operation keys. Waiting is not failing,
  so the claim is not counted against the input's retry attempts.
  """
  @spec wait(String.t(), String.t(), DateTime.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def wait(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :wait)
  end

  @doc """
  Releases a claim after a confirmed terminal Coop result and advances its operation keys.

  Ambiguous transport failures must use `defer/6` so they reconcile the same keys.
  """
  @spec defer_after_terminal(
          String.t(),
          String.t(),
          DateTime.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, Entry.t()} | {:error, term()}
  def defer_after_terminal(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :execution)
  end

  @doc """
  Releases a claim after a confirmed validation failure without abandoning its candidate.
  """
  @spec defer_after_validation(
          String.t(),
          String.t(),
          DateTime.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, Entry.t()} | {:error, term()}
  def defer_after_validation(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :validation)
  end

  @doc """
  Moves an input out of the automatic retry queue when safe replay is impossible.

  The stored error names the exact reconciliation, policy, or operator boundary.
  Confirmed terminal occurrences may advance their generation atomically with
  blocking; ambiguous outcomes must retain the same occurrence for reconciliation.
  """
  @spec block(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  @spec block(String.t(), String.t(), String.t(), String.t(), :same | :execution | :validation) ::
          {:ok, Entry.t()} | {:error, term()}
  def block(input_ref, lease_ref, error_code, error_detail, generation \\ :same) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail),
         :ok <- block_generation(generation) do
      Repo.transaction(fn ->
        block_locked(id, lease_ref, error_code, error_detail, generation)
      end)
    end
  end

  defp block_generation(generation) when generation in [:same, :execution, :validation], do: :ok
  defp block_generation(_), do: {:error, {:invalid_ingress_execution, :generation}}

  @doc """
  Rearms one exact operator-inspected blocked admission.

  Preserve the context and operation generations left by the blocked attempt.
  Ambiguous operations reconcile the same keys; confirmed terminal operations
  have already advanced their generation and may have cleared the old context.
  """
  @spec rearm(String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def rearm(input_ref) do
    with {:ok, id} <- input_id(input_ref) do
      Repo.transaction(fn -> rearm_locked(id) end)
    end
  end

  @doc """
  The oldest voice message still waiting for its transcript.
  `Ryker.Transcription.Worker` takes them in the order they arrived.
  """
  @spec fetch_waiting_for_transcript() :: {:ok, Entry.t()} | {:error, :not_found}
  def fetch_waiting_for_transcript do
    Entry.Query.awaiting_transcript()
    |> Entry.Query.ordered_by_oldest()
    |> Entry.Query.limit_to(1)
    |> Repo.fetch()
  end

  @doc """
  Fills in the words of a voice message that was recorded without them and
  lets routing take it; the announcement wakes routing. `results` holds each
  recording's transcription result by its artifact ref, and a recording with
  none reads as one Ryker could not transcribe.

  A message routing stopped waiting for is `:released` and keeps what it was
  routed with.
  """
  @spec transcribed(String.t(), %{String.t() => Transcription.result()}) ::
          {:ok, :transcribed | :released} | {:error, term()}
  def transcribed(input_ref, results) when is_map(results) do
    with {:ok, id} <- input_id(input_ref) do
      Repo.transaction(fn -> transcribed_locked(id, results) end)
    end
  end

  def transcribed(_input_ref, _results), do: {:error, {:invalid_ingress_transcript, :results}}

  defp transcribed_locked(id, results) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:ingress_transcript_failed, :input_not_found})

      %Entry{status: :pending, awaiting_transcript_until: %DateTime{}} = entry ->
        content =
          Transcription.settle(
            entry.content,
            &Map.get(results, &1["artifact_ref"], {:error, :failed})
          )

        entry
        |> settle_transcripts!(content)
        |> append_transition!(:transcribed, detail: unavailable_note(content))

        :transcribed

      %Entry{} ->
        :released
    end
  end

  # Routing's wait is over: every recording still without words reads as one
  # Ryker could not transcribe, in the claim that takes the message.
  defp release_transcript_wait(%Entry{awaiting_transcript_until: nil} = entry, _now), do: entry

  defp release_transcript_wait(%Entry{} = entry, now) do
    content = Transcription.settle(entry.content, fn _file -> {:error, :timeout} end)
    released = settle_transcripts!(entry, content)

    append_transition!(released, :transcript_timed_out,
      occurred_at: now,
      eligible_at: entry.awaiting_transcript_until,
      detail: unavailable_note(content)
    )

    released
  end

  defp settle_transcripts!(entry, content) do
    changeset = Entry.Changeset.settle_transcripts(entry, content)

    case Repo.update(changeset) do
      {:ok, settled} ->
        settled

      {:error, changeset} ->
        Repo.rollback({:persistence_failed, :ingress_transcript, changeset.errors})
    end
  end

  # Why a recording has no words, for the message's queue history.
  defp unavailable_note(%{"files" => files}) when is_list(files) do
    case for(%{"transcript_unavailable" => note} <- files, do: note) do
      [] -> nil
      notes -> notes |> Enum.uniq() |> Enum.join("; ") |> String.slice(0, 1_000)
    end
  end

  defp unavailable_note(_content), do: nil

  defp defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, generation) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- non_negative_integer(delay_ms, :delay_ms),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        defer_locked(id, lease_ref, now, delay_ms, error_code, error_detail, generation)
      end)
    end
  end

  @spec ref(Entry.t()) :: String.t()
  def ref(%Entry{id: id}) when is_binary(id), do: @ref_prefix <> id

  defp claim_entry(nil, _worker_ref, _now, _lease_seconds), do: nil

  defp claim_entry(entry, worker_ref, now, lease_seconds) do
    entry = release_transcript_wait(entry, now)
    lease_ref = "ingress-lease:#{Ecto.UUID.generate()}"

    attributes = %{
      attempt_count: entry.attempt_count + 1,
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: DateTime.add(now, lease_seconds, :second),
      lease_owner: worker_ref,
      lease_ref: lease_ref,
      next_attempt_at: nil
    }

    changeset = Entry.Changeset.claim(entry, attributes)

    case Repo.update(changeset) do
      {:ok, claimed} ->
        append_transition!(claimed, if(entry.attempt_count > 0, do: :reclaimed, else: :claimed),
          occurred_at: now,
          attempt: claimed.attempt_count,
          owner_ref: worker_ref
        )

        %{entry: claimed, lease_ref: lease_ref}

      {:error, changeset} ->
        Repo.rollback({:persistence_failed, :ingress_claim, changeset.errors})
    end
  end

  defp claimable(now) do
    now
    |> Entry.Query.claimable_at()
    |> Entry.Query.ordered_by_oldest()
    |> Entry.Query.limit_to(1)
    |> Entry.Query.lock_next_free()
    |> Repo.one()
  end

  @doc """
  The earliest moment after `since` at which a pending input becomes claimable
  by the clock alone: its retry's backoff ends, the lease of a claim nobody
  renewed runs out, or routing stops waiting for a voice message's
  transcript. Nil when no pending input waits on the clock.

  Admission sleeps until then; everything else that makes an input claimable
  is a change this module announces.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    since
    |> Entry.Query.select_next_due_after()
    |> Repo.one()
    |> UTCDateTime.earliest()
  end

  defp lock_entry(id),
    do: id |> Entry.Query.by_id() |> Entry.Query.lock_for_update() |> Repo.one()

  defp renew_locked(id, lease_ref, now, lease_seconds) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:ingress_renew_failed, :input_not_found})

      %Entry{status: :pending, lease_ref: ^lease_ref} = entry ->
        lease_expires_at = Lease.renewed(entry.lease_expires_at, now, lease_seconds)
        changeset = Entry.Changeset.renew(entry, lease_expires_at)

        case Repo.update(changeset) do
          {:ok, renewed} ->
            renewed

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_renew, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_renew_failed, :lease_lost})
    end
  end

  defp defer_locked(id, lease_ref, now, delay_ms, error_code, error_detail, generation) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:ingress_retry_failed, :input_not_found})

      %Entry{status: status} = entry when status in [:decided, :superseded] ->
        entry

      %Entry{lease_ref: ^lease_ref} = entry ->
        {execution_generation, validation_generation} =
          next_generations(entry, generation)

        attributes =
          %{
            attempt_count: spent_attempts(entry, generation),
            execution_generation: execution_generation,
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, delay_ms, :millisecond),
            validation_generation: validation_generation
          }
          |> maybe_clear_context(generation)

        changeset = Entry.Changeset.defer(entry, attributes)

        case Repo.update(changeset) do
          {:ok, deferred} ->
            append_transition!(deferred, :retry_scheduled,
              occurred_at: now,
              attempt: entry.attempt_count,
              eligible_at: deferred.next_attempt_at,
              error_code: error_code,
              detail: error_detail
            )

            deferred

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_retry, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_retry_failed, :lease_lost})
    end
  end

  defp next_generations(entry, :execution), do: {entry.execution_generation + 1, 1}

  defp next_generations(entry, :validation),
    do: {entry.execution_generation, entry.validation_generation + 1}

  defp next_generations(entry, generation) when generation in [:same, :wait],
    do: {entry.execution_generation, entry.validation_generation}

  # The claim counted an attempt when it took the lease; a wait gives it back.
  defp spent_attempts(entry, :wait), do: entry.attempt_count - 1
  defp spent_attempts(entry, _generation), do: entry.attempt_count

  defp maybe_clear_context(attributes, :execution) do
    Map.merge(attributes, %{admission_context: nil, admission_context_fingerprint: nil})
  end

  defp maybe_clear_context(attributes, _generation), do: attributes

  defp bind_context_locked(id, lease_ref, context, fingerprint) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:admission_context_failed, :input_not_found})

      %Entry{status: :pending, lease_ref: ^lease_ref, admission_context: nil} = entry ->
        changeset = Entry.Changeset.bind_context(entry, context, fingerprint)

        case Repo.update(changeset) do
          {:ok, bound} ->
            broadcast_input_updated(bound)
            bound

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :admission_context, changeset.errors})
        end

      %Entry{
        status: :pending,
        lease_ref: ^lease_ref,
        admission_context_fingerprint: ^fingerprint
      } = entry ->
        entry

      %Entry{status: :pending, lease_ref: ^lease_ref} ->
        Repo.rollback({:admission_context_failed, :snapshot_conflict})

      %Entry{} ->
        Repo.rollback({:admission_context_failed, :lease_lost})
    end
  end

  defp valid_context(context) do
    case CanonicalJSON.validate(context, max_bytes: 98_304) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  defp block_locked(id, lease_ref, error_code, error_detail, generation) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:ingress_block_failed, :input_not_found})

      %Entry{status: status} = entry when status in [:blocked, :decided, :superseded] ->
        entry

      %Entry{status: :pending, lease_ref: ^lease_ref} = entry ->
        {execution_generation, validation_generation} = next_generations(entry, generation)

        attributes =
          %{
            execution_generation: execution_generation,
            validation_generation: validation_generation,
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: :blocked
          }
          |> maybe_clear_context(generation)

        changeset = Entry.Changeset.block(entry, attributes)

        case Repo.update(changeset) do
          {:ok, blocked} ->
            append_transition!(blocked, :blocked,
              attempt: entry.attempt_count,
              error_code: error_code,
              detail: error_detail
            )

            blocked

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_block, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_block_failed, :lease_lost})
    end
  end

  defp rearm_locked(id) do
    case lock_entry(id) do
      nil ->
        Repo.rollback({:ingress_rearm_failed, :input_not_found})

      %Entry{status: :blocked} = entry ->
        changeset = Entry.Changeset.rearm(entry)

        case Repo.update(changeset) do
          {:ok, rearmed} ->
            append_transition!(rearmed, :rearmed)
            rearmed

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_rearm, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_rearm_failed, :input_not_blocked})
    end
  end

  defp record_locked(input, settings) do
    dedupe_key = Input.dedupe_key(input)

    with {:ok, receipt} <- admit(input, load(dedupe_key), settings),
         :ok <- attach_artifacts(input, receipt),
         :ok <- revoke_answer_memory(receipt),
         :ok <- receive_observation(receipt),
         :ok <- take_back(receipt),
         :ok <- Projections.observe(input, ref(receipt.entry)) do
      {:ok, receipt}
    end
  end

  # Somebody deleting their message, or editing it to say something else,
  # takes its words back as the change is recorded
  # (`Ryker.RoutingExamples.takes_back_words?/1`): the routing examples kept
  # for training that quote it are erased, what it taught about its author
  # forgotten (`Ryker.People`), and the cases built from it withdrawn
  # (`Ryker.Memories.Cases`). Erasing takes the lock every
  # forgetting takes, so it comes after the message's note is written:
  # forgetting what was learned from a message holds its note and then takes
  # that lock, and the other order deadlocked with it.
  defp take_back(%{status: :recorded, entry: %Entry{event_kind: kind} = entry})
       when kind in [:edit, :delete] do
    if RoutingExamples.takes_back_words?(entry) do
      :ok = RoutingExamples.forget_message_in_transaction(entry)
      :ok = People.forget_message_in_transaction(entry.native_input_id)
      Memories.Cases.withdraw_message_in_transaction(entry.native_input_id)
    else
      :ok
    end
  end

  defp take_back(_receipt), do: :ok

  # Only an edit that took the words back revokes an answer saved from them: a
  # link preview arriving as an edit forgot the answer (2026-10-04 review).
  defp revoke_answer_memory(%{status: :recorded, entry: entry}) do
    if RoutingExamples.takes_back_words?(entry),
      do: Memories.revoke_answer_source_in_transaction(entry),
      else: :ok
  end

  defp revoke_answer_memory(_receipt), do: :ok

  defp receive_observation(%{status: :recorded, entry: entry}),
    do: Learning.Observations.receive_in_transaction(entry)

  defp receive_observation(_receipt), do: :ok

  defp record_batch_locked(inputs, settings) do
    case lock_batch(inputs, settings) do
      :ok -> Enum.map(inputs, &record_one_locked!(&1, settings))
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_one_locked!(input, settings) do
    case record_locked(input, settings) do
      {:ok, receipt} -> receipt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp attach_artifacts(_input, %{status: :duplicate, entry: %Entry{operational_pruned_at: at}})
       when not is_nil(at),
       do: :ok

  defp attach_artifacts(input, %{entry: %Entry{id: input_id}}),
    do: Artifacts.References.attach_input(input, input_id)

  # One message can reach Ryker as several source events: Slack sends a
  # message that mentions Ryker as app_mention and as a channel message, under
  # different event ids. A source that says so (`one_input_per_revision`)
  # makes a later event for a revision already recorded the same input.
  defp admit(input, nil, %{one_input_per_revision: true} = settings) do
    case same_revision(input) do
      %Entry{} = entry -> {:ok, %{entry: entry, status: :duplicate}}
      nil -> reconcile_record(input, nil, settings)
    end
  end

  defp admit(input, entry, settings), do: reconcile_record(input, entry, settings)

  defp same_revision(input) do
    input |> Entry.Query.same_revision() |> Entry.Query.lock_for_update() |> Repo.one()
  end

  defp reconcile_record(input, nil, %{revision_ties: :exact} = settings),
    do: reconcile(input, nil, settings)

  defp reconcile_record(
         input,
         nil,
         %{revision_ties: :receipt_order} = settings
       ) do
    with {:ok, input} <- allocate_bounded_source_revision(input) do
      reconcile(input, nil, settings)
    end
  end

  defp reconcile_record(
         input,
         nil,
         %{revision_ties: :receipt_order_unbounded} = settings
       ) do
    with {:ok, input} <- allocate_unbounded_source_revision(input) do
      reconcile(input, nil, settings)
    end
  end

  defp reconcile_record(input, %Entry{} = entry, %{revision_ties: revision_ties})
       when revision_ties in [:receipt_order, :receipt_order_unbounded],
       do: reconcile(%{input | revision: entry.revision}, entry, entry.execution_mode)

  defp reconcile_record(input, %Entry{} = entry, %{revision_ties: :exact}),
    do: reconcile(input, entry, entry.execution_mode)

  defp allocate_bounded_source_revision(input) do
    base = input.revision
    maximum = base + 999

    latest =
      input
      |> Entry.Query.revisions_of()
      |> Entry.Query.revision_between(base, maximum)
      |> Entry.Query.select_latest_revision()
      |> Repo.one()

    cond do
      is_nil(latest) -> {:ok, input}
      latest < maximum -> {:ok, %{input | revision: latest + 1}}
      true -> {:error, {:source_revision_overflow, input.native_input_id, base}}
    end
  end

  defp allocate_unbounded_source_revision(input) do
    latest =
      input |> Entry.Query.revisions_of() |> Entry.Query.select_latest_revision() |> Repo.one()

    cond do
      is_nil(latest) -> {:ok, input}
      latest < @maximum_revision -> {:ok, %{input | revision: latest + 1}}
      true -> {:error, {:source_revision_overflow, input.native_input_id, input.revision}}
    end
  end

  defp lock(dedupe_key) do
    case AdvisoryLock.hold(dedupe_key) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp lock_batch(inputs, settings) do
    inputs
    |> Enum.flat_map(fn input ->
      keys = [Input.dedupe_key(input)]

      if settings.revision_ties in [:receipt_order, :receipt_order_unbounded] or
           settings.one_input_per_revision,
         do: [revision_lock(input) | keys],
         else: keys
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case lock(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  # The lock every event of one source item takes, so two copies of one
  # message cannot both be recorded (InboxConcurrencyTest holds it).
  def revision_lock(input) do
    "ingress-revision:" <>
      CanonicalJSON.digest([input.source.kind, input.source.ref, input.native_input_id])
  end

  defp load(dedupe_key) do
    dedupe_key |> Entry.Query.by_dedupe_key() |> Entry.Query.lock_for_update() |> Repo.one()
  end

  defp reconcile(input, nil, settings) do
    # Work acceptance uses the database clock. Mixing that with application
    # timestamps can place a follow-up before the answer it follows in the Lab.
    now = Repo.now!()

    input
    |> Entry.Changeset.insert(
      Repo.generate_id(),
      settings.execution_mode,
      settings.work_profile,
      settings.slack_addressing,
      source_envelope: settings.source_envelope,
      engagement_receipt: settings.engagement_receipt
    )
    |> Ecto.Changeset.change(
      inserted_at: now,
      updated_at: now,
      awaiting_transcript_until: transcript_deadline(input, now)
    )
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        append_transition!(entry, :saved, occurred_at: entry.inserted_at)

        case fetch_queue_predecessor(entry, entry.inserted_at) do
          {:ok, predecessor} ->
            append_transition!(entry, :waiting_predecessor,
              occurred_at: entry.inserted_at,
              predecessor_input_id: predecessor.id,
              detail: predecessor_summary(predecessor)
            )

          {:error, :not_found} ->
            :ok
        end

        {:ok, %{entry: entry, status: :recorded}}

      {:error, changeset} ->
        {:error, {:persistence_failed, :ingress_input, changeset.errors}}
    end
  end

  defp reconcile(input, %Entry{} = entry, _execution_mode) do
    submitted = Input.fingerprint(input)

    if entry.event_fingerprint == submitted do
      {:ok, %{entry: entry, status: :duplicate}}
    else
      {:error,
       {:input_conflict,
        dedupe_key: entry.dedupe_key,
        stored_fingerprint: entry.event_fingerprint,
        submitted_fingerprint: submitted}}
    end
  end

  # A voice message recorded before its words holds routing off until then.
  defp transcript_deadline(input, now) do
    if Transcription.pending?(input.content),
      do: DateTime.add(now, Transcription.wait_seconds(), :second)
  end

  @doc false
  def record_transition_in_transaction(%Entry{} = entry, kind, attributes \\ [])
      when is_list(attributes) do
    append_transition!(entry, kind, attributes)
    :ok
  end

  defp append_transition!(entry, kind, attributes \\ []) do
    sequence =
      entry.id
      |> InputCustodyTransition.Query.by_input_id()
      |> InputCustodyTransition.Query.select_last_sequence()
      |> Repo.one()
      |> Kernel.+(1)

    occurred_at = Keyword.get_lazy(attributes, :occurred_at, &Repo.now!/0)

    fields = %{
      input_id: entry.id,
      sequence: sequence,
      kind: kind,
      occurred_at: occurred_at,
      generation: entry.execution_generation,
      attempt: Keyword.get(attributes, :attempt, entry.attempt_count),
      predecessor_input_id: Keyword.get(attributes, :predecessor_input_id),
      superseding_input_id: Keyword.get(attributes, :superseding_input_id),
      owner_ref: Keyword.get(attributes, :owner_ref),
      eligible_at: Keyword.get(attributes, :eligible_at),
      error_code: Keyword.get(attributes, :error_code),
      detail: Keyword.get(attributes, :detail)
    }

    %InputCustodyTransition{}
    |> Ecto.Changeset.change(fields)
    |> Repo.insert()
    |> case do
      {:ok, transition} ->
        broadcast_input_updated(entry)
        transition

      {:error, changeset} ->
        Repo.rollback({:persistence_failed, :input_custody_transition, changeset.errors})
    end
  end

  # A message with no words of its own, such as a file share, names nothing:
  # the transition refuses an empty note, and refusing it refused the message
  # waiting behind it.
  defp predecessor_summary(%Entry{content: %{"text" => text}}) when is_binary(text) do
    case InspectionRedactor.artifact(text, max_bytes: 120).text do
      summary when is_binary(summary) -> if String.trim(summary) == "", do: nil, else: summary
      _none -> nil
    end
  end

  defp predecessor_summary(%Entry{}), do: nil

  defp prepare_inputs(inputs)
       when is_list(inputs) and inputs != [] and length(inputs) <= @maximum_record_batch do
    inputs
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, prepared} ->
      case Input.prepare(input) do
        {:ok, input} -> {:cont, {:ok, [input | prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_inputs(_inputs), do: {:error, {:invalid_ingress_execution, :inputs}}

  defp input_id(@ref_prefix <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_ingress_execution, :input_ref}}
    end
  end

  defp input_id(_input_ref), do: {:error, {:invalid_ingress_execution, :input_ref}}

  defp utc_datetime(%DateTime{} = value) do
    case UTCDateTime.exact(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_ingress_execution, :now}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_ingress_execution, :now}}

  defp bounded_reference(value, field), do: bounded_text(value, 1_024, field)

  defp bounded_text(value, maximum, field),
    do: Reference.check(value, field, :invalid_ingress_execution, maximum)

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp positive_integer(_value, field),
    do: {:error, {:invalid_ingress_execution, field}}

  defp record_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) --
           [
             :execution_mode,
             :one_input_per_revision,
             :revision_ties,
             :work_profile,
             :slack_audience,
             :slack_bot_user_ref,
             :source_envelope,
             :engagement_receipt
           ] ==
           [] do
      revision_ties = Keyword.get(options, :revision_ties, :exact)
      one_input_per_revision = Keyword.get(options, :one_input_per_revision, false)
      execution_mode = Keyword.get(options, :execution_mode, :live)
      work_profile = Keyword.get(options, :work_profile)
      source_envelope = Keyword.get(options, :source_envelope)
      engagement_receipt = Keyword.get(options, :engagement_receipt)

      with true <- revision_ties in [:exact, :receipt_order, :receipt_order_unbounded],
           true <- is_boolean(one_input_per_revision),
           true <- execution_mode in [:live, :shadow],
           true <- is_nil(source_envelope) or is_map(source_envelope),
           true <- is_nil(engagement_receipt) or is_map(engagement_receipt),
           {:ok, work_profile} <- WorkProfile.prepare(work_profile),
           {:ok, slack_addressing} <- slack_addressing_options(options) do
        {:ok,
         %{
           execution_mode: execution_mode,
           one_input_per_revision: one_input_per_revision,
           revision_ties: revision_ties,
           slack_addressing: slack_addressing,
           source_envelope: source_envelope,
           engagement_receipt: engagement_receipt,
           work_profile: work_profile
         }}
      else
        false -> {:error, {:invalid_ingress_execution, :record_options}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_ingress_execution, :record_options}}
    end
  end

  defp record_options(_options), do: {:error, {:invalid_ingress_execution, :record_options}}

  defp slack_addressing_options(options) do
    audience = Keyword.get(options, :slack_audience)
    bot_user_ref = Keyword.get(options, :slack_bot_user_ref)

    if (is_nil(audience) and is_nil(bot_user_ref)) or
         (audience in [:ambient, :direct, :mention] and Slack.id?(bot_user_ref)) do
      {:ok, %{audience: audience, bot_user_ref: bot_user_ref}}
    else
      {:error, {:invalid_ingress_execution, :slack_addressing}}
    end
  end

  defp slack_addressing_sources(_inputs, %{audience: nil, bot_user_ref: nil}), do: :ok

  defp slack_addressing_sources(inputs, _addressing) do
    if Enum.all?(inputs, &(&1.source.kind == "slack")),
      do: :ok,
      else: {:error, {:invalid_ingress_execution, :slack_addressing}}
  end

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(_value, field),
    do: {:error, {:invalid_ingress_execution, field}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to every message Ryker receives: `{:input_updated,
  input_id}` once a message is recorded, claimed for routing, retried,
  blocked, rearmed, routed or superseded, or its routing makes progress, and
  that change has committed.
  """
  def subscribe_inputs, do: Ryker.PubSub.subscribe(inputs_topic())

  def unsubscribe_inputs, do: Ryker.PubSub.unsubscribe(inputs_topic())

  @doc """
  Subscribes the caller to one message's changes (`{:input_updated,
  input_id}`), for the page that shows that message alone.
  """
  def subscribe_input(input_id), do: Ryker.PubSub.subscribe(input_topic(input_id))

  def unsubscribe_input(input_id), do: Ryker.PubSub.unsubscribe(input_topic(input_id))

  @doc """
  Internal — announces, after the outermost commit, that a message or its
  routing changed, together with the conversation it arrived in and the
  request that took it, if one has. Takes the entry, or its id when the caller
  holds only that: what the announcement names is then read after the commit.
  The same message announced several times in one transaction is announced
  once.
  """
  @spec broadcast_input_updated(Entry.t() | Ecto.UUID.t()) :: :ok
  def broadcast_input_updated(%Entry{id: id} = entry) when is_binary(id) do
    Episodes.broadcast_conversation_updated(
      entry.destination_transport,
      entry.destination_conversation_ref
    )

    Episodes.broadcast_episode_updated(entry.episode_id)
    Repo.after_commit(fn -> broadcast_committed_input(id) end)
  end

  def broadcast_input_updated(input_id) when is_binary(input_id) do
    Repo.after_commit(fn ->
      fields =
        input_id |> Entry.Query.by_id() |> Entry.Query.select_broadcast_fields() |> Repo.one()

      case fields do
        %Entry{} = entry -> broadcast_input_updated(entry)
        nil -> broadcast_committed_input(input_id)
      end
    end)
  end

  defp broadcast_committed_input(input_id) do
    Ryker.PubSub.broadcast(input_topic(input_id), {:input_updated, input_id})
    Ryker.PubSub.broadcast(inputs_topic(), {:input_updated, input_id})
  end

  defp inputs_topic, do: "inputs"
  defp input_topic(input_id), do: "input:#{input_id}"
end
