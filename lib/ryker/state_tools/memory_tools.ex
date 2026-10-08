defmodule Ryker.StateTools.MemoryTools do
  @moduledoc false
  alias Ryker.Continuity
  alias Ryker.ConversationRef
  alias Ryker.Memories
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.StateTools.RecordWriter

  @spec search_memory(map(), map()) :: {:ok, map()} | {:error, term()}
  def search_memory(arguments, binding) do
    Memories.MemorySearch.search(binding, arguments, binding.cursor_secret)
  end

  @spec remember_answer(map(), map()) :: {:ok, map()} | {:error, term()}
  def remember_answer(arguments, binding) do
    with {:ok, result} <-
           Memories.confirm_answer(
             binding,
             arguments["question_ref"],
             arguments["value"],
             binding.answer_authorizer
           ) do
      {:ok,
       %{
         "memory_ref" => result.memory.ref,
         "status" => "remembered",
         "scope" => "global",
         "subject" => result.memory.subject,
         "applicability" => result.memory.payload["applicability"],
         "value" => result.memory.payload["value"]
       }}
    end
  end

  @spec propose_memory(map(), map()) :: {:ok, map()} | {:error, term()}
  def propose_memory(arguments, binding) do
    with {:ok, expires_in} <- expiry(arguments["expires_at"]) do
      memory_offer(arguments, binding, expires_in)
    end
  end

  defp memory_offer(arguments, binding, expires_in) do
    scope = effective_memory_scope(arguments["scope"], binding.episode)

    case arguments["kind"] do
      "guidance" ->
        payload = %{
          "expires_in" => expires_in,
          "repository" => memory_repository(scope, binding),
          "scope" => memory_scope(scope),
          "subject" => arguments["subject"],
          "summary" => String.slice(arguments["value"], 0, 500),
          "text" => arguments["value"],
          "visibility" => memory_visibility(scope)
        }

        create_memory_record(
          binding,
          arguments,
          "guidance_offer",
          payload
        )

      "fact" ->
        payload = %{
          "expires_in" => expires_in,
          "kind" => "entity_relationship",
          "repository" => memory_repository(scope, binding),
          "scope" => fact_scope(scope),
          "subject" => arguments["subject"],
          "value" => arguments["value"],
          "visibility" => fact_visibility(scope)
        }

        create_memory_record(binding, arguments, "memory_offer", payload)
    end
  end

  @spec propose_preference(map(), map()) :: {:ok, map()} | {:error, term()}
  def propose_preference(arguments, binding) do
    scope = arguments["scope"] |> effective_memory_scope(binding.episode) |> memory_scope()

    with {:ok, expires_in} <- expiry(arguments["expires_at"]),
         payload = %{
           "expires_in" => expires_in,
           "key" => arguments["key"],
           "repository" => memory_repository(scope, binding),
           "scope" => scope,
           "value" => arguments["value"]
         },
         {:ok, result} <-
           RecordWriter.create_public_record(
             binding,
             "propose_preference",
             arguments,
             "preference_offer",
             payload,
             "preference_offer"
           ) do
      {:ok, Map.put(result, "proposal", payload)}
    end
  end

  @spec update_conversation_summary(map(), map()) :: {:ok, map()} | {:error, term()}
  def update_conversation_summary(%{"state" => state}, binding) do
    case Continuity.stage(binding.state_token, state) do
      {:ok, result} -> {:ok, Map.new(result, fn {key, value} -> {Atom.to_string(key), value} end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_memory_record(binding, arguments, kind, payload) do
    with {:ok, result} <-
           RecordWriter.create_public_record(
             binding,
             "propose_memory",
             arguments,
             kind,
             payload,
             "memory_offer"
           ) do
      {:ok, Map.put(result, "proposal", payload)}
    end
  end

  defp memory_repository("repository", binding), do: binding.session.repository_ref
  defp memory_repository(_scope, _binding), do: nil

  defp effective_memory_scope(scope, %{destination_transport: "slack"} = episode)
       when scope in ["repository", "workspace"] do
    if public_slack_destination?(episode), do: scope, else: "current_channel"
  end

  defp effective_memory_scope(scope, _episode), do: scope

  defp public_slack_destination?(%{destination_conversation_ref: conversation_ref}) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, workspace_ref, channel_ref} ->
        workspace_ref
        |> Slack.ChannelMembership.Query.by_channel(channel_ref)
        |> Slack.ChannelMembership.Query.joined_public()
        |> Repo.exists?()

      :error ->
        false
    end
  end

  defp memory_scope("mine"), do: "operator"
  defp memory_scope("current_channel"), do: "conversation"
  defp memory_scope(scope), do: scope

  defp fact_scope("mine"), do: "conversation"
  defp fact_scope("current_channel"), do: "conversation"
  defp fact_scope(scope), do: scope

  defp memory_visibility("mine"), do: "private"
  defp memory_visibility("current_channel"), do: "conversation"
  defp memory_visibility(_scope), do: "workspace"

  # A fact has no owner of its own: "mine" keeps it to the conversation it was
  # said in. Paired with workspace visibility, no fact record accepted it.
  defp fact_visibility(scope) when scope in ["mine", "current_channel"], do: "conversation"
  defp fact_visibility(_scope), do: "workspace"

  defp expiry(nil), do: {:ok, "90d"}

  # An offer lasts 7, 30, 90 or 365 days: the longest that does not outlast
  # the asked day, and 7 days for anything sooner. Eight days was kept for
  # thirty, and a time already past for seven without a word (2026-10-04
  # review); a past time is refused. The asked time is counted in whole days,
  # so thirty days asked a moment ago is still thirty.
  defp expiry(value) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(value),
         seconds when seconds >= 0 <- DateTime.diff(expires_at, Repo.now!(), :second) do
      days = div(seconds + 86_399, 86_400)

      cond do
        days >= 365 -> {:ok, "365d"}
        days >= 90 -> {:ok, "90d"}
        days >= 30 -> {:ok, "30d"}
        true -> {:ok, "7d"}
      end
    else
      _past_or_invalid -> {:error, :invalid_arguments}
    end
  end
end
