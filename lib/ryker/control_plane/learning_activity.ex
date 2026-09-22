defmodule Ryker.ControlPlane.LearningActivity do
  @moduledoc "Read-only operator projection of passive learning and its frozen attempts."
  import Ecto.Query
  alias Ryker.ControlPlane.{Activity, InspectionRedactor, PagedRelation, SlackNames}
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, InputMembership, Runtime}
  alias Ryker.Repo
  alias Ryker.State.LearningRun
  alias Ryker.Work.Turn

  @page_size 20
  @states ~w(queued running applied no_change deferred superseded)a

  def project(params) do
    counts = batch_counts()
    {waiting_count, waiting_at} = waiting_inputs()
    status = Enum.find(@states, &(Atom.to_string(&1) == params["learning_status"]))
    query = if status, do: from(b in Batch, where: b.status == ^status), else: Batch
    page = read(query, "learning_page", [desc: :inserted_at, desc: :id], params)
    secrets = InspectionRedactor.configured_secrets()

    %{
      enabled: not is_nil(Application.get_env(:ryker, :learning)),
      worker_running: not is_nil(Process.whereis(Runtime)),
      counts: counts,
      waiting_inputs: waiting_count,
      oldest_waiting_at: waiting_at,
      handover_failures: handover_failures(params),
      items: Enum.map(page.items, &batch(&1, secrets)),
      selected: selected_batch(params, secrets),
      page: page.page,
      pages: page.pages,
      total: page.total,
      filter: if(status, do: Atom.to_string(status), else: "")
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
          conversation: SlackNames.destination(item.conversation),
          at: item.accepted_at,
          explanation: handover_error(item.error_code),
          response_status:
            if(item.delivered_at, do: "Response sent", else: "Delivery not confirmed"),
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
      "Conversation context could not be saved. Inspect the original work turn for its retained inputs."

  defp selected(row, params, secrets) do
    # SELECTs only. The mutation owner rechecks source eligibility and both
    # scope-wide execution guards inside its locked, audited transaction.
    outstanding = outstanding_execution?(row)
    busy = scope_busy?(row)

    {policy, configuration_error} =
      case Runtime.configured_options() do
        {:ok, settings} -> {settings.policy, nil}
        {:error, reason} -> {nil, error(reason)}
      end

    batch(row, secrets)
    |> Map.merge(attempts(row, params))
    |> Map.merge(%{
      retry_policy: policy,
      retry_available:
        row.status == :deferred and not outstanding and not busy and not is_nil(policy),
      retry_blocked:
        retry_reason(row.status, outstanding, busy) ||
          if(row.status == :deferred, do: configuration_error)
    })
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
          result: r.result
        }
      )
      |> read("attempt_page", [desc: :inserted_at, desc: :id], params)

    offset = (page.page - 1) * @page_size

    attempts =
      page.items
      |> Enum.with_index()
      |> Enum.map(fn {attempt, index} ->
        attempt
        |> Map.delete(:result)
        |> Map.merge(%{
          number: page.total - offset - index,
          error: error(attempt.error_code),
          label: attempt_label(attempt)
        })
      end)

    %{
      attempts: attempts,
      attempt_page: page.page,
      attempt_pages: page.pages
    }
  end

  defp attempt_label(%{status: :applied, pruned_at: nil, result: result})
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

  defp attempt_label(%{status: :applied}), do: "Learning completed"
  defp attempt_label(%{status: status}), do: label(status)

  def attempt_number(%LearningRun{batch_id: nil, generation: generation}), do: generation

  def attempt_number(%LearningRun{} = run) do
    # A new frozen source selection restarts its execution generation. The
    # operator sees one chronological history for the original learning request.
    Repo.aggregate(
      from(r in LearningRun,
        where: r.batch_id == ^run.batch_id,
        where:
          r.inserted_at < ^run.inserted_at or
            (r.inserted_at == ^run.inserted_at and r.id <= ^run.id)
      ),
      :count
    )
  end

  @doc "One batch as the page lists it; a caller with the page's secrets passes them once."
  def batch(row, secrets \\ InspectionRedactor.configured_secrets()),
    do: %{
      id: row.id,
      status: row.status,
      label: label(row.status),
      conversation: SlackNames.destination(row.conversation_ref),
      conversation_path: Activity.conversation_path(row.transport, row.conversation_ref),
      repository: row.repository_ref,
      mode: row.execution_mode,
      input_count: row.input_count,
      start_count: row.start_count,
      start_limit: row.start_limit,
      budget_version: row.budget_version,
      at: row.inserted_at,
      completed_at: row.completed_at,
      next_attempt_at: row.next_attempt_at,
      error: error(row.error_code),
      error_code: safe_code(row.error_code, secrets),
      path: path(row.id)
    }

  def path(id), do: "/memory?" <> URI.encode_query(%{"batch" => id}) <> "#learning-activity"

  def attempt_path(batch, run),
    do:
      "/memory?" <> URI.encode_query(%{"batch" => batch, "attempt" => run}) <> "#learning-receipt"

  def retry_resource(id, version), do: id <> ":" <> Integer.to_string(version)

  def label(:queued), do: "Queued"
  def label(:running), do: "Learning"
  def label(:applied), do: "Knowledge updated"
  def label(:no_change), do: "No change needed"
  def label(:deferred), do: "Needs attention"
  def label(:superseded), do: "Sources no longer available"
  def label(:prepared), do: "Prepared"
  def label(:responded), do: "Response recorded"
  def label(:rejected), do: "Response rejected"
  def label(:stale), do: "Sources or topic changed"

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
      "The model execution may still be running. Ryker checks its state again before allowing another start."

  def error("learning_remote_outstanding"),
    do: "An earlier model execution has not been confirmed stopped. Wait for reconciliation."

  def error("learning_scope_busy"),
    do: "Another batch in this conversation is queued or running. Try after it finishes."

  def error("learning_retry_conflict"),
    do: "This batch changed after the form was opened. Refresh it before retrying."

  def error("learning_disabled"),
    do: "Learning is disabled. Configure a learning policy before retrying."

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
