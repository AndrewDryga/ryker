defmodule Responder.Delivery.Presentation do
  @moduledoc """
  Validates one accepted final against its exact destination renderer.

  Presentation failures are semantic candidate failures, not delivery-time
  surprises: the model can repair the same logical turn before Responder owns
  an external side effect.
  """

  alias Responder.ControlPlane.Card, as: ControlPlaneCard
  alias Responder.Episodes.Episode
  alias Responder.GitHub.Renderer, as: GitHubRenderer
  alias Responder.Slack.{Mentions, Renderer}
  alias Responder.State.Records
  alias Responder.Work.Final

  @spec validate(Episode.t(), Ecto.UUID.t(), Final.t()) :: :ok | {:error, term()}
  def validate(%Episode{}, _turn_id, %Final{delivery: :none}), do: :ok

  def validate(%Episode{} = episode, turn_id, %Final{delivery: :reply} = final)
      when is_binary(turn_id) do
    with {:ok, records} <- Records.fetch_for_episode(episode.id, final.record_refs),
         :ok <- validate_native_records(episode, records) do
      render(episode, document(final, records))
    end
  end

  def validate(_episode, _turn_id, _final),
    do: {:error, {:invalid_delivery_presentation, :document}}

  defp document(final, records) do
    %{
      "message" => final.message,
      "records" =>
        Enum.map(records, fn record ->
          %{
            "kind" => record.kind,
            "payload" => record.payload,
            "ref" => record.ref,
            "status" => Atom.to_string(record.status)
          }
        end)
    }
  end

  defp render(%Episode{destination_transport: "slack"} = episode, document) do
    case Renderer.render(Map.put(document, "slack_mentions", Mentions.authority(episode))) do
      {:ok, _rendered} -> :ok
      {:error, reason} -> {:error, {:invalid_delivery_presentation, reason}}
    end
  end

  defp render(%Episode{destination_transport: "github"}, document) do
    case GitHubRenderer.render(document) do
      {:ok, _rendered} -> :ok
      {:error, reason} -> {:error, {:invalid_delivery_presentation, reason}}
    end
  end

  # The loopback Conversation Lab renders escaped accepted prose and typed
  # native cards directly from the durable Work turn. Cards are projected here
  # too so an invalid presentation repairs in the same Coop turn.
  defp render(%Episode{destination_transport: "control_plane"}, _document), do: :ok

  # The fabricated model world has a deterministic inert publisher rather
  # than an external platform renderer. It still exercises the real final,
  # state-record, custody, and delivery contracts end to end.
  defp render(%Episode{destination_transport: "eval"}, _document), do: :ok

  defp render(%Episode{destination_transport: transport}, _document),
    do: {:error, {:invalid_delivery_presentation, {:unsupported_transport, transport}}}

  defp validate_native_records(
         %Episode{destination_transport: "control_plane"},
         records
       ) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case ControlPlaneCard.project(record) do
        {:ok, _card} ->
          {:cont, :ok}

        :ignore ->
          {:halt,
           {:error, {:invalid_delivery_presentation, {:invalid_control_plane_card, record.ref}}}}
      end
    end)
  end

  defp validate_native_records(%Episode{}, _records), do: :ok
end
