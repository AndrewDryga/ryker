defmodule Responder.Slack.Input do
  @moduledoc """
  Converts one trusted Slack envelope into the source-neutral ingress input.

  Slack IDs determine identity and routing. Blocks, attachments, text, and app
  metadata remain arbitrary bounded content for the model to interpret.
  """

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Input

  @fields [
    :actor,
    :channel_ref,
    :content,
    :event_kind,
    :event_ref,
    :message_ref,
    :occurred_at,
    :revision,
    :thread_ref,
    :workspace_ref
  ]

  @spec new(keyword() | map()) :: {:ok, Input.t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- exact_attributes(attributes) do
      Input.new(%{
        actor: attributes.actor,
        can_react: attributes.event_kind != :delete,
        content: attributes.content,
        destination: destination(attributes),
        event_kind: attributes.event_kind,
        event_ref: attributes.event_ref,
        native_input_id: message_key(attributes),
        occurred_at: attributes.occurred_at,
        occurred_at_source: :source,
        revision: attributes.revision,
        source: %{kind: :slack, ref: attributes.workspace_ref},
        source_item_ref: attributes.message_ref
      })
    end
  end

  defp exact_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> exact_attributes()
    else
      {:error, {:invalid_input, :fields}}
    end
  end

  defp exact_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_input, :fields}}
  end

  defp exact_attributes(_attributes), do: {:error, {:invalid_input, :fields}}

  defp destination(attributes) do
    %{
      conversation_ref: "slack:#{attributes.workspace_ref}:#{attributes.channel_ref}",
      thread_ref: attributes.thread_ref || attributes.message_ref,
      transport: "slack"
    }
  end

  defp message_key(attributes) do
    digest =
      CanonicalJSON.digest([
        attributes.workspace_ref,
        attributes.channel_ref,
        attributes.message_ref
      ])

    "slack-message:#{digest}"
  end
end
