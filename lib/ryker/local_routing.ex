defmodule Ryker.LocalRouting do
  @moduledoc """
  A small self-hosted routing model, tried beside the provider model (Andrew,
  2026-09-27: "build/fine-tune our own super-efficient self hosted model later
  ... So we can do more on free routing steps more accurately and fallback to
  large provider models only when needed").

  Phase 1 is shadow mode, and it only measures. With Settings › Models ›
  Local routing model at `shadow`, every routing decision Ryker accepts from
  the provider queues one comparison in the same transaction
  (`queue_in_transaction/1`). One lane (`Ryker.LocalRouting.Worker`) later
  sends the local model the exact prompt the provider answered, with
  routing's contract as structured output (`Ryker.LocalRouting.Client`),
  puts the answer through routing's own checks and compares it with the kept
  decision (`Ryker.LocalRouting.Verdict`), and records it beside what the
  provider's call cost and took. Usage & cost reads them back (`usage/2`).

  Routing never waits for any of it and never reads it: the decision is saved
  before a comparison exists, a comparison only reads what routing kept, and
  the lane asks one question at a time under a firm timeout, retrying an
  unreachable model with backoff before it gives up.

  Phase 2, the cascade, would ask the local model first and the provider only
  when the local answer is invalid, unsure, or for work that needs it; it is
  not built.

  A person forgetting wins. Each comparison records what its prompt quotes
  when it is queued, as a routing example does. Deleting a message in Slack
  or editing its words, forgetting what was learned from one or a learned
  topic, or deleting a Slack channel erases every comparison whose prompt
  quotes it, the local model's answer with it, in the transaction that
  forgets it (`Ryker.RoutingExamples`, which every forgetting calls). The
  lane checks again just before it sends, by the test a routing example's
  copy passes (`Ryker.RoutingExamples.quotes_forgotten?/1`) and under the
  lock that copy holds, and erases one that quotes anything forgotten since,
  unasked. A forgetting still committing when the check runs, which may have
  looked for comparisons before routing's commit made this one visible, is
  waited for and seen.

  Every comparison queued, settled or erased is announced after its commit
  (`subscribe_comparisons/0`).
  """
  alias Ryker.Accounting
  alias Ryker.Admission
  alias Ryker.Ingress
  alias Ryker.Learning
  alias Ryker.LocalRouting.{Client, Comparison, Verdict}
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Settings
  alias Ryker.UTCDateTime

  @topic "local_routing"
  @answer_bytes 16_384
  @error_bytes 1_000
  # An attempt stays fenced this long past its firm timeout, so a lane that
  # stopped mid-call leaves it to be asked again rather than asked twice.
  @fence_grace_ms 30_000

  @type setting :: %{mode: :off | :shadow, endpoint: String.t() | nil, model: String.t() | nil}

  @doc "The saved setting; off before an installation has settings."
  @spec setting() :: setting()
  def setting do
    Repo.one(Settings.Work.Query.select_local_routing()) ||
      %{mode: :off, endpoint: nil, model: nil}
  end

  @doc """
  Queues one comparison for a routing decision just accepted, inside the
  transaction that saves it (`Ryker.Admission`), when the local routing model
  is in shadow and a model answered a prompt for it. A decision the host made
  without a model, such as a deleted message's, has nothing to compare.
  """
  @spec queue_in_transaction(Ingress.Inbox.Entry.t()) :: :ok
  def queue_in_transaction(%Ingress.Inbox.Entry{status: :decided} = entry) do
    with %{mode: :shadow, model: model} <- setting(),
         true <- prompted?(entry) do
      now = DateTime.utc_now()
      quoted = RoutingExamples.quoted_keys(entry)

      Repo.insert_all(
        Comparison,
        [
          %{
            id: Repo.generate_id(),
            input_id: entry.id,
            generation: entry.execution_generation,
            execution_mode: entry.execution_mode,
            status: :pending,
            attempt_count: 0,
            local_model: model,
            differing_fields: [],
            source_identity: Learning.Observations.source_identity(entry),
            message_keys: quoted.keys,
            conversation_refs: quoted.conversations,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:input_id, :generation]
      )

      broadcast(entry.id)
    end

    :ok
  end

  def queue_in_transaction(%Ingress.Inbox.Entry{}), do: :ok

  defp prompted?(entry) do
    entry.id
    |> Admission.Attempt.Query.by_generation(entry.execution_generation)
    |> Admission.Attempt.Query.prompted()
    |> Repo.exists?()
  end

  @doc """
  Asks the local model the next comparison due, and records what came of it.

  `options` name the `endpoint` and `model`, the firm `timeout_ms`, how many
  attempts a comparison gets (`max_attempts`) and the backoff between them
  (`retry_base_seconds`, fourfold each time up to `retry_max_seconds`), and
  optionally the clock (`now`) and the Finch pool. `:idle` when nothing is due.
  """
  @spec run_next(keyword()) :: :idle | {:ran, Comparison.t()}
  def run_next(options) when is_list(options) do
    options =
      options
      |> Map.new()
      |> Map.put_new(:now, &DateTime.utc_now/0)
      |> Map.put_new(:finch, Ryker.CoopFinch)

    case claim(options) do
      nil -> :idle
      comparison -> {:ran, run(comparison, options)}
    end
  end

  # The next due comparison, taken for one attempt: its count goes up and it
  # is fenced for the length of the call.
  defp claim(options) do
    now = options.now.()
    fence = DateTime.add(now, options.timeout_ms + @fence_grace_ms, :millisecond)

    {:ok, claimed} =
      Repo.transaction(fn ->
        now
        |> Comparison.Query.due_at()
        |> Comparison.Query.ordered_by_oldest()
        |> Comparison.Query.limit_to(1)
        |> Comparison.Query.lock_next_free()
        |> Repo.one()
        |> case do
          nil ->
            nil

          comparison ->
            comparison
            |> Ecto.Changeset.change(
              attempt_count: comparison.attempt_count + 1,
              next_attempt_at: fence,
              local_model: options.model,
              updated_at: now
            )
            |> Repo.update!()
        end
      end)

    claimed
  end

  # An attempt that never finished, because the lane stopped mid-call, still
  # counts: a comparison that stops the lane every time is given up too.
  defp run(%Comparison{attempt_count: count} = comparison, %{max_attempts: max} = options)
       when count > max,
       do: settle(comparison, failed("#{max} attempts never finished"), options)

  defp run(comparison, options) do
    case checked_material(comparison) do
      {:ok, material} ->
        case Client.ask(options, material.prompt, material.schema) do
          {:ok, answer} -> settle(comparison, compared(comparison, material, answer), options)
          {:error, {:retry, why}} -> settle(comparison, retry(comparison, why, options), options)
          {:error, {:refused, why}} -> settle(comparison, failed(why), options)
        end

      :forgotten ->
        comparison

      :gone ->
        settle(comparison, failed("the routing prompt or its context is no longer kept"), options)
    end
  end

  # What is sent is read under the lock a routing example's copy holds
  # (`Ryker.RoutingExamples.copy_lock_in_transaction/0`), and a comparison
  # whose prompt quotes anything forgotten is erased there, unasked. A
  # forgetting that looked for comparisons before routing's commit made this
  # one visible holds that lock until it commits, so the check waits for it
  # and sees what it removed; one that begins after the check finds this
  # comparison and erases it, with any answer saved to it.
  defp checked_material(comparison) do
    {:ok, checked} =
      Repo.transaction(fn ->
        :ok = RoutingExamples.copy_lock_in_transaction()

        with :forgotten <- material(comparison) do
          :ok = erase(Comparison.Query.by_id(comparison.id))
          :forgotten
        end
      end)

    checked
  end

  # What routing kept: the prompt and contract the provider answered, the
  # decision it accepted, and the frozen context that decision was checked in.
  # Read just before it is sent, and never sent once a person forgot or
  # deleted anything it quotes.
  defp material(comparison) do
    with %Ingress.Inbox.Entry{status: :decided, operational_pruned_at: nil} = entry <-
           Repo.one(Ingress.Inbox.Entry.Query.by_id(comparison.input_id)),
         %{"action" => _action} = provider <- entry.decision_document,
         %Admission.Attempt{operational_pruned_at: nil, submission: %{} = submission} <-
           Repo.one(Admission.Attempt.Query.by_generation(entry.id, comparison.generation)),
         prompt when is_binary(prompt) <- submission["prompt"],
         schema when is_map(schema) <- submission["output_schema"],
         {:ok, context} <- Admission.decided_context(entry),
         :kept <- kept(entry) do
      {:ok, %{context: context, prompt: prompt, provider: provider, schema: schema}}
    else
      :forgotten -> :forgotten
      _gone -> :gone
    end
  end

  defp kept(entry), do: if(RoutingExamples.quotes_forgotten?(entry), do: :forgotten, else: :kept)

  defp compared(comparison, material, answer) do
    verdict =
      Verdict.judge(answer.content, answer.finish_reason, material.context, material.provider)

    provider = provider_call(comparison)

    %{
      status: :compared,
      valid: verdict.valid,
      agrees: verdict.agrees,
      differing_fields: verdict.differing_fields,
      invalid_reason: verdict.invalid_reason,
      local_answer: text(answer.content, @answer_bytes),
      local_ms: answer.ms,
      local_input_tokens: answer.input_tokens,
      local_output_tokens: answer.output_tokens,
      provider_cost_usd: provider.cost,
      provider_cost_estimated: provider.estimated,
      provider_ms: provider.ms,
      next_attempt_at: nil,
      last_error: nil,
      compared_at: :now
    }
  end

  defp retry(%Comparison{attempt_count: count}, why, %{max_attempts: max}) when count >= max,
    do: failed(why)

  defp retry(%Comparison{attempt_count: count}, why, options) do
    delay = min(options.retry_base_seconds * 4 ** (count - 1), options.retry_max_seconds)
    %{status: :pending, next_attempt_at: {:after, delay}, last_error: text(why, @error_bytes)}
  end

  defp failed(why),
    do: %{status: :failed, next_attempt_at: nil, last_error: text(why, @error_bytes)}

  # What the provider's call for the same message cost, as the Usage ledger
  # prices it (its reported cost, or the saved price's estimate), and how
  # long it spent in the model.
  defp provider_call(comparison) do
    generation = Integer.to_string(comparison.generation)

    nil
    |> Accounting.Execution.Query.ledger("all")
    |> Accounting.Execution.Query.admission_call(comparison.input_id, generation)
    |> Repo.one()
    |> case do
      %{recorded: true, reported: %Decimal{} = cost} = call ->
        %{cost: cost, estimated: false, ms: call.ms}

      %{estimate: %Decimal{} = estimate} = call ->
        %{cost: estimate, estimated: true, ms: call.ms}

      %{} = call ->
        %{cost: nil, estimated: nil, ms: call.ms}

      nil ->
        %{cost: nil, estimated: nil, ms: nil}
    end
  end

  # Saves how the attempt ended, unless retention removed the comparison
  # with its message meanwhile.
  defp settle(comparison, changes, options) do
    now = options.now.()

    changes =
      changes
      |> Map.update(:next_attempt_at, nil, fn
        {:after, seconds} -> DateTime.add(now, seconds)
        other -> other
      end)
      |> Map.update(:compared_at, nil, fn :now -> now end)
      |> Map.put(:updated_at, now)

    changeset = Ecto.Changeset.change(comparison, changes)

    case Repo.update(changeset, stale_error_field: :id) do
      {:ok, settled} ->
        broadcast(settled.input_id)
        settled

      {:error, _gone} ->
        comparison
    end
  end

  # Stored text is valid UTF-8 without NUL, cut at a character boundary.
  defp text(nil, _bytes), do: nil

  defp text(value, bytes) do
    value = value |> String.replace_invalid("?") |> String.replace(<<0>>, "")

    if byte_size(value) <= bytes do
      value
    else
      case :unicode.characters_to_binary(binary_part(value, 0, bytes)) do
        whole when is_binary(whole) -> whole
        {_partial, whole, _rest} -> whole
      end
    end
  end

  @doc """
  The earliest moment after `since` at which a pending comparison falls due
  by the clock alone: its retry's backoff ends, or the fence of an attempt
  that never finished runs out. Nil when none waits on the clock.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    since
    |> Comparison.Query.select_next_due_after()
    |> Repo.one()
    |> List.wrap()
    |> UTCDateTime.earliest()
  end

  # -- Forgetting --------------------------------------------------------------

  @doc """
  Erases the comparisons whose prompt quotes what a person just forgot,
  deleted or edited, waiting, compared or given up, inside the transaction
  that forgets it (`Ryker.RoutingExamples`): `identities` name the messages
  themselves (`Ryker.Learning.Observations.source_identity/1`), and `keys`
  every message and topic, as a routing prompt quotes them
  (`Ryker.RoutingExamples.quoted_keys/1`).
  """
  @spec forget_in_transaction([String.t()], [String.t()]) :: :ok
  def forget_in_transaction(identities, keys) when is_list(identities) and is_list(keys) do
    identities |> Comparison.Query.from_sources_or_messages(keys) |> erase()
  end

  @doc """
  Erases the comparisons from a conversation that was deleted, or whose
  prompt quotes it, inside the transaction that removes what Ryker kept of
  it.
  """
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    conversation_ref |> Comparison.Query.quoting_conversation() |> erase()
  end

  # An erased comparison is gone, never asked and never counted.
  defp erase(query) do
    {_count, input_ids} = query |> Comparison.Query.select_input_ids() |> Repo.delete_all()
    input_ids |> Enum.uniq() |> Enum.each(&broadcast/1)
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Delivers `{:local_routing_updated, input_id}` after a comparison for that
  message is queued, settled or erased, and has committed.
  """
  @spec subscribe_comparisons() :: :ok | {:error, term()}
  def subscribe_comparisons, do: Ryker.PubSub.subscribe(@topic)

  @doc "Stops the announcements `subscribe_comparisons/0` started."
  def unsubscribe_comparisons, do: Ryker.PubSub.unsubscribe(@topic)

  defp broadcast(input_id) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(@topic, {:local_routing_updated, input_id})
    end)
  end
end
