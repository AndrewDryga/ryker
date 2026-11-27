defmodule Ryker.CoopFleet.ModelPermits do
  @moduledoc "Request-owned inference concurrency and provider cooldowns across workers."
  alias Ryker.{AdvisoryLock, Repo}
  alias Ryker.CoopFleet.{ModelAccounts, ModelBucket, ModelPermit, ModelPermitLease}
  alias Ryker.CoopFleet.ModelPermitSupervisor

  def reserve(binding, authorize, kind \\ :http) when kind in [:http, :websocket] do
    bucket = ModelAccounts.quota_identity(binding.account)
    duration = get_in(binding.job, ["limits", "turn_timeout_ms"])

    if is_integer(duration) and duration in 1..86_400_000 do
      binding
      |> reserve_row(authorize, kind, bucket, duration)
      |> start_lease()
    else
      {:error, :model_request_deadline_invalid}
    end
  end

  defp reserve_row(binding, authorize, kind, bucket, duration) do
    Repo.transaction(fn ->
      lock!(bucket)
      verify_binding!(binding, authorize, bucket)
      policy = ensure_bucket!(bucket)
      reconcile_local!(bucket)
      holds = Repo.all(ModelPermit.Query.bucket(bucket) |> ModelPermit.Query.held())
      now = Repo.now!()
      check_capacity!(policy, holds, now)

      attributes = %{
        id: Repo.generate_id(),
        run_id: binding.run.id,
        bucket_id: bucket,
        job_ref: binding.job["job_ref"],
        provider: binding.run.provider,
        account: binding.run.account,
        account_epoch: binding.run.epoch,
        owner_boot: ModelPermitSupervisor.boot(),
        owner_pid: pid(self()),
        kind: kind,
        deadline: DateTime.add(now, duration, :millisecond)
      }

      Repo.insert!(ModelPermit.Changeset.reserve(attributes))
    end)
  end

  defp verify_binding!(binding, authorize, bucket) do
    with {:ok, verified} <- authorize.(),
         true <- verified.run.id == binding.run.id,
         true <- ModelAccounts.quota_identity(verified.account) == bucket do
      :ok
    else
      _refused -> Repo.rollback(:model_grant_refused)
    end
  end

  defp check_capacity!(policy, holds, now) do
    cond do
      policy.blocked_until && DateTime.compare(policy.blocked_until, now) == :gt ->
        Repo.rollback({:model_limited, :provider_cooldown, policy.blocked_until})

      length(holds) >= policy.concurrency ->
        reason = if Enum.any?(holds, &unresolved?/1), do: :unresolved_requests, else: :concurrency
        Repo.rollback({:model_limited, reason, nil})

      true ->
        :ok
    end
  end

  defp unresolved?(permit),
    do: permit.owner_boot != ModelPermitSupervisor.boot() or permit.state == :uncertain

  defp start_lease({:ok, permit}) do
    case DynamicSupervisor.start_child(
           ModelPermitSupervisor,
           {ModelPermitLease, %{permit: permit, owner: self()}}
         ) do
      {:ok, lease} ->
        {:ok, lease}

      _unavailable ->
        release_unstarted(permit.id)
        {:error, :model_permit_unavailable}
    end
  end

  defp start_lease(error), do: error

  def activate(nil, _upstream), do: {:ok, 300_000}
  def activate(lease, upstream), do: GenServer.call(lease, {:activate, upstream})
  def bind_response(lease, id), do: GenServer.call(lease, {:response, id})
  def complete(lease, id), do: call_finished(lease, {:completed, id})
  def cancel(nil), do: :ok
  def cancel(lease), do: call_finished(lease, :cancelled)

  defp call_finished(lease, reason) do
    GenServer.call(lease, reason, 20_000)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
  end

  @doc false
  def bind_lease(id, lease) do
    update_reserved(id, &ModelPermit.Changeset.bind(&1, pid(lease)))
  end

  @doc false
  def activate_row(id, lease, upstream) do
    update_reserved(id, fn permit ->
      if permit.lease_pid != pid(lease), do: Repo.rollback(:model_permit_changed)
      ModelPermit.Changeset.activate(permit, pid(upstream))
    end)
  end

  defp update_reserved(id, change) do
    Repo.transaction(fn ->
      permit = Repo.fetch!(ModelPermit.Query.by_id(id) |> ModelPermit.Query.lock_for_update())
      unless permit.state == :reserved, do: Repo.rollback(:model_permit_changed)
      permit |> change.() |> Repo.update!()
    end)
  end

  @doc false
  def response_row(id, lease, response) do
    Repo.transaction(fn ->
      permit = Repo.fetch!(ModelPermit.Query.by_id(id) |> ModelPermit.Query.lock_for_update())

      unless permit.lease_pid == pid(lease) and permit.state == :active and
               permit.kind == :websocket and is_nil(permit.response_id),
             do: Repo.rollback(:model_permit_changed)

      permit |> ModelPermit.Changeset.response(response) |> Repo.update!()
    end)
  end

  @doc false
  def finish_row(id, lease, reason, stopped?) do
    Repo.transaction(fn ->
      permit = Repo.fetch!(ModelPermit.Query.by_id(id) |> ModelPermit.Query.lock_for_update())

      if permit.lease_pid == pid(lease) and permit.state != :released do
        Repo.update!(finish_changeset(permit, reason, stopped?))
      end

      :ok
    end)
  end

  defp finish_changeset(permit, reason, true),
    do: ModelPermit.Changeset.finish(permit, reason, Repo.now!())

  defp finish_changeset(permit, _reason, false), do: ModelPermit.Changeset.uncertain(permit)

  defp release_unstarted(id) do
    Repo.transaction(fn ->
      permit = Repo.fetch!(ModelPermit.Query.by_id(id) |> ModelPermit.Query.lock_for_update())

      if permit.state == :reserved,
        do: Repo.update!(ModelPermit.Changeset.finish(permit, "not_started", Repo.now!()))
    end)
  end

  def capacity(reference) do
    with {:ok, identity} <- ModelAccounts.fetch_quota_identity(reference) do
      policy = Repo.peek(ModelBucket.Query.by_id(identity.id)) || %ModelBucket{concurrency: 1}
      holds = Repo.all(ModelPermit.Query.bucket(identity.id) |> ModelPermit.Query.held())

      {:ok,
       %{
         concurrency: policy.concurrency,
         active: length(holds),
         blocked_until: policy.blocked_until,
         unresolved:
           Enum.count(
             holds,
             &(&1.owner_boot != ModelPermitSupervisor.boot() or &1.state == :uncertain)
           )
       }}
    end
  end

  def set_limit(reference, count, actor)
      when is_integer(count) and count in 0..256 and is_binary(actor) and
             byte_size(actor) in 1..256 do
    with {:ok, identity} <- ModelAccounts.fetch_quota_identity(reference) do
      Repo.transaction(fn ->
        lock!(identity.id)

        verify_identity!(reference, identity)

        identity.id
        |> ensure_bucket!()
        |> ModelBucket.Changeset.limit(count, actor)
        |> Repo.update!()

        :ok
      end)
    end
  end

  def set_limit(_reference, _count, _actor), do: {:error, :invalid_model_limit}

  defp verify_identity!(reference, identity) do
    unless ModelAccounts.fetch_quota_identity(reference) == {:ok, identity},
      do: Repo.rollback(:model_account_changed)
  end

  def observe_limit(binding, headers) do
    bucket = ModelAccounts.quota_identity(binding.account)
    now = Repo.now!()
    until = retry_at(headers, now)

    Repo.transaction(fn ->
      lock!(bucket)
      policy = ensure_bucket!(bucket)

      if is_nil(policy.blocked_until) or DateTime.compare(policy.blocked_until, until) == :lt,
        do: Repo.update!(ModelBucket.Changeset.cooldown(policy, until))

      :ok
    end)
  end

  @doc "Prior controller requests stay held until an operator confirms their controller stopped."
  def acknowledge_stopped(id, boot, actor) when is_binary(actor) and byte_size(actor) in 1..256 do
    Repo.transaction(fn ->
      permit = Repo.fetch!(ModelPermit.Query.by_id(id) |> ModelPermit.Query.lock_for_update())

      unless permit.owner_boot == boot and boot != ModelPermitSupervisor.boot(),
        do: Repo.rollback(:model_request_still_local)

      if permit.state != :released do
        Repo.update!(
          ModelPermit.Changeset.finish(permit, "confirmed_stopped:" <> actor, Repo.now!())
        )
      end

      :ok
    end)
  end

  def held_requests do
    ModelPermit.Query.held()
    |> Repo.all()
    |> Enum.map(
      &Map.take(&1, [:id, :job_ref, :provider, :account, :owner_boot, :state, :deadline])
    )
  end

  defp ensure_bucket!(id) do
    Repo.insert!(ModelBucket.Changeset.insert(id), on_conflict: :nothing)
    Repo.fetch!(ModelBucket.Query.by_id(id))
  end

  defp lock!(bucket), do: AdvisoryLock.hold!("model-quota:" <> bucket)

  # A deadline is never stop proof. Only this BEAM's known dead request and
  # upstream processes can be reclaimed automatically.
  defp reconcile_local!(bucket) do
    ModelPermit.Query.bucket(bucket)
    |> ModelPermit.Query.held()
    |> ModelPermit.Query.local(ModelPermitSupervisor.boot())
    |> Repo.all()
    |> Enum.each(fn permit ->
      stopped =
        if permit.upstream_pid,
          do: dead?(permit.upstream_pid) and dead?(permit.lease_pid),
          else: dead?(permit.owner_pid) and dead?(permit.lease_pid)

      if stopped do
        Repo.update!(ModelPermit.Changeset.finish(permit, "local_upstream_stopped", Repo.now!()))
      end
    end)
  end

  defp dead?(nil), do: true

  defp dead?(value) do
    value |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?() |> Kernel.not()
  rescue
    _invalid -> false
  end

  defp pid(value), do: value |> :erlang.pid_to_list() |> to_string()

  defp retry_at(headers, now) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "retry-after", do: retry_deadline(value, now)

      _invalid ->
        nil
    end) || DateTime.add(now, 30, :second)
  end

  defp retry_deadline(value, now) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in 0..31_536_000 -> DateTime.add(now, max(1, seconds), :second)
      _invalid -> future_date(http_date(value), now)
    end
  end

  defp future_date(nil, _now), do: nil

  defp future_date(datetime, now) do
    if DateTime.diff(datetime, now, :second) in 1..31_536_000, do: datetime
  end

  # IMF-fixdate is the current HTTP-date form. Invalid advice never becomes an
  # unbounded sleep; absent provider evidence gets a conservative short retry.
  defp http_date(value) when is_binary(value) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    with [_weekday, day, month, year, time, "GMT"] <- String.split(value, " ", trim: true),
         index when is_integer(index) <- Enum.find_index(months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, clock} <- Time.from_iso8601(time),
         {:ok, datetime} <- DateTime.new(date, clock, "Etc/UTC") do
      datetime
    else
      _invalid -> nil
    end
  rescue
    _invalid -> nil
  end

  defp http_date(_value), do: nil
end
