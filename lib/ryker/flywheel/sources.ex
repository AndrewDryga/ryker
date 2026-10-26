defmodule Ryker.Flywheel.Sources do
  @moduledoc "Local evidence exports. External sources use the same staged-page contract through their available connector."
  alias Ryker.{Accounting, Admission, Episodes, Feedback, Improvement, Memories}
  alias Ryker.Flywheel.{Protocol, Sources}
  alias Ryker.{Repo, Settings, Work}

  @sources %{
    "settings_history" =>
      {Settings.Edit, :inserted_at, [:id, :domain, :revision, :fingerprint, :inserted_at]},
    "episodes" =>
      {Episodes.Episode, :updated_at,
       [
         :id,
         :key,
         :state,
         :semantic_version,
         :execution_mode,
         :history_pruned_at,
         :inserted_at,
         :updated_at
       ]},
    "feedback" =>
      {Feedback.Signal, :inserted_at,
       [:id, :episode_id, :input_id, :kind, :category, :value, :occurred_at, :inserted_at]},
    "diagnoses" =>
      {Improvement.Candidate, :updated_at,
       [
         :id,
         :episode_id,
         :input_id,
         :category,
         :step,
         :confidence,
         :analysis,
         :status,
         :signal_count,
         :forgotten_at,
         :updated_at
       ]},
    "usage" =>
      {Accounting.Execution, :updated_at,
       [
         :id,
         :episode_id,
         :kind,
         :source_id,
         :execution_mode,
         :status,
         :execution_target,
         :usage_recorded,
         :usage_cost_recorded,
         :usage_cost_usd,
         :usage_input_tokens,
         :usage_output_tokens,
         :usage_queued_ms,
         :usage_provider_ms,
         :usage_host_ms,
         :measurement_error_code,
         :recorded_at,
         :updated_at
       ]},
    "work" =>
      {Work.Turn, :updated_at,
       [
         :id,
         :episode_id,
         :status,
         :work_attempt_count,
         :delivery_attempt_count,
         :last_error_code,
         :execution_target,
         :accepted_at,
         :delivered_at,
         :operational_pruned_at,
         :updated_at
       ]},
    "routing" =>
      {Admission.Attempt, :updated_at,
       [
         :id,
         :input_id,
         :generation,
         :phase,
         :execution_target,
         :operational_pruned_at,
         :updated_at
       ]},
    "memory_reviews" =>
      {Memories.MemoryReviewItem, :updated_at,
       [:id, :kind, :status, :action, :reviewed_at, :updated_at]},
    "memory" =>
      {Memories.MemoryEntry, :updated_at,
       [
         :id,
         :kind,
         :status,
         :recall_count,
         :expires_at,
         :last_recalled_at,
         :last_reviewed_at,
         :updated_at
       ]}
  }

  def catalog do
    %{
      local: Enum.sort(Map.keys(@sources)),
      improvement_kinds: Protocol.kinds(),
      external: ~w(sentry logs metrics evals releases tasks tools settings),
      semantics:
        "Local exports select records changed in [from, until), including successful work. Open source traces for diagnosis; these inventories contain no prompt bodies or credentials.",
      coverage:
        "Complete means all retained inventory rows were analyzed, not that deleted historical bodies still exist. Record missing detail as an explicit limitation. External sources must report their actual retention, pagination and sampling."
    }
  end

  def page(source, progress) do
    case Map.fetch(@sources, source) do
      {:ok, {schema, clock, fields}} -> local_page(schema, clock, fields, progress)
      :error -> Repo.rollback(:flywheel_external_collection_required)
    end
  end

  defp local_page(schema, clock, fields, progress) do
    {:ok, from} = Protocol.datetime(progress["from"])
    {:ok, until} = Protocol.datetime(progress["until"])
    cursor = decode_cursor(progress["cursor"])
    rows = schema |> Sources.Query.page(fields, clock, from, until, cursor) |> Repo.all()
    page = Enum.take(rows, 100)
    complete = length(rows) <= 100
    next_cursor = if complete, do: nil, else: encode_cursor(List.last(page), clock)

    records =
      Enum.map(page, fn row ->
        data = Protocol.document(row)
        %{"ref" => row.id, "version" => Protocol.digest(data), "data" => data}
      end)

    result = %{
      "records" => records,
      "cursor" => progress["cursor"],
      "next_cursor" => next_cursor,
      "complete" => complete,
      "query" =>
        "#{schema.__schema__(:source)} ordered by #{clock},id; [#{progress["from"]},#{progress["until"]}); all retained rows"
    }

    limitation = limitation(schema, from, page)

    if limitation,
      do: Map.merge(result, %{"coverage" => "partial", "limitation" => limitation}),
      else: result
  end

  defp limitation(schema, from, rows) do
    retention = Repo.peek(Settings.Retention.Query.all())

    pruned =
      Enum.any?(rows, &(Map.get(&1, :operational_pruned_at) || Map.get(&1, :history_pruned_at)))

    cond do
      pruned ->
        "Some underlying traces have been pruned; only their inventory remains."

      is_nil(retention) ->
        "Retention settings are unavailable; historical completeness is unverified."

      DateTime.compare(
        from,
        DateTime.add(Repo.now!(), -Map.fetch!(retention, horizon(schema)), :second)
      ) == :lt ->
        "The requested window starts before the source retention horizon."

      true ->
        nil
    end
  end

  defp horizon(Episodes.Episode), do: :episode_history_seconds
  defp horizon(Settings.Edit), do: :audit_data_seconds
  defp horizon(Memories.MemoryReviewItem), do: :audit_data_seconds
  defp horizon(Memories.MemoryEntry), do: :conversation_memory_seconds
  defp horizon(_schema), do: :operational_data_seconds

  defp encode_cursor(row, clock),
    do: Jason.encode!([DateTime.to_iso8601(Map.fetch!(row, clock)), row.id])

  defp decode_cursor(nil), do: nil

  defp decode_cursor(value) do
    with {:ok, [at, id]} <- Jason.decode(value),
         {:ok, at} <- Protocol.datetime(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {at, id}
    else
      _invalid -> Repo.rollback(:invalid_flywheel_cursor)
    end
  end
end
