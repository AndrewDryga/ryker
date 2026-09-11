defmodule Responder.FakeRetentionCoopAPI do
  @moduledoc false

  use Agent

  @default_workspace %{
    "branch" => "coop/session",
    "dirty" => false,
    "head" => String.duplicate("a", 40),
    "running" => false,
    "status_digest" => String.duplicate("b", 64),
    "unmerged" => false
  }

  def start_link(options) do
    sessions = Keyword.fetch!(options, :sessions)
    default_workspace = Keyword.get(options, :workspace, @default_workspace)

    Agent.start_link(fn ->
      %{
        calls: [],
        default_workspace: default_workspace,
        fail_first: MapSet.new(Keyword.get(options, :fail_first, [])),
        failed: MapSet.new(),
        offline: Keyword.get(options, :offline, false),
        offline_prefix: Keyword.get(options, :offline_prefix),
        offline_sessions: MapSet.new(Keyword.get(options, :offline_sessions, [])),
        lose_every: Keyword.get(options, :lose_every),
        mutations: 0,
        operations: %{},
        sessions: Map.new(sessions, &{&1["id"], &1}),
        workspaces: Keyword.get(options, :workspaces, %{})
      }
    end)
  end

  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

  def clear_calls(agent), do: Agent.update(agent, &%{&1 | calls: []})

  def remote_session(agent, session_id), do: Agent.get(agent, & &1.sessions[session_id])

  @doc "Simulate a worker outage: every call fails as an unreachable transport."
  def set_offline(agent, offline?) when is_boolean(offline?),
    do: Agent.update(agent, &%{&1 | offline: offline?})

  @doc "Take every session whose remote id starts with this prefix offline."
  def set_offline_prefix(agent, prefix),
    do: Agent.update(agent, &%{&1 | offline_prefix: prefix})

  @doc "Replace the workspace one session reports, so retained work can become clean."
  def set_workspace(agent, session_id, workspace) do
    Agent.update(agent, &put_in(&1, [:workspaces, session_id], workspace))
  end

  def add_session(agent, session, workspace \\ nil) do
    Agent.update(agent, fn state ->
      state = put_in(state, [:sessions, session["id"]], session)

      if workspace,
        do: put_in(state, [:workspaces, session["id"]], workspace),
        else: state
    end)
  end

  def get_session(agent, session_id) do
    Agent.get_and_update(agent, fn state ->
      call = {:get_session, session_id}

      response =
        cond do
          unreachable?(state, session_id) -> offline()
          state.sessions[session_id] -> {:ok, state.sessions[session_id]}
          true -> not_found()
        end

      {response, %{state | calls: [call | state.calls]}}
    end)
  end

  def close_session(agent, session_id, key, revision) do
    body = %{"expected_revision" => revision, "session_id" => session_id}

    mutation(agent, :close, key, body, fn state ->
      session = state.sessions[session_id]

      cond do
        is_nil(session) ->
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

          {{:ok, response}, put_in(state, [:sessions, session_id], closed)}
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
      session = state.sessions[session_id]

      cond do
        is_nil(session) ->
          {not_found(), state}

        session["revision"] != revision ->
          {revision_conflict(), state}

        session["state"] != "closed" ->
          {invalid_state(), state}

        true ->
          operation_id = "op_plan_#{key}"
          reported = Map.get(state.workspaces, session_id, state.default_workspace)

          workspace =
            reported
            |> Map.put("accepted_dirty", reported["dirty"] and accept_dirty)
            |> Map.put("accepted_unmerged", reported["unmerged"] and accept_unmerged)

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
      session = state.sessions[session_id]

      cond do
        is_nil(session) ->
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

          {{:ok, response}, put_in(state, [:sessions, session_id], discarded)}
      end
    end)
  end

  defp mutation(agent, phase, key, body, callback) do
    Agent.get_and_update(agent, fn state ->
      call = {phase, key, body}

      {response, state} =
        cond do
          unreachable?(state, body["session_id"]) ->
            {offline(), state}

          match?(%{body: ^body, phase: ^phase}, state.operations[key]) ->
            {state.operations[key].response, state}

          is_nil(state.operations[key]) ->
            {response, state} = callback.(state)
            {response, store_successful_operation(state, key, phase, body, response)}

          true ->
            {{:error, {:coop_error, 409, "idempotency_conflict", "body changed"}}, state}
        end

      state = %{state | mutations: state.mutations + 1}
      response = maybe_lose_response(response, phase, state)

      response =
        if lost_response?(state, match?({:ok, _document}, response)),
          do: {:error, {:coop_unavailable, :response_lost}},
          else: response

      failed =
        if MapSet.member?(state.fail_first, phase),
          do: MapSet.put(state.failed, phase),
          else: state.failed

      {response, %{state | calls: [call | state.calls], failed: failed}}
    end)
  end

  defp unreachable?(state, session_id) do
    state.offline or MapSet.member?(state.offline_sessions, session_id) or
      (is_binary(state.offline_prefix) and is_binary(session_id) and
         String.starts_with?(session_id, state.offline_prefix))
  end

  # A response lost in transit after the mutation already committed remotely.
  defp lost_response?(%{lose_every: every, mutations: mutations}, true)
       when is_integer(every) and every > 0,
       do: rem(mutations, every) == 0

  defp lost_response?(_state, _succeeded?), do: false

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

  defp offline, do: {:error, {:coop_transport_error, :worker_unreachable}}

  defp revision_conflict,
    do: {:error, {:coop_error, 409, "revision_conflict", "revision changed"}}

  defp invalid_state,
    do: {:error, {:coop_error, 409, "invalid_session_state", "session is not eligible"}}
end
