defmodule Ryker.Slack.Input do
  @moduledoc """
  Converts one trusted Slack envelope into the source-neutral ingress input.

  Slack IDs determine identity and routing. Blocks, attachments, text, and app
  metadata remain arbitrary bounded content for the model to interpret.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.Input

  @behaviour Ryker.Ingress.Adapter

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
  @optional_fields [:post_destination_refs]
  @required_keys Enum.sort(@fields)
  @all_keys Enum.sort(@fields ++ @optional_fields)

  @spec new(keyword() | map()) :: {:ok, Input.t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- exact_attributes(attributes) do
      Input.new(%{
        actor: attributes.actor,
        content: attributes.content,
        destination: destination(attributes),
        event_kind: attributes.event_kind,
        event_ref: attributes.event_ref,
        native_input_id: message_key(attributes),
        occurred_at: attributes.occurred_at,
        occurred_at_source: :source,
        revision: attributes.revision,
        source: %{kind: "slack", ref: attributes.workspace_ref},
        source_capabilities: source_capabilities(attributes),
        source_item_ref: attributes.message_ref
      })
    end
  end

  @impl Ryker.Ingress.Adapter
  def source_kind, do: "slack"

  @impl Ryker.Ingress.Adapter
  def normalize(attributes, nil), do: new(attributes)

  def normalize(_event, _binding), do: {:error, {:invalid_slack_input, :binding}}

  defp exact_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> exact_attributes()
    else
      {:error, {:invalid_input, :fields}}
    end
  end

  defp exact_attributes(%{} = attributes) do
    case Map.keys(attributes) |> Enum.sort() do
      @required_keys ->
        {:ok, Map.put(attributes, :post_destination_refs, [])}

      @all_keys ->
        {:ok, attributes}

      _invalid ->
        {:error, {:invalid_input, :fields}}
    end
  end

  defp exact_attributes(_attributes), do: {:error, {:invalid_input, :fields}}

  defp destination(attributes) do
    %{
      conversation_ref: "slack:#{attributes.workspace_ref}:#{attributes.channel_ref}",
      thread_ref: attributes.thread_ref || attributes.message_ref,
      transport: "slack"
    }
  end

  defp source_capabilities(%{event_kind: event_kind}) when event_kind in [:delete, :event],
    do: %{}

  defp source_capabilities(%{actor: %{kind: :user}, post_destination_refs: refs})
       when is_list(refs) and refs != [] do
    %{
      "post_slack_message" => %{"destination_refs" => refs},
      "react" => %{"emoji_names" => nil}
    }
  end

  defp source_capabilities(_attributes), do: %{"react" => %{"emoji_names" => nil}}

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
