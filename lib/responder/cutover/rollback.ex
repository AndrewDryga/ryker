defmodule Responder.Cutover.Rollback do
  @moduledoc """
  Removes an applied cutover only while every imported target is unchanged.

  Rollback is deliberately narrower than deletion by provenance alone. Once the
  replacement runtime has recalled memory, fired an automation, claimed work,
  advanced an episode, or dispatched a schedule, the operator must resolve that
  live state explicitly instead of erasing it behind the runtime.
  """

  import Ecto.Query

  alias Responder.Cutover.{Importer, Item, Run}
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Repo
  alias Responder.State.{Behavior, MemoryEntry, Record, Schedule}
  alias Responder.Work.Session

  @spec rollback(Ecto.UUID.t(), String.t()) ::
          {:ok, %{run: Run.t(), status: :duplicate | :rolled_back}} | {:error, term()}
  def rollback(run_id, operator_ref) do
    with {:ok, run_id} <- uuid(run_id),
         :ok <- reference(operator_ref) do
      Repo.transaction(fn -> rollback_locked(run_id, operator_ref) end)
      |> transaction_result()
    end
  end

  defp rollback_locked(run_id, operator_ref) do
    lock_global!()

    case Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:cutover_run_not_found)

      %Run{status: :rolled_back, rolled_back_by: ^operator_ref} = run ->
        %{run: run, status: :duplicate}

      %Run{status: :rolled_back} ->
        Repo.rollback(:cutover_rollback_operator_conflict)

      %Run{status: :applied} = run ->
        items =
          Repo.all(
            from(item in Item,
              where: item.run_id == ^run.id,
              order_by: [asc: item.id],
              lock: "FOR UPDATE"
            )
          )

        with :ok <- applied_plan(run, items),
             :ok <- unchanged_targets(items),
             :ok <- delete_targets(items),
             :ok <- mark_items_rolled_back(items),
             {:ok, rolled_back_at} <- database_now(),
             {:ok, rolled_back} <- update_run(run, operator_ref, rolled_back_at) do
          %{run: rolled_back, status: :rolled_back}
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      %Run{status: status} ->
        Repo.rollback({:cutover_run_not_rollbackable, status})
    end
  end

  defp applied_plan(run, items) do
    cond do
      length(items) != run.item_count ->
        {:error, :cutover_item_count_mismatch}

      Enum.any?(items, &(&1.status not in [:applied, :skipped])) ->
        {:error, :cutover_items_not_applied}

      true ->
        :ok
    end
  end

  defp unchanged_targets(items) do
    Enum.reduce_while(items, :ok, fn
      %Item{status: :skipped}, :ok ->
        {:cont, :ok}

      %Item{} = item, :ok ->
        case Importer.target_fingerprint(item, item.target_refs) do
          {:ok, fingerprint} when fingerprint == item.target_fingerprint -> {:cont, :ok}
          {:ok, _changed} -> {:halt, {:error, {:cutover_target_changed, item.ref}}}
          {:error, _reason} -> {:halt, {:error, {:cutover_target_changed, item.ref}}}
        end
    end)
  end

  defp delete_targets(items) do
    items
    |> Enum.filter(&(&1.status == :applied))
    |> Enum.sort_by(&{-kind_rank(&1.kind), &1.ref})
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case delete_target(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  rescue
    error in Postgrex.Error -> {:error, {:cutover_target_has_dependencies, error.postgres.code}}
  end

  defp delete_target(%Item{kind: :memory, target_refs: [ref]} = item),
    do: delete_one(MemoryEntry, item, ref)

  defp delete_target(%Item{kind: :behavior, target_refs: [ref]} = item),
    do: delete_one(Behavior, item, ref)

  defp delete_target(%Item{kind: :schedule, target_refs: refs} = item) do
    {count, _rows} =
      Repo.delete_all(
        from(value in Schedule,
          where: value.cutover_item_id == ^item.id and value.ref in ^refs
        )
      )

    if count == length(refs), do: :ok, else: {:error, {:cutover_target_changed, item.ref}}
  end

  defp delete_target(%Item{kind: :wait, target_refs: [ref]} = item),
    do: delete_one(Record, item, ref)

  defp delete_target(%Item{kind: :episode, target_refs: [key]} = item) do
    case Repo.one(
           from(value in Episode,
             where: value.cutover_item_id == ^item.id and value.key == ^key,
             lock: "FOR UPDATE"
           )
         ) do
      %Episode{} = episode ->
        _events = Repo.delete_all(from(event in Event, where: event.episode_id == ^episode.id))

        _sessions =
          Repo.delete_all(from(session in Session, where: session.episode_id == ^episode.id))

        case Repo.delete(episode) do
          {:ok, _episode} -> :ok
          {:error, _changeset} -> {:error, {:cutover_target_changed, item.ref}}
        end

      nil ->
        {:error, {:cutover_target_changed, item.ref}}
    end
  end

  defp delete_one(schema, item, ref) do
    {count, _rows} =
      Repo.delete_all(
        from(value in schema,
          where: value.cutover_item_id == ^item.id and value.ref == ^ref
        )
      )

    if count == 1, do: :ok, else: {:error, {:cutover_target_changed, item.ref}}
  end

  defp mark_items_rolled_back(items) do
    items
    |> Enum.filter(&(&1.status == :applied))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case item
           |> Ecto.Changeset.change(status: :rolled_back)
           |> Ecto.Changeset.check_constraint(:status, name: :responder_cutover_item_valid)
           |> Repo.update() do
        {:ok, _item} ->
          {:cont, :ok}

        {:error, changeset} ->
          {:halt, {:error, {:cutover_persistence_failed, :item, changeset.errors}}}
      end
    end)
  end

  defp update_run(run, operator_ref, rolled_back_at) do
    run
    |> Ecto.Changeset.change(%{
      rolled_back_at: rolled_back_at,
      rolled_back_by: operator_ref,
      status: :rolled_back
    })
    |> Ecto.Changeset.check_constraint(:status, name: :responder_cutover_run_valid)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:cutover_persistence_failed, :run, changeset.errors}}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_cutover_rollback, :run_id}}
    end
  end

  defp reference(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_cutover_rollback, :operator_ref}}
  end

  defp database_now do
    case Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, normalize(now)}
      {:error, reason} -> {:error, {:cutover_database_time_failed, reason}}
    end
  end

  defp normalize(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp lock_global! do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["responder-cutover"]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback({:cutover_lock_failed, reason})
    end
  end

  defp kind_rank(:memory), do: 0
  defp kind_rank(:behavior), do: 1
  defp kind_rank(:schedule), do: 2
  defp kind_rank(:episode), do: 3
  defp kind_rank(:wait), do: 4

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
