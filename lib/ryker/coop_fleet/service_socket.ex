defmodule Ryker.CoopFleet.ServiceSocket do
  @moduledoc false
  @behaviour WebSock
  alias Ryker.CoopFleet.{ServiceConnections, ServiceRelays}

  defstruct [
    :id,
    :peer,
    :monitor,
    :binding,
    :certificate,
    :role,
    sending: false,
    receiving: false,
    sent_fin: false,
    received_fin: false
  ]

  def upgrade(conn, init) do
    WebSockAdapter.upgrade(conn, __MODULE__, init,
      timeout: 660_000,
      max_frame_size: 32_769 + 14,
      max_fragmented_message_size: 32_769,
      compress: false
    )
  end

  @impl true
  def init({:operator, binding}) do
    id = Ecto.UUID.generate()

    with true <- ServiceRelays.current?(binding),
         true <- take_slot(),
         {:ok, _} <- Registry.register(ServiceConnections, {:operator, id}, binding),
         {:ok, _} <- ServiceRelays.connect(id, binding) do
      Process.send_after(self(), :pair_timeout, 20_000)
      schedule_check()
      {:ok, %__MODULE__{id: id, binding: binding, role: :operator}}
    else
      _unavailable -> stop(%__MODULE__{})
    end
  end

  def init({:worker, id, owner, binding, hash}) do
    with true <- ServiceRelays.authenticated?(binding, hash),
         [{^owner, ^binding}] <- Registry.lookup(ServiceConnections, {:operator, id}),
         {:ok, _} <- Registry.register(ServiceConnections, {:worker, id}, owner) do
      send(owner, {:join, self()})
      schedule_check()

      {:ok,
       %__MODULE__{
         id: id,
         peer: owner,
         monitor: Process.monitor(owner),
         certificate: hash,
         binding: binding,
         role: :worker
       }}
    else
      _unavailable -> stop(%__MODULE__{})
    end
  end

  defp take_slot do
    Enum.any?(1..32, &match?({:ok, _}, Registry.register(ServiceConnections, {:slot, &1}, nil)))
  end

  @impl true
  def handle_info({:join, worker}, %{id: id, role: :operator, peer: nil} = state) do
    if Registry.lookup(ServiceConnections, {:worker, id}) == [{worker, self()}] do
      send(worker, {:ready, self()})
      {:push, {:binary, <<4>>}, %{state | peer: worker, monitor: Process.monitor(worker)}}
    else
      stop(state)
    end
  end

  def handle_info({:ready, peer}, %{role: :worker, peer: peer} = state),
    do: {:push, {:binary, <<4>>}, state}

  def handle_info(
        {:frame, peer, <<1, _::binary>> = frame},
        %{peer: peer, receiving: false, received_fin: false} = state
      ),
      do: {:push, {:binary, frame}, %{state | receiving: true}}

  def handle_info({:frame, peer, <<2>>}, %{peer: peer, sending: true} = state),
    do: {:push, {:binary, <<2>>}, %{state | sending: false}}

  def handle_info(
        {:frame, peer, <<3>>},
        %{peer: peer, receiving: false, received_fin: false} = state
      ),
      do: {:push, {:binary, <<3>>}, %{state | received_fin: true}}

  def handle_info({:frame, _, _}, state), do: stop(state)
  def handle_info(:pair_timeout, %{peer: nil} = state), do: stop(state)
  def handle_info(:pair_timeout, state), do: {:ok, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:check_authority, state) do
    allowed =
      if state.role == :worker,
        do: ServiceRelays.authenticated?(state.binding, state.certificate),
        else: ServiceRelays.current?(state.binding)

    if allowed do
      schedule_check()
      {:ok, state}
    else
      stop(state)
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_in({frame, [opcode: :binary]}, %{peer: peer} = state) when is_pid(peer) do
    case frame do
      <<1, data::binary>>
      when byte_size(data) in 1..32_768 and not state.sending and not state.sent_fin ->
        send(peer, {:frame, self(), frame})
        {:ok, %{state | sending: true}}

      <<2>> when state.receiving ->
        send(peer, {:frame, self(), frame})
        {:ok, %{state | receiving: false}}

      <<3>> when not state.sending and not state.sent_fin ->
        send(peer, {:frame, self(), frame})
        {:ok, %{state | sent_fin: true}}

      _invalid ->
        stop(state)
    end
  end

  def handle_in(_unexpected, state), do: stop(state)

  defp schedule_check, do: Process.send_after(self(), :check_authority, 1_000)
  defp stop(state), do: {:stop, :normal, {1008, "service access ended"}, state}
end
