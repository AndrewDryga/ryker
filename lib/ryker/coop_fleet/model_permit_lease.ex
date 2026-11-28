defmodule Ryker.CoopFleet.ModelPermitLease do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Ryker.CoopFleet.ModelPermits
  alias Ryker.Repo

  defmodule State do
    @moduledoc false
    defstruct [
      :permit,
      :owner,
      :owner_monitor,
      :upstream,
      :upstream_monitor,
      :timer,
      :response,
      released: false
    ]
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(%{permit: permit, owner: owner}) do
    Process.flag(:trap_exit, true)

    case ModelPermits.bind_lease(permit.id, self()) do
      {:ok, bound} ->
        {:ok, %State{permit: bound, owner: owner, owner_monitor: Process.monitor(owner)}}

      _changed ->
        {:stop, :model_permit_changed}
    end
  end

  @impl true
  def handle_call({:activate, upstream}, {caller, _tag}, state) do
    if state.upstream == nil and (caller == state.owner or caller == upstream) and
         Process.alive?(state.owner) do
      Process.link(upstream)
      monitor = Process.monitor(upstream)
      remaining = DateTime.diff(state.permit.deadline, Repo.now!(), :millisecond)

      result =
        if remaining > 0,
          do: ModelPermits.activate_row(state.permit.id, self(), upstream),
          else: {:error, :model_request_deadline}

      case result do
        {:ok, active} ->
          finish_activation(%{
            state
            | permit: active,
              upstream: upstream,
              upstream_monitor: monitor
          })

        _changed ->
          Process.unlink(upstream)
          Process.demonitor(monitor, [:flush])
          {:stop, :normal, {:error, :model_permit_changed}, state}
      end
    else
      {:reply, {:error, :model_permit_changed}, state}
    end
  end

  def handle_call({:response, id}, {owner, _tag}, %{owner: owner, response: nil} = state)
      when is_binary(id) and byte_size(id) in 1..512 do
    case ModelPermits.response_row(state.permit.id, self(), id) do
      {:ok, _bound} -> {:reply, :ok, %{state | response: id}}
      _changed -> {:reply, {:error, :model_permit_changed}, state}
    end
  end

  def handle_call(
        {:completed, id},
        {owner, _tag},
        %{owner: owner, response: id, permit: %{kind: :websocket}} = state
      )
      when is_binary(id) do
    # Terminal proof ends this request's execution deadline immediately;
    # persistence may wait without killing another lane on the same socket.
    cancel_timer(state.timer)

    case ModelPermits.finish_row(state.permit.id, self(), "provider_terminal_response", true) do
      {:ok, :ok} ->
        if state.upstream, do: Process.unlink(state.upstream)
        {:stop, :normal, :ok, %{state | released: true}}

      _unavailable ->
        {:stop, :model_permit_unavailable, {:error, :model_permit_unavailable}, state}
    end
  end

  def handle_call(:cancelled, {owner, _tag}, %{owner: owner} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, state), do: {:reply, {:error, :model_permit_changed}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.owner_monitor or monitor == state.upstream_monitor,
      do: {:stop, :normal, state}

  # Links make an unexpected lease failure stop paid work too. DOWN owns the
  # normal cleanup path, so a linked exit cannot release the same hold twice.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{released: true}), do: :ok

  def terminate(_reason, state) do
    cancel_timer(state.timer)
    stopped = stop_upstream(state.upstream, state.upstream_monitor)
    ModelPermits.finish_row(state.permit.id, self(), "upstream_stopped", stopped)
    :ok
  catch
    _kind, _reason -> :ok
  end

  # A row lock may have waited past the request deadline. Never give that
  # wait back as extra provider execution time.
  defp finish_activation(state) do
    remaining = DateTime.diff(state.permit.deadline, Repo.now!(), :millisecond)

    if remaining > 0 do
      timer = deadline(state.upstream, remaining)
      {:reply, {:ok, remaining}, %{state | timer: timer}}
    else
      {:stop, :normal, {:error, :model_request_deadline}, state}
    end
  end

  defp stop_upstream(nil, _monitor), do: true

  defp stop_upstream(pid, monitor) do
    Process.unlink(pid)
    Process.exit(pid, :kill)

    if Process.alive?(pid) do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> true
      after
        5_000 -> false
      end
    else
      true
    end
  end

  # This timer does no database work. A blocked quota query cannot extend an
  # admitted request's deadline, and an expired row is never reclaimed first.
  defp deadline(upstream, milliseconds) do
    {:ok, timer} =
      Task.start_link(fn ->
        monitor = Process.monitor(upstream)

        receive do
          {:DOWN, ^monitor, :process, ^upstream, _reason} -> :ok
        after
          milliseconds -> Process.exit(upstream, :kill)
        end
      end)

    timer
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end
end
