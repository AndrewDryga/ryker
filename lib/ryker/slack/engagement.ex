defmodule Ryker.Slack.Engagement do
  @moduledoc """
  Host-owned Slack engagement lookup.

  A reply in a thread that already belongs to an episode, or where Ryker
  answered with a quick reply, is always eligible for admission, even when
  its channel is not configured for ambient watching. The model still decides
  how that input relates to the existing work.
  """

  import Ecto.Query

  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Episodes.Episode
  alias Ryker.Repo

  @spec continuation?(map()) :: boolean()
  def continuation?(%{
        input: %{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: thread_ref,
            transport: "slack"
          }
        }
      })
      when is_binary(conversation_ref) and is_binary(thread_ref) do
    Repo.exists?(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref == ^conversation_ref and
            episode.destination_thread_ref == ^thread_ref
      )
    ) or
      Repo.exists?(
        from(response in RoutingResponse,
          where:
            response.kind == :message and response.transport == "slack" and
              response.conversation_ref == ^conversation_ref and
              response.thread_ref == ^thread_ref
        )
      )
  end

  def continuation?(_normalized), do: false
end
