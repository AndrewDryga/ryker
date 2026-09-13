defmodule Ryker.Slack.SocketTransport do
  @moduledoc false

  @type frame ::
          {:text, binary()}
          | {:binary, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, non_neg_integer(), binary()}

  @callback connect(term()) :: {:ok, term()} | {:error, term()}
  @callback stream(term(), term()) ::
              {:ok, term(), [frame()]} | {:unknown, term()} | {:error, term()}
  @callback send_frame(term(), frame()) :: {:ok, term()} | {:error, term()}
  @callback close(term()) :: :ok
end
