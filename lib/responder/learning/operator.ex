defmodule Responder.Learning.Operator do
  @moduledoc "Explicit, audited recovery of a deferred learning batch without erasing its cost."
  alias Responder.Learning.{Batches, Rebuilds}
  alias Responder.Operator.Actions

  def retry(id, expected_version, actor_ref, action_ref)
      when is_integer(expected_version) and expected_version >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} ->
        Actions.run(
          %{
            action: :retry,
            action_ref: action_ref,
            actor_ref: actor_ref,
            kind: "learning",
            resource_ref: id,
            request: %{"expected_budget_version" => expected_version, "additional_starts" => 1}
          },
          fn -> Batches.retry_in_transaction(id, expected_version) end
        )

      _ ->
        {:error, :invalid_learning_retry}
    end
  end

  def retry(_, _, _, _), do: {:error, :invalid_learning_retry}

  def rebuild(id, version, generation, selections, actor_ref, action_ref)
      when is_integer(version) and version in 1..9_223_372_036_854_775_807 and
             is_integer(generation) and generation in 1..9_223_372_036_854_775_807 do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, selections} <- Rebuilds.selections(selections) do
      Actions.run(
        %{
          action: :update,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "knowledge_rebuild",
          resource_ref: id,
          request: %{"version" => version, "generation" => generation, "selections" => selections}
        },
        fn -> Rebuilds.request_in_transaction(id, version, generation, selections) end
      )
    else
      _ -> {:error, :invalid_learning_rebuild}
    end
  end

  def rebuild(_, _, _, _, _, _), do: {:error, :invalid_learning_rebuild}

  def reselect(
        id,
        version,
        %{version: target_version, generation: generation} = target,
        selections,
        actor_ref,
        action_ref
      )
      when is_integer(version) and version in 0..2_147_483_647 and is_integer(target_version) and
             target_version in 1..9_223_372_036_854_775_807 and is_integer(generation) and
             generation in 1..9_223_372_036_854_775_807 and map_size(target) == 2 do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, selections} <- Rebuilds.selections(selections) do
      Actions.run(
        %{
          action: :retry,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "knowledge_rebuild",
          resource_ref: id,
          request: %{
            "expected_budget_version" => version,
            "target" => %{"version" => target_version, "generation" => generation},
            "selections" => selections,
            "additional_starts" => 1
          }
        },
        fn -> Rebuilds.reselect_in_transaction(id, version, target, selections) end
      )
    else
      _ -> {:error, :invalid_learning_rebuild}
    end
  end

  def reselect(_, _, _, _, _, _), do: {:error, :invalid_learning_rebuild}
end
