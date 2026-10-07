defmodule Ryker.Slack.Engagement do
  @moduledoc """
  Host-owned Slack engagement lookup.

  A reply in a thread that already belongs to an episode, or where Ryker
  answered with a quick reply, is always eligible for admission, even when
  its channel is not configured for ambient watching. The model still decides
  how that input relates to the existing work.
  """

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
    Repo.exists?(Episode.Query.by_thread("slack", conversation_ref, thread_ref)) or
      Repo.exists?(
        RoutingResponse.Query.messages_in_thread("slack", conversation_ref, thread_ref)
      )
  end

  def continuation?(_normalized), do: false
end
