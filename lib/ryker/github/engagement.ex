defmodule Ryker.GitHub.Engagement do
  @moduledoc "Host-owned quiet-default eligibility for authenticated GitHub inputs."

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.GitHub.Binding
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.State.Behaviors

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  def eligible?(%Input{} = input, %Binding{}, bot_login) do
    cond do
      continuation?(input) -> {:yes, :continuation}
      engaged_input?(input) -> {:yes, :continuation}
      Behaviors.standing_match?(input) -> {:yes, :standing_rule}
      mentioned?(input, bot_login) -> {:yes, :mention}
      true -> :metadata
    end
  end

  # An edit, deletion, or redelivery of an item Ryker already accepted must
  # reach the same durable input lineage even before Admission has opened an
  # episode. This is deliberately limited to the exact source item.
  defp engaged_input?(input) do
    Repo.exists?(
      from(entry in Entry,
        where:
          entry.source_kind == "github" and entry.source_ref == ^input.source.ref and
            entry.source_item_ref == ^input.source_item_ref and
            not is_nil(entry.engagement_receipt)
      )
    )
  end

  defp continuation?(input) do
    Repo.exists?(
      from(episode in Episode,
        where:
          episode.destination_transport == "github" and
            episode.destination_conversation_ref == ^input.destination.conversation_ref and
            episode.destination_thread_ref == ^input.destination.thread_ref and
            episode.state in ^@active_states
      )
    )
  end

  defp mentioned?(input, bot_login) when is_binary(bot_login) do
    with "github-user:" <> id <- input.actor.ref,
         {_id, ""} <- Integer.parse(id),
         text when is_binary(text) <- message_text(input.content) do
      cleaned = strip_quoted_and_code(text)

      Regex.match?(
        ~r/(?:^|[^A-Za-z0-9_-])@#{Regex.escape(bot_login)}(?:\[bot\])?(?:$|[^A-Za-z0-9_-])/i,
        cleaned
      )
    else
      _not_an_authorized_request -> false
    end
  end

  defp mentioned?(_input, _bot_login), do: false

  defp message_text(%{"payload" => payload}) do
    get_in(payload, ["comment", "body"]) || get_in(payload, ["review", "body"]) ||
      get_in(payload, ["issue", "body"]) || get_in(payload, ["pull_request", "body"])
  end

  defp message_text(_content), do: nil

  defp strip_quoted_and_code(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`[^`]*`/, "")
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?(">")))
    |> Enum.join("\n")
  end
end
