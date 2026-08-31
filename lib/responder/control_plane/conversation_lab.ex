defmodule Responder.ControlPlane.ConversationLab do
  @moduledoc """
  Source-neutral local conversation ingress for the loopback control plane.

  A lab message is not sent directly to a model. It enters the same durable
  inbox, admission, episode, Work, state-tool, and delivery path as Slack,
  GitHub, or a signed webhook. The stable conversation destination lets later
  messages continue the same episode without adding a second chat store.
  """

  alias Responder.Ingress.{Inbox, Input, WorkProfile}

  @maximum_message_bytes 20_000
  @option_keys [:id_generator, :now]

  @spec send_message(String.t(), String.t(), WorkProfile.t(), keyword()) ::
          {:ok, Inbox.receipt()} | {:error, term()}
  def send_message(conversation_id, message, work_profile, options \\ [])

  def send_message(conversation_id, message, %WorkProfile{} = work_profile, options) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         :ok <- message(message),
         {:ok, settings} <- options(options),
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now),
         {:ok, input} <-
           Input.new(%{
             actor: %{kind: :user, ref: "local-operator"},
             content: %{"text" => message},
             destination: destination(conversation_id),
             event_kind: :message,
             event_ref: "control-plane-event:#{event_id}",
             native_input_id: "control-plane-message:#{event_id}",
             occurred_at: occurred_at,
             occurred_at_source: :ingress,
             revision: 1,
             source: %{kind: "control_plane", ref: "local"},
             source_capabilities: %{},
             source_item_ref: "control-plane-item:#{event_id}"
           }) do
      Inbox.record(input, work_profile: work_profile)
    end
  end

  def send_message(_conversation_id, _message, _work_profile, _options),
    do: {:error, {:invalid_conversation_lab, :work_profile}}

  @spec conversation_ref(String.t()) :: {:ok, String.t()} | {:error, term()}
  def conversation_ref(conversation_id) do
    with {:ok, conversation_id} <- conversation_id(conversation_id) do
      {:ok, "control-plane:lab:#{conversation_id}"}
    end
  end

  defp destination(conversation_id) do
    conversation_ref = "control-plane:lab:#{conversation_id}"

    %{
      transport: "control_plane",
      conversation_ref: conversation_ref,
      thread_ref: conversation_ref
    }
  end

  defp conversation_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_conversation_lab, :conversation_id}}
    end
  end

  defp message(value) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= @maximum_message_bytes,
       do: :ok,
       else: {:error, {:invalid_conversation_lab, :message}}
  end

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- @option_keys == [] do
      settings = %{
        id_generator: Keyword.get(options, :id_generator, &Ecto.UUID.generate/0),
        now: Keyword.get(options, :now, &DateTime.utc_now/0)
      }

      if is_function(settings.id_generator, 0) and is_function(settings.now, 0),
        do: {:ok, settings},
        else: {:error, {:invalid_conversation_lab, :options}}
    else
      {:error, {:invalid_conversation_lab, :options}}
    end
  end

  defp options(_options), do: {:error, {:invalid_conversation_lab, :options}}

  defp generated_id(id_generator) do
    case Ecto.UUID.cast(id_generator.()) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_conversation_lab, :event_id}}
    end
  end

  defp occurred_at(now) do
    case now.() do
      %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = value -> {:ok, value}
      _other -> {:error, {:invalid_conversation_lab, :now}}
    end
  end
end
