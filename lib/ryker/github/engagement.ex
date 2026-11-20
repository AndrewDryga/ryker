defmodule Ryker.GitHub.Engagement do
  @moduledoc "Host-owned quiet-default eligibility for authenticated GitHub inputs."
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.GitHub.{Binding, Confirmations, Labels}
  alias Ryker.GitHub.Input, as: GitHubInput
  alias Ryker.Ingress
  alias Ryker.Repo

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc """
  Why Ryker takes this input, or `:metadata` when it does not. A `:mention`,
  `:reply`, `:review_request` or `:continuation` is someone asking, so the router needs
  their write access; a `:revision` is an edit of the exact item Ryker already took, and a
  `:standing_rule` is an event an operator chose to have handled.
  """
  @spec reason(Ingress.Input.t(), Binding.t(), String.t() | nil, function()) ::
          {:yes, :review_request | :revision | :continuation | :standing_rule | :mention | :reply}
          | :metadata
          | {:error, term()}
  def reason(%Ingress.Input{} = input, %Binding{} = binding, bot_login, review_reply) do
    cond do
      review_requested?(input.content["event_name"], input.content["payload"], binding) ->
        {:yes, :review_request}

      engaged_input?(input) ->
        {:yes, :revision}

      continuation?(input) ->
        {:yes, :continuation}

      Behaviors.standing_match?(input) ->
        {:yes, :standing_rule}

      mentioned?(input, bot_login) ->
        {:yes, :mention}

      true ->
        addressed_reply(input, binding, review_reply)
    end
  end

  @doc "Whether the signed payload alone identifies a human request, for permission feedback."
  # A denied sender must not cause a parent-comment API read. Direct review
  # replies without a mention are recognized only after Write authorization.
  def explicit_request?(%Ingress.Input{actor: %{kind: :user}} = input, binding, bot_login) do
    review_requested?(input.content["event_name"], input.content["payload"], binding) or
      mentioned?(input, bot_login) or
      Confirmations.required_repository_role(input.content["payload"]) == :maintain
  end

  def explicit_request?(_input, _binding, _bot_login), do: false

  defp addressed_reply(
         %{
           content: %{
             "event_name" => "pull_request_review_comment",
             "payload" => %{"action" => action, "comment" => %{"in_reply_to_id" => _id}} = payload
           }
         },
         binding,
         review_reply
       )
       when action in ["created", "edited"] do
    case review_reply.(binding, payload) do
      {:ok, true} -> {:yes, :reply}
      {:ok, false} -> :metadata
      {:error, reason} -> {:error, reason}
    end
  end

  defp addressed_reply(_input, _binding, _review_reply), do: :metadata

  @doc "Whether this event explicitly requests a review from the configured bot."
  @spec review_requested?(String.t(), map(), Binding.t()) :: boolean()
  def review_requested?(
        "pull_request",
        %{
          "action" => "review_requested",
          "requested_reviewer" => %{"id" => id, "type" => "Bot"}
        },
        %Binding{ryker_actor_id: id}
      ),
      do: true

  def review_requested?(event_name, payload, _binding),
    do: Labels.review_request?(event_name, payload)

  @doc "The operator-selected review profile for an authorized review request on this pull request."
  def work_profile(_reason, _input, %{review_work_profile: nil} = binding, _login),
    do: binding.work_profile

  def work_profile(:review_request, _input, binding, _login), do: binding.review_work_profile

  def work_profile(reason, %{content: content} = input, binding, login)
      when reason in [:mention, :continuation] and is_binary(login) do
    pull_comment? =
      content["event_name"] == "pull_request_review_comment" or
        (content["event_name"] == "issue_comment" and
           is_map(get_in(content, ["payload", "issue", "pull_request"])))

    if pull_comment? and mentioned?(input, login) and
         addressed_review?(GitHubInput.body(content), login),
       do: binding.review_work_profile,
       else: binding.work_profile
  end

  def work_profile(_reason, _input, binding, _login), do: binding.work_profile

  defp addressed_review?(text, login) do
    # A question about an existing review uses normal routing. The new comment
    # has to address the App and ask it to perform a review.
    pattern =
      ~r/^\s*@#{Regex.escape(login)}(?:\[bot\])?[, :]\s*(?:(?:can|could|would) you\s+)?(?:please\s+)?(?:re-?review|review)\b/im

    Regex.match?(pattern, strip_quoted_and_code(text))
  end

  # An edit, deletion, or redelivery of an item Ryker already accepted must
  # reach the same durable input lineage even before Admission has opened an
  # episode. This is deliberately limited to the exact source item.
  defp engaged_input?(input) do
    input.source.ref
    |> Ingress.Inbox.Entry.Query.engaged_github_item(input.source_item_ref)
    |> Repo.exists?()
  end

  defp continuation?(input) do
    "github"
    |> Episodes.Episode.Query.by_thread(
      input.destination.conversation_ref,
      input.destination.thread_ref
    )
    |> Episodes.Episode.Query.by_states(@active_states)
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
