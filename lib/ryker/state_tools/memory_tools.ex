defmodule Ryker.StateTools.MemoryTools do
  @moduledoc false

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.State.{Continuity, Memories, MemorySearch}
  alias Ryker.StateTools.RecordWriter

  @spec search_memory(map(), map()) :: {:ok, map()} | {:error, term()}
  def search_memory(arguments, binding) do
    MemorySearch.search(binding, arguments, binding.cursor_secret)
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
    scope = effective_memory_scope(arguments["scope"], binding.episode)

    case arguments["kind"] do
      "guidance" ->
        payload = %{
          "expires_in" => expiry(arguments["expires_at"]),
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
          "expires_in" => expiry(arguments["expires_at"]),
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
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", workspace_ref, channel_ref] ->
        Repo.exists?(
          from(membership in ChannelMembership,
            where:
              membership.workspace_ref == ^workspace_ref and
                membership.channel_ref == ^channel_ref and membership.status == :joined and
                membership.private == false and membership.external_shared == false
          )
        )

      _invalid ->
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

  defp fact_visibility("current_channel"), do: "conversation"
  defp fact_visibility(_scope), do: "workspace"

  defp expiry(nil), do: "90d"

  defp expiry(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, 0} -> expiry_bucket(expires_at)
      _invalid -> "90d"
    end
  end

  defp expiry_bucket(expires_at) do
    days = max(DateTime.diff(expires_at, DateTime.utc_now(), :day), 0)

    cond do
      days <= 7 -> "7d"
      days <= 30 -> "30d"
      days <= 90 -> "90d"
      true -> "365d"
    end
  end
end
