defmodule Responder.FakeRetentionCoopAPI do
  @moduledoc false

  use Agent

  def start_link(options) do
    session = Keyword.fetch!(options, :session)

    Agent.start_link(fn ->
      %{
        calls: [],
        fail_first: MapSet.new(Keyword.get(options, :fail_first, [])),
        failed: MapSet.new(),
        operations: %{},
        session: session,
        workspace:
          Keyword.get(options, :workspace, %{
            "branch" => "coop/session",
            "dirty" => false,
            "head" => String.duplicate("a", 40),
            "running" => false,
            "status_digest" => String.duplicate("b", 64),
            "unmerged" => false
          })
      }
    end)
  end

  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))
  def session(agent), do: Agent.get(agent, & &1.session)

  def get_session(agent, session_id) do
    Agent.get_and_update(agent, fn state ->
      call = {:get_session, session_id}
      response = if state.session["id"] == session_id, do: {:ok, state.session}, else: not_found()
      {response, %{state | calls: [call | state.calls]}}
    end)
  end

  def close_session(agent, session_id, key, revision) do
    body = %{"expected_revision" => revision, "session_id" => session_id}

    mutation(agent, :close, key, body, fn state ->
      session = state.session

      cond do
        session["id"] != session_id ->
          {not_found(), state}

        session["revision"] != revision ->
          {revision_conflict(), state}

        session["state"] not in ["open", "exhausted"] ->
          {invalid_state(), state}

        true ->
          closed = %{session | "revision" => revision + 1, "state" => "closed"}

          response = %{
            "operation" => operation("op_close_#{key}", "CloseSession", "session", session_id),
            "session" => closed
          }

          {{:ok, response}, %{state | session: closed}}
      end
    end)
  end

  def plan_discard(agent, session_id, key, revision, accept_dirty, accept_unmerged) do
    body = %{
      "accept_dirty" => accept_dirty,
      "accept_unmerged" => accept_unmerged,
      "expected_revision" => revision,
      "session_id" => session_id
    }

    mutation(agent, :plan, key, body, fn state ->
      session = state.session

      cond do
        session["id"] != session_id ->
          {not_found(), state}

        session["revision"] != revision ->
          {revision_conflict(), state}

        session["state"] != "closed" ->
          {invalid_state(), state}

        true ->
          operation_id = "op_plan_#{key}"

          workspace =
            state.workspace
            |> Map.put("accepted_dirty", state.workspace["dirty"] and accept_dirty)
            |> Map.put(
              "accepted_unmerged",
              state.workspace["unmerged"] and accept_unmerged
            )

          response = %{
            "operation" => operation(operation_id, "PlanDiscard", "discard_plan", session_id),
            "plan" => %{
              "operation_id" => operation_id,
              "plan" => %{
                "revision" => revision,
                "session_id" => session_id,
                "workspace" => workspace
              }
            }
          }

          {{:ok, response}, state}
      end
    end)
  end

  def discard_session(agent, session_id, key, plan_operation_id) do
    body = %{"plan_operation_id" => plan_operation_id, "session_id" => session_id}

    mutation(agent, :discard, key, body, fn state ->
      session = state.session

      cond do
        session["id"] != session_id ->
          {not_found(), state}

        session["state"] != "closed" ->
          {invalid_state(), state}

        not Enum.any?(state.operations, fn {_key, operation} ->
          operation.phase == :plan and
              match?(
                {:ok, %{"plan" => %{"operation_id" => ^plan_operation_id}}},
                operation.response
              )
        end) ->
          {{:error, {:coop_error, 409, "discard_plan_stale", "unknown plan"}}, state}

        true ->
          discarded = %{
            session
            | "revision" => session["revision"] + 1,
              "state" => "discarded"
          }

          response = %{
            "operation" => operation("op_discard_#{key}", "Discard", "session", session_id),
            "session" => discarded
          }

          {{:ok, response}, %{state | session: discarded}}
      end
    end)
  end

  defp mutation(agent, phase, key, body, callback) do
    Agent.get_and_update(agent, fn state ->
      call = {phase, key, body}

      {response, state} =
        case state.operations[key] do
          %{body: ^body, phase: ^phase, response: response} ->
            {response, state}

          nil ->
            {response, state} = callback.(state)
            {response, store_successful_operation(state, key, phase, body, response)}

          _different ->
            {{:error, {:coop_error, 409, "idempotency_conflict", "body changed"}}, state}
        end

      response = maybe_lose_response(response, phase, state)

      failed =
        if MapSet.member?(state.fail_first, phase),
          do: MapSet.put(state.failed, phase),
          else: state.failed

      {response, %{state | calls: [call | state.calls], failed: failed}}
    end)
  end

  defp store_successful_operation(state, key, phase, body, {:ok, _} = response) do
    put_in(state, [:operations, key], %{body: body, phase: phase, response: response})
  end

  defp store_successful_operation(state, _key, _phase, _body, _response), do: state

  defp maybe_lose_response({:ok, _document} = response, phase, state) do
    if MapSet.member?(state.fail_first, phase) and not MapSet.member?(state.failed, phase),
      do: {:error, {:coop_unavailable, :response_lost}},
      else: response
  end

  defp maybe_lose_response(response, _phase, _state), do: response

  defp operation(id, method, resource_type, resource_id) do
    %{
      "id" => id,
      "method" => method,
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp not_found, do: {:error, {:coop_error, 404, "not_found", "resource not found"}}

  defp revision_conflict,
    do: {:error, {:coop_error, 409, "revision_conflict", "revision changed"}}

  defp invalid_state,
    do: {:error, {:coop_error, 409, "invalid_session_state", "session is not eligible"}}
end
