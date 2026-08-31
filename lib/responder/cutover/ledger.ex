defmodule Responder.Cutover.Ledger do
  @moduledoc """
  Persists one reviewed, byte-bound legacy cutover plan before any import.

  Inventory and review are separate artifacts. Automatically safe memory,
  behavior, and schedule rows retain their inventory decision. Every unfinished
  episode or wait requires an explicit local-operator import/skip decision.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Responder.{CanonicalJSON, Cutover.Item, Cutover.Run, Repo}
  alias Responder.Cutover.LegacySchema

  @manifest_fields ~w(cutover_at items source summary version workspace_ref)
  @envelope_fields ~w(manifest sha256)
  @item_fields ~w(data decision id kind source)
  @source_fields ~w(ref sha256 table)
  @review_fields ~w(decisions manifest_sha256 operator_ref reviewed_at version)
  @maximum_manifest_bytes 16 * 1_024 * 1_024
  @maximum_review_bytes 1 * 1_024 * 1_024
  @maximum_items 3_000
  @reference ~r/\A[A-Za-z0-9_.:@\/-]+\z/
  @item_kinds %{
    "behavior" => :behavior,
    "episode" => :episode,
    "memory" => :memory,
    "schedule" => :schedule,
    "wait" => :wait
  }

  @spec prepare(map(), map()) ::
          {:ok, %{run: Run.t(), status: :duplicate | :prepared}} | {:error, term()}
  def prepare(envelope, review) do
    with {:ok, plan} <- plan(envelope, review) do
      Repo.transaction(fn -> prepare_locked(plan) end)
      |> transaction_result()
    end
  end

  defp plan(envelope, review) do
    with :ok <- bounded(envelope, @maximum_manifest_bytes, :manifest),
         :ok <- bounded(review, @maximum_review_bytes, :review),
         {:ok, manifest, manifest_sha256} <- envelope(envelope),
         {:ok, cutover_at} <- datetime(manifest["cutover_at"], :cutover_at),
         {:ok, review} <- review(review, manifest_sha256, cutover_at),
         {:ok, items} <- items(manifest["items"], review["decisions"]),
         :ok <- wait_dependencies(items) do
      {:ok,
       %{
         cutover_at: cutover_at,
         items: items,
         manifest: manifest,
         manifest_sha256: manifest_sha256,
         review: review,
         review_sha256: CanonicalJSON.digest(review)
       }}
    end
  end

  defp envelope(%{} = envelope) do
    with true <- exact_fields?(envelope, @envelope_fields),
         %{} = manifest <- envelope["manifest"],
         true <- exact_fields?(manifest, @manifest_fields),
         1 <- manifest["version"],
         sha256 when is_binary(sha256) <- envelope["sha256"],
         true <- digest?(sha256),
         true <- CanonicalJSON.digest(manifest) == sha256,
         %{
           "kind" => "responder_sqlite",
           "schema_sha256" => schema_sha256,
           "schema_version" => schema_version,
           "sha256" => source_sha256
         } = source <- manifest["source"],
         true <- map_size(source) == 4,
         true <- LegacySchema.supported?(schema_version, schema_sha256),
         true <- digest?(source_sha256),
         true <- reference?(manifest["workspace_ref"]),
         %{} <- manifest["summary"] do
      {:ok, manifest, sha256}
    else
      _invalid -> {:error, :cutover_manifest_invalid}
    end
  end

  defp envelope(_envelope), do: {:error, :cutover_manifest_invalid}

  defp review(%{} = review, manifest_sha256, cutover_at) do
    with true <- exact_fields?(review, @review_fields),
         1 <- review["version"],
         ^manifest_sha256 <- review["manifest_sha256"],
         true <- reference?(review["operator_ref"]),
         %{} <- review["decisions"],
         {:ok, reviewed_at} <- datetime(review["reviewed_at"], :reviewed_at),
         true <- DateTime.compare(reviewed_at, cutover_at) in [:eq, :gt] do
      {:ok, Map.put(review, "reviewed_at", DateTime.to_iso8601(reviewed_at))}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :cutover_review_invalid}
    end
  end

  defp review(_review, _manifest_sha256, _cutover_at), do: {:error, :cutover_review_invalid}

  defp items(values, decisions) when is_list(values) and length(values) <= @maximum_items do
    with true <- values == Enum.sort_by(values, & &1["id"]),
         true <- unique_item_ids?(values),
         {:ok, items} <- map_items(values, decisions),
         true <- Map.keys(decisions) |> Enum.sort() == review_item_ids(values) do
      {:ok, items}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :cutover_items_invalid}
    end
  end

  defp items(_values, _decisions), do: {:error, :cutover_items_invalid}

  defp map_items(values, decisions) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, prepared} ->
      case item(item, decisions) do
        {:ok, value} -> {:cont, {:ok, [value | prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp item(%{} = item, decisions) do
    with true <- exact_fields?(item, @item_fields),
         id when is_binary(id) <- item["id"],
         true <- reference?(id),
         kind_name when is_binary(kind_name) <- item["kind"],
         {:ok, kind} <- Map.fetch(@item_kinds, kind_name),
         %{} = data <- item["data"],
         %{} = source <- item["source"],
         true <- exact_fields?(source, @source_fields),
         true <- source_table?(kind_name, source["table"]),
         true <- reference?(source["ref"]),
         true <- digest?(source["sha256"]),
         true <- CanonicalJSON.digest(data) == source["sha256"],
         {:ok, decision} <- final_decision(item["decision"], id, decisions) do
      {:ok,
       %{
         data: data,
         decision: decision,
         kind: kind,
         ref: id,
         source_ref: source["ref"],
         source_sha256: source["sha256"],
         source_table: source["table"],
         status: if(decision == :import, do: :pending, else: :skipped)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :cutover_item_invalid}
    end
  end

  defp item(_item, _decisions), do: {:error, :cutover_item_invalid}

  defp final_decision("import", _id, _decisions), do: {:ok, :import}

  defp final_decision("review", id, decisions) do
    case Map.fetch(decisions, id) do
      {:ok, "import"} -> {:ok, :import}
      {:ok, "skip"} -> {:ok, :skip}
      _invalid -> {:error, {:cutover_review_missing, id}}
    end
  end

  defp final_decision(_decision, _id, _decisions), do: {:error, :cutover_item_invalid}

  defp wait_dependencies(items) do
    episodes =
      Map.new(items, fn item ->
        if item.kind == :episode, do: {item.source_ref, item.decision}, else: {nil, nil}
      end)
      |> Map.delete(nil)

    invalid =
      Enum.find(items, fn item ->
        item.kind == :wait and item.decision == :import and
          Map.get(episodes, item.data["episode_id"]) != :import
      end)

    if invalid, do: {:error, {:cutover_wait_episode_not_imported, invalid.ref}}, else: :ok
  end

  defp prepare_locked(plan) do
    case Repo.one(
           from(run in Run,
             where: run.manifest_sha256 == ^plan.manifest_sha256,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        insert_plan!(plan)

      %Run{review_sha256: review_sha256} = run when review_sha256 == plan.review_sha256 ->
        %{run: run, status: :duplicate}

      %Run{} ->
        Repo.rollback(:cutover_manifest_review_conflict)
    end
  end

  defp insert_plan!(plan) do
    source = plan.manifest["source"]
    review = plan.review
    {:ok, reviewed_at} = datetime(review["reviewed_at"], :reviewed_at)

    run =
      %Run{}
      |> cast(
        %{
          cutover_at: plan.cutover_at,
          id: Ecto.UUID.generate(),
          item_count: length(plan.items),
          manifest_sha256: plan.manifest_sha256,
          operator_ref: review["operator_ref"],
          review_sha256: plan.review_sha256,
          reviewed_at: reviewed_at,
          source_kind: source["kind"],
          source_schema_sha256: source["schema_sha256"],
          source_schema_version: source["schema_version"],
          source_sha256: source["sha256"],
          status: :prepared,
          summary: plan.manifest["summary"],
          version: 1,
          workspace_ref: plan.manifest["workspace_ref"]
        },
        [
          :cutover_at,
          :id,
          :item_count,
          :manifest_sha256,
          :operator_ref,
          :review_sha256,
          :reviewed_at,
          :source_kind,
          :source_schema_sha256,
          :source_schema_version,
          :source_sha256,
          :status,
          :summary,
          :version,
          :workspace_ref
        ]
      )
      |> validate_required([
        :cutover_at,
        :id,
        :item_count,
        :manifest_sha256,
        :operator_ref,
        :review_sha256,
        :reviewed_at,
        :source_kind,
        :source_schema_sha256,
        :source_schema_version,
        :source_sha256,
        :status,
        :summary,
        :version,
        :workspace_ref
      ])
      |> unique_constraint(:manifest_sha256)
      |> check_constraint(:status, name: :responder_cutover_run_valid)
      |> Repo.insert!()

    Enum.each(plan.items, &insert_item!(&1, run.id))
    %{run: run, status: :prepared}
  end

  defp insert_item!(item, run_id) do
    %Item{}
    |> cast(
      Map.merge(item, %{id: Ecto.UUID.generate(), run_id: run_id}),
      [
        :data,
        :decision,
        :id,
        :kind,
        :ref,
        :run_id,
        :source_ref,
        :source_sha256,
        :source_table,
        :status
      ]
    )
    |> validate_required([
      :data,
      :decision,
      :id,
      :kind,
      :ref,
      :run_id,
      :source_ref,
      :source_sha256,
      :source_table,
      :status
    ])
    |> unique_constraint([:run_id, :ref])
    |> unique_constraint([:run_id, :source_table, :source_ref])
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:status, name: :responder_cutover_item_valid)
    |> Repo.insert!()
  end

  defp review_item_ids(values) do
    values
    |> Enum.filter(&(&1["decision"] == "review"))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp unique_item_ids?(values) do
    ids = Enum.map(values, & &1["id"])
    Enum.uniq(ids) == ids
  end

  defp source_table?("memory", "memory_entries"), do: true
  defp source_table?("behavior", table) when table in ~w(memory_entries standing_rules), do: true
  defp source_table?("schedule", "scheduled_tasks"), do: true
  defp source_table?("episode", "work_episodes"), do: true
  defp source_table?("wait", "episode_wakeups"), do: true
  defp source_table?(_kind, _table), do: false

  defp bounded(value, maximum, kind) do
    case CanonicalJSON.validate(value, max_bytes: maximum) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cutover_artifact_invalid, kind, reason}}
    end
  end

  defp datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, normalize(datetime)}
      _invalid -> {:error, {:cutover_datetime_invalid, field}}
    end
  end

  defp datetime(_value, field), do: {:error, {:cutover_datetime_invalid, field}}

  defp normalize(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp exact_fields?(map, fields),
    do: map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1))

  defp reference?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1_024 and String.valid?(value) and
        Regex.match?(@reference, value)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
