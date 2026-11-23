defmodule Ryker.GitHub.CIRepairs do
  @moduledoc "Leased, bounded automatic repairs shared by human and Ryker pull requests."
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.ErrorDetail
  alias Ryker.GitHub.{CIRepair, CIRepairMessages, CIRepairPolicy, CIRepairRequests, CIRepairRound}
  alias Ryker.GitObject
  alias Ryker.Ingress
  alias Ryker.Lease
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings

  @doc "A verified webhook or own-PR watcher makes only this PR due."
  def nudge(%{name: name} = expected, number, head, refresh \\ false)
      when is_integer(number) and number > 0 and is_boolean(refresh) do
    if is_nil(head) or GitObject.id?(head) do
      Repo.transaction(fn -> nudge_locked(name, expected, number, head, refresh) end)
    else
      {:error, :invalid_ci_repair_head}
    end
  end

  defp nudge_locked(binding_ref, expected, number, head, refresh) do
    :ok = Settings.synchronize_in_transaction()

    case configuration(binding_ref) do
      {:ok, configured} ->
        if configured.binding.repository_id == expected.repository_id and
             configured.binding.installation_id == expected.installation_id and
             configured.repository.github_repository == expected.repository_full_name do
          enqueue!(configured, number, head, refresh)
        else
          Repo.rollback(:ci_repair_binding_changed)
        end

      {:error, _unavailable} ->
        :ignored
    end
  end

  defp enqueue!(configured, number, head, refresh) do
    binding = configured.binding

    identity =
      CanonicalJSON.digest(%{
        "binding" => binding.name,
        "repository" => binding.repository_id,
        "installation" => binding.installation_id,
        "number" => number
      })

    AdvisoryLock.hold!("ci-repair:" <> identity)
    result = Repo.fetch(CIRepair.Query.by_identity(identity) |> CIRepair.Query.lock_for_update())

    if result == {:error, :not_found} and configured.repository.github_ci_repair == :off do
      :ignored
    else
      repair =
        case result do
          {:ok, repair} ->
            repair

          {:error, :not_found} ->
            CIRepair.Changeset.insert(%{
              identity: identity,
              binding_ref: binding.name,
              repository_ref: configured.repository.ref,
              repository_id: binding.repository_id,
              installation_id: binding.installation_id,
              number: number
            })
            |> Repo.insert!()
        end

      heads = Enum.uniq(repair.pending_heads ++ List.wrap(head))
      if length(heads) > 20, do: Repo.rollback(:ci_repair_signal_capacity)

      update!(repair, %{
        pending_heads: heads,
        refresh_requested: repair.refresh_requested or refresh,
        revision: repair.revision + 1,
        next_attempt_at: Repo.now!()
      })
    end
  end

  def configuration(binding_ref) do
    with {:ok, settings} <- Settings.fetch(),
         true <- settings.github.enabled,
         binding when not is_nil(binding) <-
           Enum.find(settings.github_bindings, &(&1.name == binding_ref)),
         repository when not is_nil(repository) <-
           Enum.find(settings.repositories, &(&1.ref == binding.repository_ref)) do
      {:ok, %{binding: binding, repository: repository}}
    else
      _unavailable -> {:error, :repository_unavailable}
    end
  end

  def claim_next(bindings) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case Repo.fetch(CIRepair.Query.next_claimable(now, bindings)) do
        {:error, :not_found} ->
          nil

        {:ok, repair} ->
          update!(repair, %{
            lease_ref: Repo.generate_id(),
            lease_expires_at: DateTime.add(now, 120),
            attempt_count: repair.attempt_count + 1
          })
      end
    end)
  end

  @doc "A changed signal invalidates an in-flight API read instead of silently losing it."
  def evaluate(%CIRepair{} = claimed, pull) do
    Repo.transaction(fn ->
      :ok = Settings.synchronize_in_transaction()
      repair = fetch_and_lock_claim!(claimed)
      if repair.revision != claimed.revision, do: Repo.rollback(:ci_repair_changed)
      configured = configuration!(repair)
      round = current_round(repair)
      round = finish_round(round, repair.allowed)
      decide(repair, round, pull, configured)
    end)
  end

  defp decide(repair, round, pull, configured) do
    case CIRepairPolicy.eligibility(configured.repository, configured.binding, pull) do
      {:error, reason} ->
        settle(repair, round, pull, Atom.to_string(reason), false, active?(round))

      :ok ->
        eligible(repair, round, pull, configured)
    end
  end

  defp eligible(repair, %CIRepairRound{finished_at: nil} = round, pull, _configured) do
    cond do
      get_in(pull, ["checks", "state"]) == "passing" ->
        settle(repair, round, pull, "checks_passing", false, true)

      not repair.allowed ->
        settle(repair, round, pull, "stopping", false, true)

      pull["head"] != round.head ->
        settle(repair, round, pull, "head_changed", false, true)

      true ->
        settle(repair, round, pull, "running", true, true)
    end
  end

  defp eligible(repair, round, %{"checks" => %{"state" => "passing"}} = pull, _configured) do
    attributes = %{
      rounds: 0,
      failure_open: false,
      last_attempt_head: nil,
      generation: repair.generation + if(repair.failure_open, do: 1, else: 0)
    }

    repair = update!(repair, attributes)
    settle(repair, round, pull, "passing", false, false)
  end

  defp eligible(
         %{generation: generation} = repair,
         %CIRepairRound{
           generation: generation,
           outcome: %{"status" => "publication_needs_attention"}
         } = round,
         pull,
         _configured
       ) do
    settle(repair, round, pull, "publication_needs_attention", false, false)
  end

  defp eligible(repair, round, pull, configured) do
    signaled =
      pull["head"] in repair.pending_heads or repair.refresh_requested or
        published_head(round) == pull["head"]

    cond do
      not signaled ->
        settle(repair, round, pull, completed_status(round), false, false)

      get_in(pull, ["checks", "state"]) != "failing" ->
        settle(repair, round, pull, "waiting_for_ci", false, true)

      repair.rounds >= 2 ->
        settle(repair, round, pull, "limit_reached", false, false)

      repair.last_attempt_head == pull["head"] and not repair.refresh_requested ->
        settle(repair, round, pull, completed_status(round), false, false)

      true ->
        start_round(repair, pull, configured)
    end
  end

  defp start_round(repair, pull, configured) do
    case CIRepairRequests.record(repair, configured, pull) do
      {:ok, round} ->
        repair =
          update!(repair, %{
            current_round_id: round.id,
            rounds: round.ordinal,
            last_attempt_head: round.head,
            failure_open: true,
            pending_heads: [],
            refresh_requested: false
          })

        settle(repair, round, pull, "running", true, true)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp settle(repair, round, pull, status, allowed, pending) do
    keep_signals = active?(round) or status == "waiting_for_ci"

    repair =
      update!(repair, %{
        allowed: allowed,
        status: status,
        observation: pull,
        pending_heads: if(keep_signals, do: repair.pending_heads, else: []),
        refresh_requested: keep_signals and repair.refresh_requested,
        revision: repair.revision + 1
      })

    %{repair: repair, round: round, pending: pending, stop: active?(round) and not allowed}
  end

  defp published_head(%CIRepairRound{
         outcome: %{"status" => "pull_request_ready", "commit" => commit}
       }),
       do: commit

  defp published_head(_round), do: nil

  defp completed_status(%CIRepairRound{outcome: %{"status" => "pull_request_ready"}}),
    do: "published"

  defp completed_status(%CIRepairRound{}), do: "no_change"
  defp completed_status(nil), do: "stale_event"
  defp active?(%CIRepairRound{finished_at: nil}), do: true
  defp active?(_round), do: false

  defp current_round(%{current_round_id: nil}), do: nil

  defp current_round(repair),
    do: repair.current_round_id |> CIRepairRound.Query.by_id() |> Repo.fetch!()

  defp finish_round(nil, _allowed), do: nil

  defp finish_round(%CIRepairRound{finished_at: finished} = round, _allowed)
       when not is_nil(finished), do: round

  defp finish_round(round, allowed) do
    result =
      case Repo.fetch(Ingress.Inbox.Entry.Query.by_id(round.entry_id)) do
        {:ok, entry} -> Records.TaskProgress.read(entry)
        {:error, :not_found} -> %{"status" => "history_unavailable", "terminal" => true}
      end

    if result["terminal"] == true or
         (not allowed and result["status"] in ["needs_input", "stopped"]) do
      round |> CIRepairRound.Changeset.finish(result, Repo.now!()) |> Repo.update!()
    else
      round
    end
  end

  @doc "Completes comment delivery without acknowledging a signal received during the write."
  def delivered(projected, receipt) do
    with {:ok, request} <- CIRepairMessages.request(projected),
         :ok <- Delivery.ReconciledMessage.validate(request, receipt) do
      complete_poll(projected, %{
        external_receipt: receipt,
        rendered_fingerprint: CanonicalJSON.digest(request.document)
      })
    end
  end

  @doc "Releases the claim for a PR that has never started a repair round."
  def complete_without_delivery(%{round: nil} = projected), do: complete_poll(projected, %{})

  defp complete_poll(projected, delivery) do
    Repo.transaction(fn ->
      repair = fetch_and_lock_claim!(projected.repair)

      next =
        cond do
          repair.revision != projected.repair.revision -> Repo.now!()
          projected.pending -> DateTime.add(Repo.now!(), 15)
          true -> nil
        end

      update!(
        repair,
        Map.merge(delivery, %{
          next_attempt_at: next,
          lease_ref: nil,
          lease_expires_at: nil,
          attempt_count: 0,
          last_error: nil
        })
      )
    end)
  end

  def defer(claimed, reason, seconds) do
    Repo.transaction(fn ->
      repair = fetch_and_lock_claim!(claimed)

      update!(repair, %{
        next_attempt_at: DateTime.add(Repo.now!(), seconds),
        lease_ref: nil,
        lease_expires_at: nil,
        last_error: ErrorDetail.detail(reason)
      })
    end)
  end

  defp configuration!(repair) do
    case configuration(repair.binding_ref) do
      {:ok, %{binding: binding} = configured}
      when binding.repository_id == repair.repository_id and
             binding.installation_id == repair.installation_id and
             binding.repository_ref == repair.repository_ref ->
        configured

      _unavailable ->
        Repo.rollback(:repository_unavailable)
    end
  end

  defp fetch_and_lock_claim!(claimed) do
    repair =
      claimed.id |> CIRepair.Query.by_id() |> CIRepair.Query.lock_for_update() |> Repo.fetch!()

    if not Lease.held?(repair, claimed.lease_ref, Repo.now!()),
      do: Repo.rollback(:ci_repair_lease_lost)

    repair
  end

  defp update!(repair, attributes),
    do: repair |> CIRepair.Changeset.update(attributes) |> Repo.update!()
end
