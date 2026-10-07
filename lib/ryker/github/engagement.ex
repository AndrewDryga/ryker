defmodule Ryker.GitHub.Engagement do
  @moduledoc "Host-owned quiet-default eligibility for authenticated GitHub inputs."

  alias Ryker.Behaviors
  alias Ryker.Episodes.EpisodeQuery
  alias Ryker.GitHub.Binding
  alias Ryker.GitHub.Input, as: GitHubInput
  alias Ryker.Ingress.Inbox.EntryQuery
  alias Ryker.Ingress.Input
  alias Ryker.Repo

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc """
  Why Ryker takes this input, or `:metadata` when it does not. A `:mention` or a
  `:continuation` is someone asking, so the router needs their write access; a
  `:revision` is an edit of the exact item Ryker already took, and a
  `:standing_rule` is an event an operator chose to have handled.
  """
  @spec eligible?(Input.t(), Binding.t(), String.t() | nil) ::
          {:yes, :revision | :continuation | :standing_rule | :mention} | :metadata
  def eligible?(%Input{} = input, %Binding{}, bot_login) do
    cond do
      engaged_input?(input) -> {:yes, :revision}
      continuation?(input) -> {:yes, :continuation}
      Behaviors.standing_match?(input) -> {:yes, :standing_rule}
      mentioned?(input, bot_login) -> {:yes, :mention}
      true -> :metadata
    end
  end

  # An edit, deletion, or redelivery of an item Ryker already accepted must
  # reach the same durable input lineage even before Admission has opened an
  # episode. This is deliberately limited to the exact source item.
  defp engaged_input?(input) do
    input.source.ref
    |> EntryQuery.engaged_github_item(input.source_item_ref)
    |> Repo.exists?()
  end

  defp continuation?(input) do
    "github"
    |> EpisodeQuery.in_thread(input.destination.conversation_ref, input.destination.thread_ref)
    |> EpisodeQuery.in_states(@active_states)
    |> Repo.exists?()
  end

  # Only text this event wrote can ask: an item opened or edited, a comment or a
  # review written. A label, an assignment or a reopen carries the item's old
  # text, and counting the mention in it again made every later event on an item
  # that once named Ryker a fresh request (2026-10-04 review).
  @new_text_actions ~w(opened edited created submitted)

  defp mentioned?(input, bot_login) when is_binary(bot_login) do
    with %{"payload" => %{"action" => action}} when action in @new_text_actions <- input.content,
         "github-user:" <> id <- input.actor.ref,
         {_id, ""} <- Integer.parse(id),
         text when is_binary(text) <- GitHubInput.body(input.content) do
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

  defp strip_quoted_and_code(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`[^`]*`/, "")
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?(">")))
    |> Enum.join("\n")
  end
end
