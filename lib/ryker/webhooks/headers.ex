defmodule Ryker.Webhooks.Headers do
  @moduledoc """
  The request headers an external sender sets on a webhook, from
  `x-responder-timestamp` and `x-responder-signature` to the five event
  headers below.

  The names are a contract with configured senders and stay as they are. The
  five event headers are read the same way whether they are being signed or
  turned into metadata: absent is allowed, empty or repeated is not.
  """

  alias Plug.Conn

  # In the order the HMAC signature covers them.
  @event_headers ~w(x-responder-event-id x-responder-item-id x-responder-event-type x-responder-occurred-at x-responder-revision)

  @spec optional(Conn.t(), String.t()) :: {:ok, String.t() | nil} | {:error, :header}
  def optional(conn, name) do
    case Conn.get_req_header(conn, name) do
      [] -> {:ok, nil}
      [value] when value != "" -> {:ok, value}
      _other -> {:error, :header}
    end
  end

  @doc "The event headers in signing order, an absent one as the empty string."
  @spec signed_values(Conn.t()) :: {:ok, [String.t()]} | {:error, :header}
  def signed_values(conn) do
    Enum.reduce_while(@event_headers, {:ok, []}, fn name, {:ok, values} ->
      case optional(conn, name) do
        {:ok, value} -> {:cont, {:ok, [value || "" | values]}}
        {:error, :header} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, :header} = error -> error
    end
  end
end
