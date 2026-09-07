defmodule Responder.Delivery.Dispatcher do
  @moduledoc """
  Delivers one host-routed message, admission reaction, or model-requested action under durable custody.

  Platform publishers receive immutable requests without credentials or
  routing authority. Any ambiguous provider result releases the exact intent
  for a bounded retry; a typed receipt is the only way to settle custody.
  """

  alias Responder.Artifacts.Outputs
  alias Responder.Delivery.{Adapters, PlatformActionCustody, ReactionCustody, Request}
  alias Responder.State.Records
  alias Responder.Work.Custody

  @maximum_error_detail_bytes 4_096

  @type result ::
          {:ok,
           :idle
           | {:delivered, :message | :reaction | :action, String.t()}
           | {:deferred, :message | :reaction | :action, String.t(), term()}
           | {:blocked, :message | :reaction | :action, String.t(), term()}}
          | {:error, term()}

  @spec run_once(keyword()) :: result()
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <- claim_next(settings) do
      execute(claim, settings)
    end
  end

  defp claim_next(%{kind: :message} = settings) do
    Custody.claim_next(settings.worker_ref, settings.lease_seconds, :delivery)
  end

  defp claim_next(%{kind: :reaction} = settings) do
    ReactionCustody.claim_next(settings.worker_ref, settings.lease_seconds)
  end

  defp claim_next(%{kind: :action} = settings) do
    PlatformActionCustody.claim_next(settings.worker_ref, settings.lease_seconds)
  end

  defp execute(nil, _settings), do: {:ok, :idle}

  defp execute(claim, %{kind: :message} = settings) do
    with {:ok, request} <- message_request(claim),
         {:ok, receipt} <- publish_with_lease(request, claim, settings),
         {:ok, _settled} <-
           Custody.confirm_delivery(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok, {:delivered, :message, request.ref}}
    else
      {:error, reason} -> handle_message_error(claim, reason, settings)
    end
  end

  defp execute(claim, %{kind: :reaction} = settings) do
    with {:ok, request} <- ReactionCustody.request(claim.reaction),
         {:ok, receipt} <- publish_with_lease(request, claim, settings),
         {:ok, _settled} <-
           ReactionCustody.confirm_delivery(request.ref, claim.lease_ref, receipt) do
      {:ok, {:delivered, :reaction, request.ref}}
    else
      {:error, reason} -> handle_reaction_error(claim, reason, settings)
    end
  end

  defp execute(claim, %{kind: :action} = settings) do
    with {:ok, request} <- PlatformActionCustody.request(claim.action),
         {:ok, receipt} <- publish_with_lease(request, claim, settings),
         {:ok, _settled} <-
           PlatformActionCustody.confirm_delivery(request.ref, claim.lease_ref, receipt) do
      {:ok, {:delivered, :action, request.ref}}
    else
      {:error, reason} -> handle_action_error(claim, reason, settings)
    end
  end

  defp message_request(claim) do
    with {:ok, message, record_refs, artifact_refs} <-
           delivery_message(claim.turn.delivery_document),
         {:ok, records} <- delivery_records(claim.episode.id, record_refs),
         {:ok, artifacts} <- Outputs.fetch_many(claim.turn.id, artifact_refs) do
      document =
        if record_refs == [],
          do: %{"message" => message},
          else: %{"message" => message, "records" => Enum.map(records, &record_document/1)}

      Request.new(%{
        artifacts: Enum.map(artifacts, &artifact_document/1),
        conversation_ref: claim.episode.destination_conversation_ref,
        document: document,
        kind: :message,
        ref: claim.turn.delivery_ref,
        source_item_ref: nil,
        thread_ref: claim.episode.destination_thread_ref,
        transport: claim.episode.destination_transport
      })
    end
  end

  defp delivery_message(%{"message" => message} = document)
       when map_size(document) == 1 and is_binary(message),
       do: {:ok, message, [], []}

  defp delivery_message(
         %{
           "decision_reason" => nil,
           "delivery" => "reply",
           "message" => message,
           "outcome" =>
             %{
               "artifact_refs" => artifact_refs,
               "record_refs" => record_refs,
               "state" => state
             } = outcome
         } = document
       )
       when map_size(document) == 4 and map_size(outcome) == 3 and is_binary(message) and
              is_list(artifact_refs) and is_list(record_refs) and is_binary(state),
       do: {:ok, message, record_refs, artifact_refs}

  defp delivery_message(_document), do: {:error, {:invalid_delivery_message, :document}}

  defp delivery_records(_episode_id, []), do: {:ok, []}

  defp delivery_records(episode_id, refs) do
    case Records.fetch_for_episode(episode_id, refs) do
      {:ok, records} -> {:ok, records}
      {:error, _reason} -> {:error, {:invalid_delivery_message, :record_refs}}
    end
  end

  defp record_document(record) do
    %{
      "kind" => record.kind,
      "payload" => record.payload,
      "ref" => record.ref,
      "status" => Atom.to_string(record.status)
    }
  end

  defp artifact_document(artifact) do
    %{
      "bytes" => artifact.byte_size,
      "data" => artifact.data,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "ref" => artifact.ref,
      "sha256" => artifact.sha256
    }
  end

  defp publish_with_lease(request, claim, settings) do
    caller = self()
    result_ref = make_ref()

    {publisher, monitor} =
      spawn_monitor(fn ->
        supervise_publish(caller, result_ref, request, settings.adapters)
      end)

    cadence_ms = max(div(settings.lease_seconds * 1_000, 3), 1)

    try do
      await_publish(result_ref, publisher, monitor, claim, settings, cadence_ms)
    after
      stop_publish(result_ref, publisher, monitor)
    end
  end

  defp supervise_publish(caller, result_ref, request, adapters) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    owner = self()

    provider =
      spawn_link(fn ->
        result =
          try do
            Adapters.publish(request, adapters)
          catch
            kind, reason -> {:error, {:delivery_publisher_crashed, kind, reason}}
          end

        send(owner, {:delivery_provider_result, self(), result})
      end)

    try do
      receive do
        {:delivery_provider_result, ^provider, result} ->
          send(caller, {result_ref, result})

        {:EXIT, ^provider, reason} ->
          send(caller, {result_ref, {:error, {:delivery_publisher_exit, reason}}})

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          :ok

        {:cancel_publish, ^caller, ^result_ref} ->
          :ok
      end
    after
      provider_monitor = Process.monitor(provider)
      Process.exit(provider, :kill)
      receive do: ({:DOWN, ^provider_monitor, :process, ^provider, _reason} -> :ok)
    end
  end

  defp stop_publish(result_ref, publisher, monitor) do
    # Polling may rescue a renewal exception without exiting the caller. Reap the
    # supervisor only after its linked provider has stopped, then drain our mail.
    cleanup_monitor = Process.monitor(publisher)
    send(publisher, {:cancel_publish, self(), result_ref})
    receive do: ({:DOWN, ^cleanup_monitor, :process, ^publisher, _reason} -> :ok)
    Process.demonitor(monitor, [:flush])

    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp await_publish(result_ref, publisher, monitor, claim, settings, cadence_ms) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])

        case renew_claim(claim, settings) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {:DOWN, ^monitor, :process, ^publisher, reason} ->
        {:error, {:delivery_publisher_exit, reason}}
    after
      cadence_ms ->
        case renew_claim(claim, settings) do
          :ok ->
            await_publish(result_ref, publisher, monitor, claim, settings, cadence_ms)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp renew_claim(claim, %{kind: :message} = settings) do
    case Custody.renew(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _turn} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp renew_claim(claim, %{kind: :reaction} = settings) do
    case ReactionCustody.renew(
           claim.reaction.delivery_ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _reaction} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp renew_claim(claim, %{kind: :action} = settings) do
    case PlatformActionCustody.renew(
           claim.action.action_ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _action} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp defer_message(claim, reason, settings) do
    retry_seconds = retry_delay(reason, claim.turn.delivery_attempt_count, settings)
    {error_code, error_detail} = describe_error(reason)

    case Custody.defer(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           retry_seconds,
           error_code,
           error_detail
         ) do
      {:ok, _turn} -> {:ok, {:deferred, :message, claim.turn.delivery_ref, reason}}
      {:error, defer_reason} -> delivery_error(reason, defer_reason)
    end
  end

  defp handle_message_error(claim, reason, settings) do
    cond do
      lease_error?(reason) ->
        {:error, reason}

      retryable_error?(reason) and claim.turn.delivery_attempt_count < settings.max_attempts ->
        defer_message(claim, reason, settings)

      true ->
        block_message(claim, reason)
    end
  end

  defp block_message(claim, reason) do
    {error_code, error_detail} = describe_error(reason)

    case Custody.block_delivery(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           error_code,
           error_detail
         ) do
      {:ok, _turn} -> {:ok, {:blocked, :message, claim.turn.delivery_ref, reason}}
      {:error, block_reason} -> delivery_error(reason, block_reason)
    end
  end

  defp defer_reaction(claim, reason, settings) do
    retry_seconds = retry_delay(reason, claim.reaction.attempt_count, settings)
    {error_code, error_detail} = describe_error(reason)

    case ReactionCustody.defer(
           claim.reaction.delivery_ref,
           claim.lease_ref,
           retry_seconds,
           error_code,
           error_detail
         ) do
      {:ok, _reaction} -> {:ok, {:deferred, :reaction, claim.reaction.delivery_ref, reason}}
      {:error, defer_reason} -> delivery_error(reason, defer_reason)
    end
  end

  defp handle_reaction_error(claim, reason, settings) do
    cond do
      lease_error?(reason) ->
        {:error, reason}

      retryable_error?(reason) and claim.reaction.attempt_count < settings.max_attempts ->
        defer_reaction(claim, reason, settings)

      true ->
        block_reaction(claim, reason)
    end
  end

  defp block_reaction(claim, reason) do
    {error_code, error_detail} = describe_error(reason)

    case ReactionCustody.block(
           claim.reaction.delivery_ref,
           claim.lease_ref,
           error_code,
           error_detail
         ) do
      {:ok, _reaction} -> {:ok, {:blocked, :reaction, claim.reaction.delivery_ref, reason}}
      {:error, block_reason} -> delivery_error(reason, block_reason)
    end
  end

  defp defer_action(claim, reason, settings) do
    retry_seconds = retry_delay(reason, claim.action.attempt_count, settings)
    {error_code, error_detail} = describe_error(reason)

    case PlatformActionCustody.defer(
           claim.action.action_ref,
           claim.lease_ref,
           retry_seconds,
           error_code,
           error_detail
         ) do
      {:ok, _action} -> {:ok, {:deferred, :action, claim.action.action_ref, reason}}
      {:error, defer_reason} -> delivery_error(reason, defer_reason)
    end
  end

  defp handle_action_error(claim, reason, settings) do
    cond do
      lease_error?(reason) ->
        {:error, reason}

      retryable_error?(reason) and claim.action.attempt_count < settings.max_attempts ->
        defer_action(claim, reason, settings)

      true ->
        block_action(claim, reason)
    end
  end

  defp block_action(claim, reason) do
    {error_code, error_detail} = describe_error(reason)

    case PlatformActionCustody.block(
           claim.action.action_ref,
           claim.lease_ref,
           error_code,
           error_detail
         ) do
      {:ok, _action} -> {:ok, {:blocked, :action, claim.action.action_ref, reason}}
      {:error, block_reason} -> delivery_error(reason, block_reason)
    end
  end

  defp delivery_error(reason, defer_reason),
    do: {:error, {:delivery_dispatch_failed, reason, defer_reason}}

  defp retryable_error?({:delivery_credentials_unavailable, _reason}), do: true
  defp retryable_error?({:delivery_publisher_crashed, _kind, _reason}), do: true
  defp retryable_error?({:delivery_publisher_exit, _reason}), do: true

  defp retryable_error?({:delivery_rate_limited, delay, _reason})
       when is_nil(delay) or (is_integer(delay) and delay > 0),
       do: true

  defp retryable_error?({:delivery_transport_unavailable, _reason}), do: true
  defp retryable_error?({:delivery_uncertain, _reason}), do: true

  defp retryable_error?({:delivery_reconciliation_failed, reason}),
    do: retryable_error?(reason)

  defp retryable_error?({:github_api_error, status, _body}),
    do: retryable_status?(status)

  defp retryable_error?({:slack_http_error, status, _body}),
    do: retryable_status?(status)

  defp retryable_error?({:slack_api_error, error}) do
    error in ~w(fatal_error internal_error ratelimited request_timeout service_unavailable)
  end

  defp retryable_error?(_reason), do: false

  defp retryable_status?(status),
    do: status in [408, 409, 425, 429] or (is_integer(status) and status >= 500)

  defp lease_error?(:work_lease_lost), do: true
  defp lease_error?(:delivery_reaction_lease_lost), do: true
  defp lease_error?(:platform_action_lease_lost), do: true
  defp lease_error?(_reason), do: false

  defp retry_delay(reason, attempt_count, settings) do
    backoff = backoff_delay(attempt_count, settings)

    case provider_retry_delay(reason) do
      delay when is_integer(delay) and delay > 0 -> max(delay, backoff)
      nil -> backoff
    end
  end

  defp backoff_delay(attempt_count, settings) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp provider_retry_delay({:delivery_rate_limited, delay, _reason})
       when is_integer(delay) and delay > 0,
       do: delay

  defp provider_retry_delay({wrapper, reason})
       when wrapper in [:delivery_reconciliation_failed, :delivery_uncertain],
       do: provider_retry_delay(reason)

  defp provider_retry_delay(_reason), do: nil

  defp describe_error(reason) do
    code = reason |> error_atom() |> Atom.to_string()
    detail = reason |> inspect(limit: 20, printable_limit: 3_500, width: 120) |> bound_detail()
    {code, detail}
  end

  defp bound_detail(detail) when byte_size(detail) <= @maximum_error_detail_bytes, do: detail

  defp bound_detail(detail) do
    String.byte_slice(detail, 0, @maximum_error_detail_bytes - 3) <> "..."
  end

  defp error_atom({atom, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _rest}) when is_atom(atom), do: atom
  defp error_atom(atom) when is_atom(atom), do: atom
  defp error_atom(_reason), do: :delivery_failed

  defp settings(options) when is_list(options) do
    allowed = [
      :adapters,
      :kind,
      :lease_seconds,
      :max_attempts,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      validate_settings(%{
        adapters: Keyword.fetch!(options, :adapters),
        kind: Keyword.fetch!(options, :kind),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        max_attempts: Keyword.get(options, :max_attempts, 8),
        retry_base_seconds: Keyword.get(options, :retry_base_seconds, 1),
        retry_max_seconds: Keyword.get(options, :retry_max_seconds, 60),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      })
    else
      {:error, {:invalid_delivery_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_delivery_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_delivery_dispatcher, :options}}

  defp validate_settings(settings) do
    with :ok <- setting(is_map(settings.adapters) and map_size(settings.adapters) > 0, :adapters),
         :ok <- setting(settings.kind in [:message, :reaction, :action], :kind),
         :ok <- setting(positive?(settings.lease_seconds), :lease_seconds),
         :ok <- setting(positive?(settings.max_attempts), :max_attempts),
         :ok <- setting(positive?(settings.retry_base_seconds), :retry_base_seconds),
         :ok <- setting(valid_retry_max?(settings), :retry_max_seconds),
         :ok <- setting(reference?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp valid_retry_max?(settings) do
    positive?(settings.retry_max_seconds) and
      settings.retry_max_seconds >= settings.retry_base_seconds
  end

  defp positive?(value), do: is_integer(value) and value > 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end

  defp setting(true, _field), do: :ok
  defp setting(false, field), do: {:error, {:invalid_delivery_dispatcher, field}}
end
