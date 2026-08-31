defmodule Responder.Retention.Plan do
  @moduledoc """
  Validates Coop's exact public discard-plan envelope.

  A plan is evidence, not deletion authority. Automatic cleanup never accepts
  dirty work, and accepts unmerged commits only when the caller has separately
  proved that this exact Work session was published.
  """

  @outer_fields ~w(operation plan)
  @operation_required ~w(id method resource_id resource_type state)
  @operation_optional ~w(created_at updated_at error_code error_detail)
  @plan_envelope_fields ~w(operation_id plan)
  @plan_fields ~w(revision session_id workspace)
  @workspace_required ~w(branch dirty head running status_digest unmerged)
  @workspace_optional ~w(accepted_dirty accepted_unmerged)
  @digest ~r/\A[0-9a-f]{64}\z/
  @head ~r/\A[0-9a-f]{40,64}\z/

  @spec prepare(map(), String.t(), pos_integer(), boolean()) ::
          {:ok, map()} | {:error, {:invalid_discard_plan, atom()}}
  def prepare(response, session_id, revision, accept_unmerged)
      when is_map(response) and is_binary(session_id) and is_integer(revision) and revision > 0 and
             is_boolean(accept_unmerged) do
    with :ok <- exact_fields(response, @outer_fields, [], :envelope),
         {:ok, operation} <- operation(response["operation"], session_id) do
      plan_document(
        response["plan"],
        operation["id"],
        session_id,
        revision,
        accept_unmerged
      )
    end
  end

  def prepare(_response, _session_id, _revision, _accept_unmerged),
    do: {:error, {:invalid_discard_plan, :document}}

  @spec discardable?(map()) :: boolean()
  def discardable?(%{
        "workspace" => %{
          "accepted_unmerged" => accepted_unmerged,
          "dirty" => dirty,
          "running" => running,
          "unmerged" => unmerged
        }
      }) do
    not dirty and not running and (not unmerged or accepted_unmerged)
  end

  def discardable?(_plan), do: false

  defp operation(value, session_id) when is_map(value) do
    with :ok <- exact_fields(value, @operation_required, @operation_optional, :operation),
         :ok <- reference(value["id"], :operation_id),
         true <- value["method"] == "PlanDiscard" or error(:operation_method),
         true <- value["state"] == "succeeded" or error(:operation_state),
         true <- value["resource_type"] == "discard_plan" or error(:operation_resource),
         true <- value["resource_id"] == session_id or error(:operation_identity) do
      {:ok, value}
    else
      {:error, _reason} = result -> result
      false -> {:error, {:invalid_discard_plan, :operation}}
    end
  end

  defp operation(_value, _session_id), do: {:error, {:invalid_discard_plan, :operation}}

  defp plan_document(value, operation_id, session_id, revision, accept_unmerged)
       when is_map(value) do
    with :ok <- exact_fields(value, @plan_envelope_fields, [], :plan_envelope),
         true <- value["operation_id"] == operation_id or error(:plan_operation_identity),
         plan when is_map(plan) <- value["plan"],
         :ok <- exact_fields(plan, @plan_fields, [], :plan),
         true <- plan["session_id"] == session_id or error(:session_identity),
         true <- plan["revision"] == revision or error(:session_revision),
         {:ok, workspace} <- workspace(plan["workspace"], accept_unmerged) do
      {:ok,
       %{
         "operation_id" => operation_id,
         "revision" => revision,
         "session_id" => session_id,
         "workspace" => workspace
       }}
    else
      {:error, _reason} = result -> result
      _invalid -> {:error, {:invalid_discard_plan, :plan}}
    end
  end

  defp plan_document(_value, _operation_id, _session_id, _revision, _accept_unmerged),
    do: {:error, {:invalid_discard_plan, :plan_envelope}}

  defp workspace(value, accept_unmerged) when is_map(value) do
    with :ok <- exact_fields(value, @workspace_required, @workspace_optional, :workspace),
         :ok <- optional_git_head(value["head"]),
         :ok <- bounded_string(value["branch"], 1_024, :branch),
         :ok <- digest(value["status_digest"], :status_digest),
         :ok <- boolean(value["dirty"], :dirty),
         :ok <- boolean(value["unmerged"], :unmerged),
         :ok <- boolean(value["running"], :running),
         :ok <- boolean(Map.get(value, "accepted_dirty", false), :accepted_dirty),
         :ok <- boolean(Map.get(value, "accepted_unmerged", false), :accepted_unmerged),
         true <- not value["running"] or error(:running),
         true <- not Map.get(value, "accepted_dirty", false) or error(:accepted_dirty),
         expected_accepted_unmerged = value["unmerged"] and accept_unmerged,
         true <-
           Map.get(value, "accepted_unmerged", false) == expected_accepted_unmerged or
             error(:accepted_unmerged) do
      {:ok,
       %{
         "accepted_dirty" => false,
         "accepted_unmerged" => expected_accepted_unmerged,
         "branch" => value["branch"],
         "dirty" => value["dirty"],
         "head" => value["head"],
         "running" => false,
         "status_digest" => value["status_digest"],
         "unmerged" => value["unmerged"]
       }}
    else
      {:error, _reason} = result -> result
      false -> {:error, {:invalid_discard_plan, :workspace}}
    end
  end

  defp workspace(_value, _accept_unmerged),
    do: {:error, {:invalid_discard_plan, :workspace}}

  defp exact_fields(value, required, optional, field) do
    keys = Map.keys(value)

    if Enum.all?(required, &(&1 in keys)) and keys -- (required ++ optional) == [],
      do: :ok,
      else: error(field)
  end

  defp optional_git_head(""), do: :ok

  defp optional_git_head(value) when is_binary(value) do
    if Regex.match?(@head, value), do: :ok, else: error(:head)
  end

  defp optional_git_head(_value), do: error(:head)

  defp digest(value, _field) when is_binary(value) do
    if Regex.match?(@digest, value), do: :ok, else: error(:status_digest)
  end

  defp digest(_value, field), do: error(field)

  defp reference(value, field), do: bounded_string(value, 1_024, field, false)

  defp bounded_string(value, maximum, field, allow_empty \\ true)

  defp bounded_string(value, maximum, _field, allow_empty) when is_binary(value) do
    minimum = if allow_empty, do: 0, else: 1

    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         byte_size(value) in minimum..maximum,
       do: :ok,
       else: error(:string)
  end

  defp bounded_string(_value, _maximum, field, _allow_empty), do: error(field)

  defp boolean(value, _field) when is_boolean(value), do: :ok
  defp boolean(_value, field), do: error(field)

  defp error(field), do: {:error, {:invalid_discard_plan, field}}
end
