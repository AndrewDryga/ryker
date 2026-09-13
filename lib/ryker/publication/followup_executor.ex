defmodule Ryker.Publication.FollowupExecutor do
  @moduledoc false

  alias Ryker.Delivery.Adapters
  alias Ryker.Publication.{Callback, Followups}

  def run_poll(
        %{followup: followup, lease_ref: lease_ref, publication: publication} = claim,
        options
      ) do
    with {:ok, settings} <- settings(options) do
      run_poll_with_settings(claim, followup, publication, lease_ref, settings)
    end
  end

  def run_poll(_claim, _options), do: {:error, {:invalid_publication_followup_executor, :claim}}

  def run_delivery(%{event: event, lease_ref: lease_ref} = claim, options) do
    with {:ok, settings} <- settings(options),
         {:ok, event} <- settings.custody.admit_wakeup(event.ref, lease_ref),
         {:ok, request} <- settings.custody.delivery_request(event),
         {:ok, receipt} <-
           leased_call(claim, :delivery, settings, fn ->
             Adapters.publish(request, settings.adapters)
           end),
         {:ok, stored} <- settings.custody.confirm_delivery(event.ref, lease_ref, receipt) do
      {:ok, %{event: stored, phase: :delivery, receipt: receipt}}
    end
  end

  def run_delivery(_claim, _options),
    do: {:error, {:invalid_publication_followup_executor, :claim}}

  defp run_poll_with_settings(claim, followup, publication, lease_ref, settings) do
    if is_binary(followup.verification_event_ref) and is_nil(followup.verified_at),
      do: reconcile_verification(publication, lease_ref, settings),
      else: poll_publication(claim, publication, lease_ref, settings)
  end

  defp reconcile_verification(publication, lease_ref, settings) do
    case settings.custody.reconcile_verification(
           publication.ref,
           lease_ref,
           settings.interval_seconds
         ) do
      {:ok, updated} -> {:ok, %{phase: :verification, followup: updated}}
      {:error, _reason} = error -> error
    end
  end

  defp poll_publication(claim, publication, lease_ref, settings) do
    with {:ok, status} <-
           leased_call(claim, :poll, settings, fn ->
             settings.api.get_publication_status(
               settings.client,
               publication.github_repository,
               publication.pull_request_number
             )
           end),
         {:ok, updated} <-
           settings.custody.store_poll(
             publication.ref,
             lease_ref,
             status,
             settings.interval_seconds
           ) do
      {:ok, %{phase: :poll, followup: updated}}
    end
  end

  defp leased_call(claim, phase, settings, callback) do
    result_ref = make_ref()

    {pid, monitor} =
      Callback.start(result_ref, fn ->
        try do
          callback.()
        rescue
          exception ->
            {:error, {:publication_followup_callback_crashed, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {:publication_followup_callback_crashed, kind, reason}}
        end
      end)

    cadence_ms = max(div(settings.lease_seconds * 1_000, 3), 1)

    try do
      await_call(result_ref, pid, monitor, claim, phase, settings, cadence_ms)
    after
      Callback.finish(pid, monitor, result_ref)
    end
  end

  defp await_call(result_ref, pid, monitor, claim, phase, settings, cadence_ms) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])

        case renew(claim, phase, settings) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:publication_followup_callback_exit, reason}}
    after
      cadence_ms ->
        case renew(claim, phase, settings) do
          :ok ->
            await_call(result_ref, pid, monitor, claim, phase, settings, cadence_ms)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp renew(claim, :poll, settings) do
    case settings.custody.renew_poll(
           claim.publication.ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _followup} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp renew(claim, :delivery, settings) do
    case settings.custody.renew_delivery(
           claim.event.ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp settings(options) when is_list(options) do
    allowed = [:adapters, :api, :client, :custody, :interval_seconds, :lease_seconds]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      values = %{
        adapters: Keyword.fetch!(options, :adapters),
        api: Keyword.fetch!(options, :api),
        client: Keyword.fetch!(options, :client),
        custody: Keyword.get(options, :custody, Followups),
        interval_seconds: Keyword.get(options, :interval_seconds, 120),
        lease_seconds: Keyword.get(options, :lease_seconds, 60)
      }

      with true <- callback?(values.api, :get_publication_status, 3),
           true <- custody?(values.custody),
           true <- is_map(values.adapters) and map_size(values.adapters) > 0,
           true <- positive?(values.interval_seconds),
           true <- positive?(values.lease_seconds) do
        {:ok, values}
      else
        false -> {:error, {:invalid_publication_followup_executor, :settings}}
      end
    else
      {:error, {:invalid_publication_followup_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_publication_followup_executor, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_publication_followup_executor, :options}}

  defp custody?(module) do
    Enum.all?(
      [
        admit_wakeup: 2,
        confirm_delivery: 3,
        delivery_request: 1,
        reconcile_verification: 3,
        renew_delivery: 3,
        renew_poll: 3,
        store_poll: 4
      ],
      fn {function, arity} -> callback?(module, function, arity) end
    )
  end

  defp callback?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  defp positive?(value), do: is_integer(value) and value > 0
end
