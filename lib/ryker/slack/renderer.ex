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

  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(%{"emisar_approval_status" => status} = document) when map_size(document) == 1,
    do: EmisarReview.render(status)

  def render(%{"incident_room" => room} = document) when map_size(document) == 1,
    do: WorkCards.incident_room(room)

  def render(%{"task_card" => task} = document) when map_size(document) == 1,
    do: WorkCards.task_card(task)

  def render(%{"channel_setup" => setup} = document) when map_size(document) == 1,
    do: ChannelSetup.render(setup)

  def render(%{"channel_welcome" => welcome} = document) when map_size(document) == 1,
    do: ChannelCards.welcome(welcome)

  def render(%{"channel_settings" => view} = document) when map_size(document) == 1,
    do: ChannelCards.settings(view)

  def render(%{"saved_entity" => entity} = document) when map_size(document) == 1 do
    case SavedEntityCard.validate(entity) do
      :ok ->
        {:ok,
         %{"blocks" => SavedEntityCard.blocks(entity), "text" => SavedEntityCard.text(entity)}}

      {:error, _reason} ->
        {:error, {:invalid_slack_render, :saved_entity}}
    end
  end

  def render(%{"message" => message} = document) when map_size(document) == 1,
    do: render(%{"message" => message, "records" => []})

  def render(
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

  def render(%{"message" => message, "records" => records} = document)
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

  def render(_document), do: {:error, {:invalid_slack_render, :document}}

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
