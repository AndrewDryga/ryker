defmodule Ryker.Retention.Executor do
  @moduledoc """
  Reconciles one leased Work session against Coop's exact public resources.

  Every mutation key and body is reconstructed from the durable session row.
  A lost response therefore retries byte-for-byte, while crossed authority or
  an unsafe discard plan fails closed without touching another workspace.
  """

  alias Ryker.Retention.{Custody, Plan}
  alias Ryker.Work.Session

  @session_states ~w(open exhausted closed discarded)

  @spec run(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def run(%{lease_ref: lease_ref, session: %Session{} = session}, options)
      when is_binary(lease_ref) do
    with {:ok, settings} <- settings(options) do
      execute(session.cleanup_status, session, lease_ref, settings)
    end
  rescue
    error -> {:error, {:retention_executor_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:retention_executor_caught, kind, inspect(reason)}}
  end

  def run(_claim, _options), do: {:error, {:invalid_retention_executor, :claim}}

  defp execute(:close_pending, %Session{coop_session_id: nil} = session, lease_ref, _settings) do
    with {:ok, settled} <- Custody.settle_absent(session.id, lease_ref) do
      {:ok, %{phase: :discarded, session: settled}}
    end
  end

  defp execute(:close_pending, session, lease_ref, settings) do
    with {:ok, remote} <- fetch_session(session, settings) do
      close_from_state(remote["state"], session, lease_ref, remote, settings)
    end
  end

  defp execute(:plan_pending, session, lease_ref, settings) do
    with {:ok, remote} <- fetch_session(session, settings) do
      plan_from_state(remote["state"], session, lease_ref, remote, settings)
    end
  end

  defp execute(:discard_pending, session, lease_ref, settings) do
    with {:ok, remote} <- fetch_session(session, settings) do
      discard_from_state(remote["state"], session, lease_ref, remote, settings)
    end
  end

  defp execute(_status, _session, _lease_ref, _settings),
    do: {:error, {:invalid_retention_executor, :status}}

  defp close_from_state("discarded", session, lease_ref, _remote, _settings),
    do: settle_already_discarded(session, lease_ref)

  defp close_from_state("closed", session, lease_ref, _remote, settings),
    do: mark_closed(session, lease_ref, settings)

  defp close_from_state(state, session, lease_ref, remote, settings)
       when state in ["open", "exhausted"] do
    with {:ok, revision} <- revision(remote),
         {:ok, frozen} <- Custody.freeze_close_revision(session.id, lease_ref, revision) do
      close_remote(frozen, lease_ref, settings)
    end
  end

  defp close_from_state(_state, _session, _lease_ref, _remote, _settings),
    do: {:error, {:coop_protocol_error, :session_state}}

  defp close_remote(session, lease_ref, settings) do
    key = Custody.close_key(session)

    case api_call(settings, fn ->
           settings.api.close_session(
             settings.client,
             session.coop_session_id,
             key,
             session.close_expected_revision
           )
         end) do
      {:ok, response} -> handle_close_response(response, session, lease_ref, settings)
      {:error, reason} -> handle_close_error(reason, session, lease_ref)
    end
  end

  defp handle_close_response(response, session, lease_ref, settings) do
    case mutation_session(response, "CloseSession", session, ~w(closed discarded)) do
      {:ok, %{"state" => "discarded"}} -> settle_already_discarded(session, lease_ref)
      {:ok, %{"state" => "closed"}} -> mark_closed(session, lease_ref, settings)
      {:error, reason} -> {:error, {:coop_mutation_response_unresolved, :close, reason}}
    end
  end

  defp handle_close_error(
         {:coop_error, 409, "revision_conflict", _detail} = reason,
         session,
         lease_ref
       ) do
    with {:ok, _advanced} <-
           Custody.advance_close(session.id, lease_ref, session.close_generation) do
      {:error, {:retention_generation_spent, :close, reason}}
    end
  end

  defp handle_close_error(
         {:coop_error, status, "session_cleanup_error", _detail} = reason,
         session,
         lease_ref
       )
       when status >= 500 do
    with {:ok, _advanced} <-
           Custody.advance_close(session.id, lease_ref, session.close_generation) do
      {:error, {:retention_generation_spent, :close, reason}}
    end
  end

  defp handle_close_error(reason, _session, _lease_ref), do: {:error, reason}

  defp mark_closed(session, lease_ref, settings) do
    with {:ok, stored} <-
           Custody.mark_closed(
             session.id,
             lease_ref,
             settings.closed_session_grace_seconds
           ) do
      {:ok, %{phase: :closed, session: stored}}
    end
  end

  defp plan_from_state("discarded", session, lease_ref, _remote, _settings),
    do: settle_already_discarded(session, lease_ref)

  defp plan_from_state("closed", session, lease_ref, remote, settings) do
    accept_unmerged = session.discard_plan_accept_unmerged or Custody.published?(session)

    with {:ok, revision} <- revision(remote),
         {:ok, frozen} <-
           Custody.freeze_plan_revision(session.id, lease_ref, revision, accept_unmerged) do
      plan_remote(frozen, lease_ref, settings)
    end
  end

  defp plan_from_state(_state, _session, _lease_ref, _remote, _settings),
    do: {:error, {:coop_protocol_error, :discard_plan_session_state}}

  defp plan_remote(session, lease_ref, settings) do
    key = Custody.plan_key(session)

    case api_call(settings, fn ->
           settings.api.plan_discard(
             settings.client,
             session.coop_session_id,
             key,
             session.discard_plan_expected_revision,
             false,
             session.discard_plan_accept_unmerged
           )
         end) do
      {:ok, response} -> handle_plan_response(response, session, lease_ref, settings)
      {:error, reason} -> handle_plan_error(reason, session, lease_ref)
    end
  end

  defp handle_plan_response(response, session, lease_ref, settings) do
    result =
      with {:ok, plan} <-
             Plan.prepare(
               response,
               session.coop_session_id,
               session.discard_plan_expected_revision,
               session.discard_plan_accept_unmerged
             ),
           {:ok, stored} <-
             Custody.store_plan(
               session.id,
               lease_ref,
               plan,
               settings.retained_recheck_seconds
             ) do
        phase = if stored.cleanup_status == :retained, do: :retained, else: :planned
        {:ok, %{phase: phase, session: stored}}
      end

    case result do
      {:ok, _execution} = success -> success
      {:error, reason} -> {:error, {:coop_mutation_response_unresolved, :plan, reason}}
    end
  end

  defp handle_plan_error(
         {:coop_error, 409, code, _detail} = reason,
         session,
         lease_ref
       )
       when code in ["revision_conflict", "discard_plan_stale"] do
    with {:ok, _advanced} <-
           Custody.advance_plan(session.id, lease_ref, session.discard_plan_generation) do
      {:error, {:retention_generation_spent, :plan, reason}}
    end
  end

  defp handle_plan_error(reason, _session, _lease_ref), do: {:error, reason}

  defp discard_from_state("discarded", session, lease_ref, _remote, _settings),
    do: settle_already_discarded(session, lease_ref)

  defp discard_from_state("closed", session, lease_ref, _remote, settings) do
    key = Custody.discard_key(session)

    case api_call(settings, fn ->
           settings.api.discard_session(
             settings.client,
             session.coop_session_id,
             key,
             session.discard_plan_operation_id
           )
         end) do
      {:ok, response} -> handle_discard_response(response, session, lease_ref, key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_from_state(_state, _session, _lease_ref, _remote, _settings),
    do: {:error, {:coop_protocol_error, :discard_session_state}}

  defp handle_discard_response(response, session, lease_ref, key) do
    case mutation_session(response, "Discard", session, ["discarded"]) do
      {:ok, _remote} ->
        with {:ok, stored} <-
               Custody.settle_discard(
                 session.id,
                 lease_ref,
                 key,
                 session.coop_session_id
               ) do
          {:ok, %{phase: :discarded, session: stored}}
        end

      {:error, reason} ->
        {:error, {:coop_mutation_response_unresolved, :discard, reason}}
    end
  end

  defp settle_already_discarded(session, lease_ref) do
    with {:ok, stored} <-
           Custody.settle_remote_discarded(session.id, lease_ref, session.coop_session_id) do
      {:ok, %{phase: :discarded, session: stored}}
    end
  end

  defp fetch_session(session, settings) do
    with {:ok, remote} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, session.coop_session_id)
           end),
         :ok <- exact_session(session, remote, @session_states) do
      {:ok, remote}
    end
  end

  defp mutation_session(
         %{"operation" => operation, "session" => remote},
         method,
         session,
         states
       )
       when is_map(operation) and is_map(remote) do
    with :ok <- exact_operation(operation, method, "session", session.coop_session_id),
         :ok <- exact_session(session, remote, states) do
      {:ok, remote}
    end
  end

  defp mutation_session(_response, _method, _session, _states),
    do: {:error, {:coop_protocol_error, :mutation_response}}

  defp exact_operation(
         %{
           "id" => id,
           "method" => method,
           "resource_id" => resource_id,
           "resource_type" => resource_type,
           "state" => "succeeded"
         },
         method,
         resource_type,
         resource_id
       ),
       do: reference(id, :operation_id)

  defp exact_operation(%{"method" => _method}, _expected, _type, _id),
    do: {:error, {:coop_protocol_error, :operation_identity}}

  defp exact_operation(_operation, _method, _type, _id),
    do: {:error, {:coop_protocol_error, :operation_resource}}

  defp exact_session(
         expected,
         %{
           "external_ref" => external_ref,
           "id" => id,
           "policy" => policy,
           "policy_digest" => policy_digest,
           "state" => state
         },
         allowed_states
       ) do
    cond do
      id != expected.coop_session_id or reference(id, :session_id) != :ok ->
        {:error, {:coop_protocol_error, :session_identity}}

      state not in allowed_states ->
        {:error, {:coop_protocol_error, :session_state}}

      policy != expected.policy or policy_digest != expected.policy_digest or
          external_ref != Session.coop_task_ref(expected) ->
        {:error, {:coop_protocol_error, :session_authority}}

      true ->
        :ok
    end
  end

  defp exact_session(_expected, _remote, _allowed_states),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp revision(_remote), do: {:error, {:coop_protocol_error, :session_revision}}

  defp api_call(_settings, callback) do
    callback.()
  rescue
    error -> {:error, {:coop_transport_error, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:coop_transport_error, {kind, reason}}}
  end

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) do
      settings(Map.new(options))
    else
      {:error, {:invalid_retention_executor, :options}}
    end
  end

  defp settings(%{} = options) do
    allowed = [:api, :client, :closed_session_grace_seconds, :retained_recheck_seconds]

    if Map.keys(options) -- allowed == [] and Map.has_key?(options, :client) do
      settings = %{
        api: Map.get(options, :api, Ryker.Coop.Client),
        client: options.client,
        closed_session_grace_seconds: Map.get(options, :closed_session_grace_seconds, 900),
        retained_recheck_seconds: Map.get(options, :retained_recheck_seconds, 21_600)
      }

      if is_atom(settings.api) and is_integer(settings.closed_session_grace_seconds) and
           settings.closed_session_grace_seconds >= 0 and
           is_integer(settings.retained_recheck_seconds) and
           settings.retained_recheck_seconds > 0,
         do: {:ok, settings},
         else: {:error, {:invalid_retention_executor, :options}}
    else
      {:error, {:invalid_retention_executor, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_retention_executor, :options}}

  defp reference(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:coop_protocol_error, :reference}}
  end

  defp reference(_value, field), do: {:error, {:coop_protocol_error, field}}
end
