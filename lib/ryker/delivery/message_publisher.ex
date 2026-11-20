defmodule Ryker.Delivery.MessagePublisher do
  @moduledoc """
  Narrow platform port for one durable visible message.
  """
  alias Ryker.Delivery.Request

  @callback publish_message(Request.t(), term()) :: {:ok, map()} | {:error, term()}
  @type before_write :: (String.t() ->
                           {:reserved, (-> :ok | {:error, term()})} | {:error, term()})
  @callback publish_message(Request.t(), term(), before_write()) ::
              {:ok, map()} | {:error, term()}
  @callback update_message(Request.t(), String.t(), map(), term()) :: :ok | {:error, term()}

  @optional_callbacks update_message: 4, publish_message: 3

  @doc "Reserve the first write, retaining its identity if the remote outcome is uncertain."
  def with_reservation(reserve, write) do
    case reserve.() do
      :ok -> write.()
      {:reserved, release} -> settle_reservation(write.(), release)
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_reservation({:error, {kind, detail}}, _release)
       when kind in [:delivery_uncertain, :delivery_share_pending], do: {:error, {kind, detail}}

  defp settle_reservation({:error, _definite} = error, release) do
    with :ok <- release.(), do: error
  end

  defp settle_reservation(result, _release), do: result
end
