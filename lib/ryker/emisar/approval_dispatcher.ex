defmodule Ryker.Emisar.ApprovalDispatcher do
  @moduledoc """
  Claims and advances one durable Emisar approval monitor.

  Remote reads happen outside PostgreSQL transactions. The lease fences every
  observation, and only an exact terminal identity can create the trusted
  continuation input.
  """
  alias Ryker.Adapter
  alias Ryker.Backoff
  alias Ryker.Emisar.{Approval, Approvals}
  alias Ryker.Maps
  alias Ryker.Reference
  require Logger

  @fields [
    :api,
    :client,
    :connection_ref,
    :lease_seconds,
    :poll_seconds,
    :presentation,
    :presenter,
    :retry_base_seconds,
    :retry_max_seconds,
    :wait_seconds,
    :worker_ref
  ]
  @card_lock_poll_ms 50
  # What approvers read in Emisar about a request Ryker withdrew.
  @withdrawal_reason "The Ryker request that asked for this no longer needs it."

  @type result ::
          {:ok,
           :idle
           | {:closed, [String.t()]}
           | {:monitoring, String.t(), String.t()}
           | {:resumed, String.t(), String.t()}
           | {:deferred, String.t(), term()}
           | {:blocked, String.t(), term()}}
          | {:error, term()}

  @spec run_once(keyword() | map()) :: result()
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, closed} <- close_ended(settings),
         {:ok, claim} <-
           Approvals.claim_next(
             settings.connection_ref,
             settings.worker_ref,
             settings.lease_seconds
           ) do
      execute(claim, settings, closed)
    end
  end

  # Busy accounts may never go idle. Retire one ended watch on every cycle,
  # before taking a polling lease, so cleanup and observation both progress.
  defp close_ended(settings) do
    case Approvals.close_ended(settings.connection_ref) do
      {:ok, closed} ->
        Enum.each(closed, &withdraw(&1, settings))
        {:ok, closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(nil, _settings, []), do: {:ok, :idle}

  defp execute(nil, _settings, closed),
    do: {:ok, {:closed, Enum.map(closed, & &1.request_id)}}

  defp execute(claim, settings, _closed) do
    case settings.api.wait_for_run(settings.client, claim.approval.run_id, wait(claim, settings)) do
      {:ok, state} ->
        observe_presented(claim, state, settings)

      {:error, reason} ->
        handle_error(claim, reason, settings)

      invalid ->
        handle_error(claim, {:emisar_protocol_error, {:api_result, invalid}}, settings)
    end
  end

  # Emisar asks a client to cancel a run it no longer needs rather than leave
  # the request open until someone decides or it expires. A closed Chat task's
  # approval stayed open (2026-10-12): anyone could still approve it, and the
  # action would have run with nothing waiting for its result. A watch blocked
  # by its card can still reach Emisar. Try withdrawing its exact pending run
  # too; a run already sent to a runner is the console operator's to stop.
  defp withdraw(%Approval{status: watch, remote_status: status} = approval, settings)
       when watch in [:monitoring, :blocked] and status in ["pending", "pending_approval"] do
    case settings.api.cancel_run(settings.client, approval.run_id, @withdrawal_reason) do
      {:ok, state} ->
        withdrawn(approval, state, settings)

      {:error, reason} ->
        Logger.warning(
          "Emisar approval #{approval.request_id} stays open until it expires: " <>
            "withdrawing its run failed: #{inspect(reason)}"
        )
    end
  end

  defp withdraw(_approval, _settings), do: :ok

  # The card shows the withdrawn run like any other that ended; a card that
  # cannot be drawn now keeps the row, which Chat reads, and logs why.
  defp withdrawn(approval, state, settings) do
    with {:ok, _closed} <-
           Approvals.record_withdrawal(settings.connection_ref, approval.request_id, state),
         :ok <- settings.presenter.publish(approval, state, settings.presentation) do
      :ok
    else
      failure ->
        Logger.info(
          "Emisar approval #{approval.request_id} was withdrawn; its card was not redrawn: " <>
            inspect(failure)
        )
    end
  end

  # A new approval is read at once, so its card appears without a wait. Once
  # the card shows the run, Emisar answers when the run changes or the wait
  # ends: read every few seconds instead, each approval wrote its row about
  # 86,000 times a day while a person took their time.
  defp wait(%{approval: %{last_observed_at: nil}}, _settings), do: 0
  defp wait(_claim, settings), do: settings.wait_seconds

  defp observe_presented(claim, state, settings) do
    request_id = claim.approval.request_id

    case Approvals.authorize_presentation(
           settings.connection_ref,
           request_id,
           claim.lease_ref,
           state,
           settings.lease_seconds
         ) do
      {:ok, approval} -> present(approval, claim, state, settings)
      {:error, reason} -> handle_error(claim, reason, settings)
    end
  end

  # The approvals one reply asked for are drawn on one message, and the slots
  # read them at the same time: the two of one turn are new together and both
  # read at once. Each drew the other as its row last stored it, so the update
  # that landed last could show the other before its own update, and nothing
  # drew it again until that approval changed (2026-10-08). One slot at a time
  # draws a task's card and stores what it drew.
  defp present(approval, claim, state, settings) do
    lock = {{__MODULE__, approval.episode_id}, self()}
    deadline = System.monotonic_time(:millisecond) + div(settings.lease_seconds * 1_000, 4)

    if acquire_card(lock, deadline) do
      try do
        present_locked(approval, claim, state, settings)
      after
        :global.del_lock(lock, [node()])
      end
    else
      handle_error(claim, :emisar_approval_card_busy, settings)
    end
  end

  defp acquire_card(lock, deadline) do
    cond do
      :global.set_lock(lock, [node()], 0) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@card_lock_poll_ms)
        acquire_card(lock, deadline)
    end
  end

  defp present_locked(approval, claim, state, settings) do
    request_id = approval.request_id

    case settings.presenter.publish(approval, state, settings.presentation) do
      :ok ->
        case Approvals.observe(
               settings.connection_ref,
               request_id,
               claim.lease_ref,
               state,
               settings.poll_seconds
             ) do
          {:ok, %{status: :monitoring}} ->
            {:ok, {:monitoring, request_id, state.status}}

          {:ok, %{status: :resumed}} ->
            {:ok, {:resumed, request_id, state.status}}

          {:error, reason} ->
            handle_error(claim, reason, settings)
        end

      {:error, reason} ->
        classification =
          if settings.presenter.permanent?(reason),
            do: {:emisar_approval_presentation_permanent, reason},
            else: {:emisar_approval_presentation_unavailable, reason}

        handle_error(claim, classification, settings)

      invalid ->
        handle_error(
          claim,
          {:emisar_protocol_error, {:presentation_result, invalid}},
          settings
        )
    end
  end

  defp handle_error(claim, reason, settings) do
    request_id = claim.approval.request_id

    if permanent?(reason) do
      case Approvals.block(settings.connection_ref, request_id, claim.lease_ref, reason) do
        {:ok, _approval} -> {:ok, {:blocked, request_id, reason}}
        {:error, block_reason} -> custody_error(reason, block_reason)
      end
    else
      delay =
        Backoff.delay(
          claim.approval.failure_count + 1,
          settings.retry_base_seconds,
          settings.retry_max_seconds
        )

      case Approvals.defer(
             settings.connection_ref,
             request_id,
             claim.lease_ref,
             delay,
             reason
           ) do
        {:ok, _approval} -> {:ok, {:deferred, request_id, reason}}
        {:error, defer_reason} -> custody_error(reason, defer_reason)
      end
    end
  end

  defp permanent?(:emisar_approval_identity_mismatch), do: true
  defp permanent?({:emisar_approval_presentation_permanent, _reason}), do: true
  defp permanent?({:emisar_protocol_error, _reason}), do: true
  defp permanent?({:invalid_emisar_client, _reason}), do: true

  # 408, 425 and 429 ask for the same request again later; every other 4xx is final.
  defp permanent?({:emisar_http_error, status, _detail})
       when status in 400..499 and status not in [408, 425, 429],
       do: true

  defp permanent?(_reason), do: false

  defp custody_error(original, custody),
    do: {:error, {:emisar_approval_custody_failed, original, custody}}

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
       do: options |> Map.new() |> settings(),
       else: {:error, {:invalid_emisar_approval_dispatcher, :fields}}
  end

  defp settings(%{} = options) do
    with true <- Maps.exact_keys?(options, @fields),
         api when is_atom(api) <- options.api,
         true <- Adapter.implements?(api, wait_for_run: 3, cancel_run: 3),
         presenter when is_atom(presenter) <- options.presenter,
         true <- Adapter.implements?(presenter, publish: 3),
         true <- function_exported?(presenter, :permanent?, 1),
         :ok <- reference(options.worker_ref),
         :ok <- positive(options.lease_seconds),
         :ok <- positive(options.poll_seconds),
         :ok <- positive(options.retry_base_seconds),
         :ok <- positive(options.retry_max_seconds),
         true <- options.retry_base_seconds <= options.retry_max_seconds,
         true <- options.wait_seconds in 0..60 and options.wait_seconds < options.lease_seconds do
      {:ok, options}
    else
      _invalid -> {:error, {:invalid_emisar_approval_dispatcher, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_emisar_approval_dispatcher, :fields}}

  defp reference(value), do: if(Reference.valid?(value), do: :ok, else: {:error, :reference})

  defp positive(value) when is_integer(value) and value > 0, do: :ok
  defp positive(_value), do: {:error, :positive_integer}
end
