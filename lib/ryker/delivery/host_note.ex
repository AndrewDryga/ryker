defmodule Ryker.Delivery.HostNote do
  @moduledoc """
  A fixed note from the host, posted in a conversation people are reading.

  The words are fixed in the caller's code: no model writes a host note. It
  goes out through the delivery adapters Ryker is running with, the same
  publishers that post every reply, under a delivery ref the caller fixes for
  the occasion: a retry finds the note it already posted instead of posting a
  second one.
  """

  alias Ryker.Delivery.{Adapters, Request}

  @enforce_keys [:conversation_ref, :execution_mode, :message, :ref, :thread_ref, :transport]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          conversation_ref: String.t(),
          execution_mode: :live | :shadow,
          message: String.t(),
          ref: String.t(),
          thread_ref: String.t() | nil,
          transport: String.t()
        }

  @type outcome :: {:posted, map()} | {:not_posted, term()}

  @doc "Posts the note through the delivery adapters of the applied configuration."
  @spec deliver(t()) :: {:ok, outcome()} | {:error, term()}
  def deliver(%__MODULE__{} = note), do: deliver(note, applied_adapters())

  @doc """
  Posts the note through `adapters`.

  Nobody reads a shadow conversation, and a conversation Ryker has no
  publisher for cannot be told anything: both come back not posted, with the
  reason, rather than as a failure worth retrying.
  """
  @spec deliver(t(), map() | nil) :: {:ok, outcome()} | {:error, term()}
  def deliver(%__MODULE__{execution_mode: :shadow}, _adapters), do: {:ok, {:not_posted, :shadow}}
  def deliver(%__MODULE__{}, nil), do: {:ok, {:not_posted, :delivery_not_configured}}

  def deliver(%__MODULE__{} = note, adapters) when is_map(adapters) do
    with {:ok, request} <- request(note) do
      case Adapters.publish(request, adapters) do
        {:ok, receipt} ->
          {:ok, {:posted, receipt}}

        {:error, {:delivery_adapter_not_configured, _transport} = reason} ->
          {:ok, {:not_posted, reason}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "The note as one immutable message delivery into its conversation and thread."
  @spec request(t()) :: {:ok, Request.t()} | {:error, term()}
  def request(%__MODULE__{} = note) do
    Request.new(%{
      conversation_ref: note.conversation_ref,
      document: %{"message" => note.message},
      kind: :message,
      ref: note.ref,
      source_item_ref: nil,
      thread_ref: note.thread_ref,
      transport: note.transport
    })
  end

  # The registry the running delivery lanes were started with; readers resolve
  # the applied configuration at the moment they need it.
  defp applied_adapters do
    with %{adapters: registrations} <- Application.get_env(:ryker, :delivery),
         {:ok, adapters} <- Adapters.new(registrations) do
      adapters
    else
      _unavailable -> nil
    end
  end
end
