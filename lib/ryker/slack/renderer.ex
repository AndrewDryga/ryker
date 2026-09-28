defmodule Ryker.Slack.Renderer do
  @moduledoc """
  Renders host-owned state records into bounded Slack Block Kit.

  Model prose is emitted through Slack's standard `markdown` block while it
  fits Slack's cumulative Markdown bound. Oversized prose remains complete in
  inert plain-text sections. Interactive controls are created only from
  validated durable records, so model output cannot invent action IDs, button
  values, or confirmation flows.

  This module is the one entry point; each card family renders in its own
  module under `Ryker.Slack.Renderer`, all built from the shared `Blocks`
  vocabulary and `Fields` checks:

    * `EmisarReview` — the governed-review message
    * `WorkCards` and `TaskPublication` — incident-room and task cards
    * `ChannelCards` and `ChannelSetup` — welcome, settings and the setup Q&A
    * `SavedEntityCard` — schedules, rules, preferences, guidance, memories
    * `Records` and `Offers` — the records attached to a reply
  """

  import Ryker.Slack.Renderer.Blocks, only: [escape: 1, message_blocks: 1]

  alias Ryker.Slack.Mentions

  alias Ryker.Slack.Renderer.{
    ChannelCards,
    ChannelSetup,
    EmisarReview,
    Fields,
    Records,
    SavedEntityCard,
    WorkCards
  }

  @maximum_message_characters 20_000
  @maximum_blocks 50

  # chat.update refuses a message whose text is over 4,000 characters as Slack
  # counts them, which is after it has linked each URL, while chat.postMessage
  # takes one ten times as long: a long reply could be posted and never
  # repainted. The blocks carry the whole message and the text is what a
  # notification shows, so it stays well inside Slack's count.
  @maximum_text_characters 3_000

  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(document) do
    with {:ok, %{"text" => text} = rendered} when is_binary(text) <- render_document(document),
         do: {:ok, %{rendered | "text" => notification_text(text)}}
  end

  # Every `&` and `<` left in rendered text starts an escape or a Slack
  # token, so the cut drops a trailing one that it would split.
  defp notification_text(text) do
    if String.length(text) <= @maximum_text_characters do
      text
    else
      text
      |> String.slice(0, @maximum_text_characters - 1)
      |> String.replace(~r/(?:<[^>]*|&[^;\s]*)\z/u, "")
      |> String.trim_trailing()
      |> Kernel.<>("…")
    end
  end

  defp render_document(%{"emisar_approval_status" => status} = document)
       when map_size(document) == 1,
       do: EmisarReview.render(status)

  defp render_document(%{"incident_room" => room} = document) when map_size(document) == 1,
    do: WorkCards.incident_room(room)

  defp render_document(%{"task_card" => task} = document) when map_size(document) == 1,
    do: WorkCards.task_card(task)

  defp render_document(%{"channel_setup" => setup} = document) when map_size(document) == 1,
    do: ChannelSetup.render(setup)

  defp render_document(%{"channel_welcome" => welcome} = document) when map_size(document) == 1,
    do: ChannelCards.welcome(welcome)

  defp render_document(%{"channel_settings" => view} = document) when map_size(document) == 1,
    do: ChannelCards.settings(view)

  defp render_document(%{"saved_entity" => entity} = document) when map_size(document) == 1 do
    case SavedEntityCard.validate(entity) do
      :ok ->
        {:ok,
         %{"blocks" => SavedEntityCard.blocks(entity), "text" => SavedEntityCard.text(entity)}}

      {:error, _reason} ->
        {:error, {:invalid_slack_render, :saved_entity}}
    end
  end

  defp render_document(%{"message" => message} = document) when map_size(document) == 1,
    do: render_document(%{"message" => message, "records" => []})

  # A message without cards that names someone: the publisher added the
  # delivery's mention authority to it.
  defp render_document(%{"message" => message, "slack_mentions" => authority} = document)
       when map_size(document) == 2,
       do:
         render_document(%{"message" => message, "records" => [], "slack_mentions" => authority})

  defp render_document(
         %{
           "message" => message,
           "records" => records,
           "slack_mentions" => authority
         } = document
       )
       when map_size(document) == 3 do
    with :ok <- message(message),
         :ok <- Records.validate(records),
         {:ok, text} <- Mentions.render(message, authority),
         {:ok, record_blocks} <- Records.render(records),
         :ok <- block_count(text, record_blocks) do
      {:ok,
       %{
         "blocks" => message_blocks(text) ++ record_blocks,
         "text" => text
       }}
    else
      {:error, {:invalid_slack_mentions, _reason}} ->
        {:error, {:invalid_slack_render, :mentions}}

      {:error, _reason} = error ->
        error
    end
  end

  defp render_document(%{"message" => message, "records" => records} = document)
       when map_size(document) == 2 do
    with :ok <- message(message),
         :ok <- Records.validate(records),
         {:ok, record_blocks} <- Records.render(records),
         text = escape(message),
         :ok <- block_count(text, record_blocks) do
      {:ok,
       %{
         "blocks" => message_blocks(text) ++ record_blocks,
         "text" => text
       }}
    end
  end

  defp render_document(_document), do: {:error, {:invalid_slack_render, :document}}

  defp block_count(text, record_blocks) do
    if length(message_blocks(text)) + length(record_blocks) <= @maximum_blocks,
      do: :ok,
      else: {:error, {:invalid_slack_render, :blocks}}
  end

  defp message(value) do
    if Fields.text?(value) and String.length(value) <= @maximum_message_characters,
      do: :ok,
      else: {:error, {:invalid_slack_render, :message}}
  end
end
