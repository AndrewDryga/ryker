defmodule Ryker.Delivery.Presentation do
  @moduledoc """
  Validates one accepted final against its exact destination renderer.

  Presentation failures are semantic candidate failures, not delivery-time
  surprises: the model can repair the same logical turn before Ryker owns
  an external side effect.
  """
  alias Ryker.Delivery.ChatCard
  alias Ryker.Episodes.Episode
  alias Ryker.GitHub.Renderer, as: GitHubRenderer
  alias Ryker.Slack.{Mentions, Renderer, ReplyRecords}
  alias Ryker.Work.Custody.Delivery
  alias Ryker.Work.{Final, Turn}

  # Rendered for where the answer goes: the destination of the input the turn
  # answers, which is the episode's home unless that input came from elsewhere,
  # like a comment on a Slack task's pull request, answered on GitHub.
  @spec validate(Episode.t(), Turn.t(), Final.t()) :: :ok | {:error, term()}
  def validate(%Episode{}, _turn, %Final{delivery: :none}), do: :ok

  def validate(%Episode{} = episode, %Turn{} = turn, %Final{delivery: :reply} = final) do
    transport = Delivery.answer_target(episode, turn)["transport"]

    with {:ok, records} <- ReplyRecords.fetch(episode.id, final.record_refs),
         :ok <- validate_native_records(transport, records) do
      render(transport, episode, %{
        "message" => final.message,
        "records" => ReplyRecords.documents(transport, episode.id, records)
      })
    end
  end

  def validate(_episode, _turn, _final),
    do: {:error, {:invalid_delivery_presentation, :document}}

  defp render("slack", episode, document) do
    case Renderer.render(Map.put(document, "slack_mentions", Mentions.authority(episode))) do
      {:ok, _rendered} -> :ok
      {:error, reason} -> {:error, {:invalid_delivery_presentation, reason}}
    end
  end

  defp render("github", _episode, document) do
    case GitHubRenderer.render(document) do
      {:ok, _rendered} -> :ok
      {:error, reason} -> {:error, {:invalid_delivery_presentation, reason}}
    end
  end

  # Chat renders escaped accepted prose and typed
  # native cards directly from the durable Work turn. Cards are projected here
  # too so an invalid presentation repairs in the same Coop turn.
  defp render("control_plane", _episode, _document), do: :ok

  defp render(transport, _episode, _document),
    do: {:error, {:invalid_delivery_presentation, {:unsupported_transport, transport}}}

  defp validate_native_records("control_plane", records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case ChatCard.project(record) do
        {:ok, _card} ->
          {:cont, :ok}

        :ignore ->
          {:halt,
           {:error, {:invalid_delivery_presentation, {:invalid_control_plane_card, record.ref}}}}
      end
    end)
  end

  defp validate_native_records(_transport, _records), do: :ok
end
