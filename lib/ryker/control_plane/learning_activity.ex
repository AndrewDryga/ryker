defmodule Ryker.ControlPlane.LearningActivity do
  @moduledoc """
  The Learning page's read model: whether background learning runs here, the
  messages it has not read yet, the batches that need a person, what it did
  recently, the handovers that could not be saved, and one batch with its
  frozen attempts, each linked to its learning card on the Timeline. Read-only.
  """
  import Ecto.Query

  alias Ryker.ControlPlane.{
    Activity,
    ConversationMemory,
    ConversationProjection,
    LearningRequests,
    PagedRelation
  }

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning.{Batch, Batches, InputMembership, Runtime}
  alias Ryker.Learning.LearningRun
  alias Ryker.Repo
  alias Ryker.Settings.Installation
  alias Ryker.Settings.Learning, as: LearningSetting
  alias Ryker.Slack.Names
  alias Ryker.Work.Turn

  @page_size 20
  @states ~w(queued running applied no_change deferred superseded dropped)a
  # The recent list's outcome filter, in the order the page offers it; the
  # batches that need a person are listed on their own, so no outcome here
  # includes them.
  @outcomes [
    {"updated", [:applied]},
    {"no_change", [:no_change]},
    {"in_progress", [:queued, :running]},
    {"sources_changed", [:superseded]}
  ]
  @query_keys ~w(batch attempt_page outcome page attention_page handover_page)

  @doc "The query keys the Learning page reads."
  def query_keys, do: @query_keys

  @doc "The recent list's outcome filters, in the order the page offers them."
  def outcomes, do: Enum.map(@outcomes, &elem(&1, 0))

  def project(params) do
    {waiting_count, waiting_at} = waiting_inputs()
    secrets = InspectionRedactor.configured_secrets()
    enabled = not is_nil(Application.get_env(:ryker, :learning))
    worker_running = not is_nil(Process.whereis(Runtime))
    outcome = if List.keymember?(@outcomes, params["outcome"], 0), do: params["outcome"], else: ""
    selected = selected_batch(params, secrets)

    recent_statuses =
      case List.keyfind(@outcomes, outcome, 0) do
        {_outcome, statuses} -> statuses
        nil -> @states -- [:deferred]
      end

    %{
      state:
        state(
          setting_enabled(),
          enabled,
          worker_running,
          enabled and policy_refused?(),
          applying?()
        ),
      enabled: enabled,
      worker_running: worker_running,
      counts: batch_counts(),
      waiting_inputs: waiting_count,
      oldest_waiting_at: waiting_at,
      attention: batches([:deferred], "attention_page", params, secrets),
      recent: Map.put(batches(recent_statuses, "page", params, secrets), :outcome, outcome),
      handover_failures: handover_failures(params),
      selected: selected
    }
  end

  # What a person should read first. The saved choice leads, so the line
  # agrees with the switch the moment it is pressed: turned off is off while
  # the runtime lets running passes finish, and turned on is starting until
  # the runtime has applied it. The runtime then says whether learning runs.
  defp state(false, _enabled, _worker, _refused, _applying), do: :off
  defp state(_setting, true, true, true, _applying), do: :paused
  defp state(_setting, true, true, _refused, _applying), do: :on
  defp state(_setting, true, false, _refused, _applying), do: :not_running
  defp state(true, false, _worker, _refused, true), do: :starting
  defp state(true, false, _worker, _refused, false), do: :cannot_start
  defp state(nil, false, _worker, _refused, _applying), do: :off

  # Whether the newest saved settings are still being applied to the runtime.
  defp applying? do
    Repo.exists?(
      from(installation in Installation,
        where:
          installation.applied_revision < installation.revision and
            is_nil(installation.failure_code)
      )
    )
  end

  # The worker gave a session of the configured policy more than an isolated
  # scratch, so learning holds every new attempt until the policy changes.
  defp policy_refused? do
    case Runtime.configured_options() do
      {:ok, settings} -> Batches.policy_refused?(settings)
      {:error, _reason} -> false
    end
  end

  defp setting_enabled,
    do: Repo.one(from(setting in LearningSetting, select: setting.enabled, limit: 1))

  defp batches(statuses, key, params, secrets) do
    page =
      from(b in Batch, where: b.status in ^statuses)
      |> read(key, [desc: :inserted_at, desc: :id], params)

    context = context(page.items)

    %{
      items: Enum.map(page.items, &batch(&1, secrets, context)),
      page: page.page,
      pages: page.pages,
      total: page.total
    }
  end

  # What a page of batches needs beyond each row: the names of its direct
  # conversations and which stopped batches Ryker still checks on.
  defp context(rows) do
    direct =
      for row <- rows, row.transport == "control_plane", uniq: true, do: row.conversation_ref

    stopped = for row <- rows, row.status == :deferred, do: row.id

    rechecked =
      if stopped == [],
        do: MapSet.new(),
        else:
          Repo.all(
            from(r in LearningRun,
              where:
                r.batch_id in ^stopped and not is_nil(r.started_at) and
                  is_nil(r.remote_stopped_at),
              distinct: true,
              select: r.batch_id
            )
          )
          |> MapSet.new()

    exhausted = for row <- rows, row.error_code == "learning_retry_exhausted", do: row.id

    %{
      titles: ConversationProjection.titles(direct),
      rechecked: rechecked,
      causes: stale_attempts(exhausted),
      now: DateTime.utc_now()
    }
  end

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, params, page_size: @page_size)

  defp batch_counts do
    Map.new(@states, &{&1, 0})
    |> Map.merge(
      Map.new(Repo.all(from(b in Batch, group_by: b.status, select: {b.status, count(b.id)})))
    )
  end

  defp waiting_inputs do
    pending =
      from(e in Entry,
        as: :input,
        where: e.status in [:decided, :superseded],
        where: not exists(from(m in InputMembership, where: m.input_id == parent_as(:input).id))
      )

    assigned =
      from(e in Entry,
        join: m in InputMembership,
        on: m.input_id == e.id,
        join: b in Batch,
        on: b.id == m.batch_id,
        where:
          b.status in [:queued, :running, :deferred] and
            (is_nil(m.terminal_reason) or m.terminal_reason != "source_unavailable")
      )

    {pending_count, pending_at} =
      Repo.one(from(e in pending, select: {count(e.id), min(e.updated_at)}))

    {assigned_count, assigned_at} =
      Repo.one(from(e in assigned, select: {count(e.id), min(e.updated_at)}))

    {pending_count + assigned_count, oldest(pending_at, assigned_at)}
  end

  defp selected_batch(params, secrets) do
    with {:ok, id} <- Ecto.UUID.cast(params["batch"]),
         %Batch{} = batch <- Repo.get(Batch, id) do
      selected(batch, params, secrets)
    else
      _ -> nil
    end
  end

  defp handover_failures(params) do
    page =
      from(t in Turn,
        join: e in Episode,
        on: e.id == t.episode_id,
        where: not is_nil(t.summary_error_code),
        select: %{
          turn_id: t.id,
          episode_key: e.key,
          conversation: e.destination_conversation_ref,
          accepted_at: t.accepted_at,
          delivered_at: t.delivered_at,
          error_code: t.summary_error_code
        }
      )
      |> read("handover_page", [desc: :accepted_at, desc: :id], params)

    items =
      Enum.map(page.items, fn item ->
        %{
          turn_id: item.turn_id,
          conversation: Names.destination(item.conversation),
          at: item.accepted_at,
          explanation: handover_error(item.error_code),
          response_status: if(item.delivered_at, do: "Reply sent", else: "Reply not confirmed"),
          request_path:
            "/timeline/" <>
              URI.encode(item.episode_key, &URI.char_unreserved?/1) <>
              "?" <>
              URI.encode_query(%{"attempt" => item.turn_id}) <>
              "#request-#{item.turn_id}"
        }
      end)

    %{total: page.total, page: page.page, pages: page.pages, items: items}
  end

  defp handover_error("source_capacity"),
    do: "Its source history exceeded the safe memory limit, so no conversation context was saved."

  defp handover_error("no_sources"),
    do: "No complete, usable source history was available. No unsupported summary was saved."

  defp handover_error(_),
    do:
      "Conversation context could not be saved. Inspect the original run for its retained inputs."

  defp selected(row, params, secrets) do
    # SELECTs only. The mutation owner rechecks source eligibility and both
    # scope-wide execution guards inside its locked, audited transaction.
    outstanding = outstanding_execution?(row)
    busy = scope_busy?(row)
    relearn = if row.status == :deferred, do: relearn_topics(row), else: []

    {policy, configuration_error} =
      case Runtime.configured_options() do
        {:ok, settings} -> {settings.policy, nil}
        {:error, reason} -> {nil, error(reason)}
      end

    batch(row, secrets, context([row]))
    |> Map.merge(attempts(row, params))
    |> Map.merge(%{
      relearn: relearn,
      retry_available: retryable?(row, relearn, outstanding or busy, policy),
      retry_blocked:
        retry_reason(row.status, outstanding, busy) ||
          if(row.status == :deferred, do: configuration_error),
      # A stopped batch can be dropped once no model execution of its
      # conversation is still unconfirmed (`Batches.drop_in_transaction/2`).
      drop_available: row.status == :deferred and not outstanding
    })
  end

  # One more start is offered only to a stopped batch nothing else holds,
  # under a working policy, and never while a stale topic would stop it again.
  defp retryable?(%{status: :deferred}, [], false = _held, policy) when not is_nil(policy),
    do: true

  defp retryable?(_row, _relearn, _held, _policy), do: false

  @doc """
  The learned topics a batch stopped on because they lost the messages they
  were learned from, each with where to relearn it.

  Only a batch stopped by such a topic has any. Every start meets the same
  topic until it is relearned from messages that still exist, or forgotten,
  so these, not another start, are what moves the batch; once none is left,
  one more start can update it. A forgotten topic is gone for good, so it is
  never one of them.
  """
  @spec relearn_topics(Batch.t()) :: [%{id: String.t(), title: String.t(), path: String.t()}]
  def relearn_topics(%Batch{} = batch) do
    if cause_code(batch) == "knowledge_target_unavailable",
      do: stale_topics(batch),
      else: []
  end

  def relearn_topics(_batch), do: []

  @doc """
  What stopped a batch, as its code. A batch stops with the code of what
  stopped it; one that stopped before a stale topic had a code of its own
  used every start on that topic, and its attempts carry the cause instead
  (QA re-test, 2026-09-26: batch 96368bd7 still offered "Grant one more
  start"). The same rule applies to it, whatever date it has.
  """
  @spec cause_code(Batch.t()) :: String.t() | nil
  def cause_code(%Batch{error_code: "learning_retry_exhausted", id: id}),
    do: Map.get(stale_attempts([id]), id, "learning_retry_exhausted")

  def cause_code(%Batch{error_code: code}), do: code

  # The stopped batches, of `ids`, whose latest attempt stopped on a topic that
  # lost its sources.
  defp stale_attempts([]), do: %{}

  defp stale_attempts(ids) do
    Repo.all(
      from(r in LearningRun,
        where: r.batch_id in ^ids and not is_nil(r.error_code),
        distinct: r.batch_id,
        order_by: [asc: r.batch_id, desc: r.inserted_at, desc: r.id],
        select: {r.batch_id, r.error_code}
      )
    )
    |> Enum.filter(fn {_id, code} -> code == "knowledge_target_unavailable" end)
    |> Map.new()
  end

  defp stale_topics(batch) do
    repository =
      if is_nil(batch.repository_ref),
        do: dynamic([k], is_nil(k.repository_ref)),
        else: dynamic([k], k.repository_ref == ^batch.repository_ref)

    topics =
      Repo.all(
        from(k in ConversationKnowledge,
          where:
            k.transport == ^batch.transport and k.conversation_ref == ^batch.conversation_ref,
          where: is_nil(k.forgotten_at),
          where: ^repository,
          order_by: [desc: k.updated_at, desc: k.id],
          limit: 20
        )
      )

    available = ConversationMemory.available_ids(topics)

    topics
    |> Enum.reject(&MapSet.member?(available, &1.id))
    |> ConversationMemory.present()
    |> Enum.map(
      &%{id: &1.id, title: &1.title, path: ConversationMemory.topic_path(&1.id) <> "#relearn"}
    )
  end

  defp outstanding_execution?(row) do
    Repo.exists?(
      from(r in LearningRun,
        join: b in Batch,
        on: b.id == r.batch_id,
        where:
          b.scope_key == ^row.scope_key and not is_nil(r.started_at) and
            is_nil(r.remote_stopped_at)
      )
    )
  end

  defp scope_busy?(row) do
    Repo.exists?(
      from(b in Batch,
        where:
          b.scope_key == ^row.scope_key and
            b.id != ^row.id and b.status in [:queued, :running]
      )
    )
  end

  defp retry_reason(status, _outstanding, _busy) when status != :deferred, do: nil

  defp retry_reason(:deferred, true, _busy),
    do:
      "An earlier model execution has not been confirmed stopped. Ryker must reconcile it before another start."

  defp retry_reason(:deferred, false, true),
    do: "Another batch in this conversation is already queued or running."

  defp retry_reason(:deferred, false, false), do: nil

  defp attempts(row, params) do
    page =
      from(r in LearningRun,
        where: r.batch_id == ^row.id,
        select: %{
          id: r.id,
          status: r.status,
          at: r.inserted_at,
          error_code: r.error_code,
          pruned_at: r.pruned_at,
          result: r.result,
          stop_receipt: r.stop_receipt,
          inputs: r.inputs,
          remote_stopped_at: r.remote_stopped_at
        }
      )
      |> read("attempt_page", [desc: :inserted_at, desc: :id], params)

    offset = (page.page - 1) * @page_size
    # Each attempt is read on its learning card on the Timeline.
    paths = LearningRequests.paths(page.items)

    attempts =
      page.items
      |> Enum.with_index()
      |> Enum.map(fn {attempt, index} ->
        attempt
        |> Map.drop([:result, :stop_receipt, :inputs, :remote_stopped_at])
        |> Map.merge(%{
          number: page.total - offset - index,
          error: attempt_error(attempt),
          label: attempt_label(attempt),
          path: paths[attempt.id]
        })
      end)

    %{
      attempts: attempts,
      attempt_page: page.page,
      attempt_pages: page.pages
    }
  end

  @doc """
  What one attempt came to, from its own saved result; the batch it belongs to
  can end differently. The Learning page and the attempt's Timeline card read
  it the same way.
  """
  def attempt_label(%{status: :applied, pruned_at: nil, result: result})
      when is_binary(result) do
    # Reselection changes the batch, never the outcome of an earlier attempt.
    case Jason.decode(result) do
      {:ok, %{"updates" => updates}} when is_list(updates) ->
        if Enum.all?(updates, &match?(%{"action" => "defer"}, &1)),
          do: "No change needed",
          else: "Knowledge updated"

      _ ->
        "Learning completed"
    end
  end

  def attempt_label(%{status: :applied}), do: "Learning completed"
  def attempt_label(%{status: status}), do: label(status)

  defp batch(row, secrets, context),
    do: %{
      id: row.id,
      status: row.status,
      label: label(row.status),
      conversation: conversation(row, context.titles),
      conversation_path: Activity.conversation_path(row.transport, row.conversation_ref),
      repository: row.repository_ref,
      mode: row.execution_mode,
      input_count: row.input_count,
      start_count: row.start_count,
      start_limit: row.start_limit,
      budget_version: row.budget_version,
      at: row.inserted_at,
      completed_at: row.completed_at,
      next_check: next_check(row, context),
      error: error(Map.get(context.causes, row.id, row.error_code)),
      error_code: safe_code(Map.get(context.causes, row.id, row.error_code), secrets),
      path: path(row.id)
    }

  # A direct conversation is named by its title, like Chat names it; every
  # one of them read "Direct conversation" on its own.
  defp conversation(%{transport: "control_plane", conversation_ref: ref}, titles) do
    case titles[ref] do
      nil -> Names.destination(ref)
      title -> "Direct conversation · " <> title
    end
  end

  defp conversation(row, _titles), do: Names.destination(row.conversation_ref)

  # When Ryker looks at the batch again, only while that is still ahead: a
  # queued batch waiting out its delay, or a stopped one whose model run it
  # still reconciles. A stopped batch nothing checks again has no next check.
  defp next_check(%{next_attempt_at: %DateTime{} = at} = row, context) do
    scheduled =
      row.status == :queued or
        (row.status == :deferred and MapSet.member?(context.rechecked, row.id))

    if scheduled and DateTime.compare(at, context.now) == :gt, do: at
  end

  defp next_check(_row, _context), do: nil

  @doc "Where one batch opens on the Learning page."
  def path(id), do: "/memory/learning?" <> URI.encode_query(%{"batch" => id})

  def retry_resource(id, version), do: id <> ":" <> Integer.to_string(version)

  def label(:queued), do: "Queued"
  def label(:running), do: "Learning"
  def label(:applied), do: "Knowledge updated"
  def label(:no_change), do: "No change needed"
  def label(:deferred), do: "Needs attention"
  def label(:superseded), do: "Sources no longer available"
  def label(:dropped), do: "Dropped"
  def label(:prepared), do: "Prepared"
  def label(:responded), do: "Response recorded"
  def label(:rejected), do: "Response rejected"
  def label(:stale), do: "Sources or topic changed"

  @doc """
  Why one attempt ended. An attempt that first could not be reconciled reads
  as unconfirmed only until it has stop proof: seven attempts on 2026-09-24
  said the model "may still be running" when they had never sent it anything.
  """
  def attempt_error(%{stop_receipt: %{"kind" => "attempt_expired"}}),
    do:
      "The worker never confirmed that this attempt stopped. No worker run lasts longer than a day, so Ryker closed it after that and learned from these messages again."

  def attempt_error(%{error_code: "learning_remote_unresolved", stop_receipt: %{} = stop}) do
    if stop["kind"] == "never_submitted",
      do: error("learning_session_unconfirmed"),
      else: "Ryker could not confirm this model execution at first, then confirmed it stopped."
  end

  def attempt_error(%{error_code: code}), do: error(code)

  def error(nil), do: nil

  def error("source_capacity"),
    do:
      "The source history is too large to combine safely. Existing conversation context remains saved; other conversation groups can still progress."

  def error("scope_capacity"),
    do:
      "The combined conversation context would span too many source scopes. The original context remains saved."

  def error("learning_judgment_deferred"),
    do:
      "The model found no safe, useful topic change to make from these messages. Its explanation is saved in the attempt."

  def error("learning_retry_exhausted"),
    do:
      "The approved model starts were used. Inspect the attempts before granting one more start."

  def error("learning_remote_unresolved"),
    do:
      "The worker has not confirmed that this attempt stopped. Ryker checks again every hour and starts nothing new in this conversation until it does, or until a day has passed and nothing more can arrive from it."

  def error("learning_attempt_expired"),
    do:
      "The worker never confirmed that the last attempt stopped. After a day nothing more can arrive from it, so Ryker closed it and starts again with a fresh session."

  def error("learning_session_unconfirmed"),
    do:
      "The worker session could not be confirmed, so nothing was sent to the model. Ryker starts again with a fresh session."

  def error("learning_session_not_isolated"),
    do:
      "The worker reported broader access than the learning job allows, so Ryker sent it nothing. Check the job and worker version before starting a new attempt."

  def error("learning_policy_changed"),
    do: "The learning settings changed before this attempt started, so it never ran."

  def error("learning_remote_outstanding"),
    do: "An earlier model execution has not been confirmed stopped. Wait for reconciliation."

  def error("learning_scope_busy"),
    do: "Another batch in this conversation is queued or running. Try after it finishes."

  def error("learning_retry_conflict"),
    do: "This batch changed after the form was opened. Refresh it before retrying."

  def error("learning_disabled"),
    do: "Learning is disabled. Enable Learning in Settings before retrying."

  def error("learning_configuration_invalid"),
    do: "The current learning configuration is invalid. Correct it before retrying."

  def error("learning_source_stale"),
    do:
      "A source changed, was removed, or expired. This batch cannot be retried with its old inputs."

  def error("knowledge_target_unavailable"),
    do:
      "A topic's source history is no longer valid. This attempt cannot safely update that topic."

  def error("learning_capacity_exceeded"),
    do:
      "The selected input and source history exceed the learning budget. A retry alone may not resolve this."

  def error("knowledge_source_capacity_exceeded"),
    do:
      "This topic reached its source-history limit. Its existing history was preserved; another identical attempt will not add capacity."

  def error("invalid_learning_result"),
    do:
      "The model response did not match the learning contract. Inspect the saved response and validation details."

  def error("learning_match_required"),
    do:
      "A possible existing topic was found. The next bounded attempt must compare it before creating a duplicate."

  def error("nothing_to_learn"),
    do:
      "Only greetings, thanks or short replies like \"ok\", so Ryker did not ask a model to learn from them."

  def error("learning_result_pruned"),
    do: "The saved model response expired. Its outcome remains recorded."

  def error(code) when is_atom(code), do: error(Atom.to_string(code))

  def error(_),
    do:
      "Learning could not finish. Inspect the frozen attempt and its diagnostic code before retrying."

  defp safe_code(nil, _secrets), do: nil
  defp safe_code(value, secrets), do: InspectionRedactor.artifact(value, secrets: secrets).text

  defp oldest(nil, right), do: right
  defp oldest(left, nil), do: left
  defp oldest(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)
end
