defmodule Ryker.Slack.Target do
  @moduledoc false
  alias Ryker.ConversationRef
  alias Ryker.Delivery
  alias Ryker.Slack.{Id, Timestamp}

  @spec parse(Delivery.Request.t()) :: {:ok, map()} | {:error, term()}
  def parse(%Delivery.Request{transport: "slack"} = request) do
    with {:ok, workspace_ref, channel_ref} <- conversation(request.conversation_ref),
         :ok <- optional_timestamp(request.thread_ref),
         :ok <- source_target(request) do
      {:ok,
       %{
         channel_ref: channel_ref,
         message_ref: request.source_item_ref,
         thread_ref: request.thread_ref,
         workspace_ref: workspace_ref
       }}
    end
  end

  def parse(_request), do: {:error, {:invalid_slack_delivery_target, :transport}}

  defp conversation(value) do
    with {:ok, workspace_ref, channel_ref} <- ConversationRef.parse_slack(value),
         true <- Id.valid?(workspace_ref) and Id.valid?(channel_ref) do
      {:ok, workspace_ref, channel_ref}
    else
      _invalid -> {:error, {:invalid_slack_delivery_target, :conversation_ref}}
    end
  end

  defp source_target(%Delivery.Request{kind: :message, source_item_ref: nil}), do: :ok

  defp source_target(%Delivery.Request{kind: :reaction, source_item_ref: value}),
    do: timestamp(value, :source_item_ref)

  defp source_target(_request), do: {:error, {:invalid_slack_delivery_target, :source_item_ref}}

  defp optional_timestamp(nil), do: :ok
  defp optional_timestamp(value), do: timestamp(value, :thread_ref)

  defp timestamp(value, field) do
    if Timestamp.valid?(value),
      do: :ok,
      else: {:error, {:invalid_slack_delivery_target, field}}
  end
end
