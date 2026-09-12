defmodule Responder.Slack.Collections do
  @moduledoc """
  Delivers a requested collection of saved entities as one message per item.

  Active schedules, standing rules and saved knowledge visible in the requesting
  channel are listed in the requested thread, one saved-entity card each, with
  the same detail projection and removal controls as their confirmations. A
  page holds at most five items and names the exact total from its own scoped
  query. Empty and unavailable are different answers, and a retried request
  never posts an item twice.

  `page/4` reads the same scoped query one bounded page at a time over any set
  of channels, so the complete list an operator opens in App Home is the list
  the thread page was cut from rather than a second query with its own rules.
  """

  import Ecto.Query

  alias Responder.Repo
  alias Responder.Slack.SavedEntity
  alias Responder.State.{Behavior, MemoryEntry, Schedule}

  @page_size 5
  @kinds [:schedules, :standing_rules, :knowledge]

  @type kind :: :schedules | :standing_rules | :knowledge
  @type request :: %{
          channel_ref: String.t(),
          request_ref: String.t(),
          thread_ref: String.t(),
          workspace_ref: String.t()
        }
  @type scope :: %{channel_refs: [String.t()], workspace_ref: String.t()}
  @type page :: %{
          entries: [Schedule.t() | Behavior.t() | MemoryEntry.t()],
          offset: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec deliver(kind(), request(), map()) :: {:ok, map()} | {:error, term()}
  def deliver(kind, request, options) when kind in @kinds do
    case page(kind, scope(request), 0, @page_size) do
      {:ok, page} -> deliver_page(kind, page, request, options)
      {:error, _reason} -> deliver_summary(unavailable(kind), :unavailable, 0, request, options)
    end
  end

  def deliver(_kind, _request, _options), do: {:error, :invalid_collection}

  @doc """
  Reads one bounded page of the same scoped collection query.

  The page is cut from the complete authorized result, so `total` is the exact
  number of items the reader may see and every item is reachable by asking for
  its offset. An offset past the end names the last page that still exists.
  """
  @spec page(kind(), scope(), non_neg_integer(), pos_integer()) ::
          {:ok, page()} | {:error, term()}
  def page(kind, scope, offset, limit)
      when kind in @kinds and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 do
    with {:ok, entities} <- load(kind, scope) do
      total = length(entities)
      offset = bounded_offset(offset, total, limit)
      {:ok, %{entries: Enum.slice(entities, offset, limit), offset: offset, total: total}}
    end
  end

  def page(_kind, _scope, _offset, _limit), do: {:error, :invalid_collection}

  # A button rendered before items were removed names a page that no longer
  # exists; the last page that does is the honest answer, never a blank one.
  defp bounded_offset(_offset, 0, _limit), do: 0
  defp bounded_offset(offset, total, limit), do: min(offset, div(total - 1, limit) * limit)

  defp scope(request),
    do: %{channel_refs: [request.channel_ref], workspace_ref: request.workspace_ref}

  defp deliver_page(kind, %{entries: [], total: 0}, request, options),
    do: deliver_summary(empty(kind), :empty, 0, request, options)

  defp deliver_page(kind, %{entries: entries, total: total}, request, options) do
    with :ok <- deliver_items(entries, request, options),
         :ok <- deliver_continuation(kind, total, request, options) do
      {:ok, %{outcome: :delivered, shown: length(entries), total: total}}
    end
  end

  # Each item has its own delivery identity, so a failure on item 2 retries
  # item 2 without posting item 1 again.
  defp deliver_items(entities, request, options) do
    Enum.reduce_while(entities, :ok, fn entity, :ok ->
      document = %{"saved_entity" => SavedEntity.document(entity)}

      case post_once(
             document,
             "slack-collection:#{request.request_ref}:#{entity.ref}",
             request,
             options
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Home is operator-only, so the pointer names who can follow it: the
  # sentence used to promise everyone a complete list they could not open.
  defp deliver_continuation(kind, total, request, options) when total > @page_size do
    text =
      "Showing #{@page_size} of #{total} #{label(kind)} in this channel. " <>
        "Operators can open my App Home for the complete list."

    post_once(
      %{"message" => text},
      "slack-collection:#{request.request_ref}:more",
      request,
      options
    )
  end

  defp deliver_continuation(_kind, _total, _request, _options), do: :ok

  defp deliver_summary(text, outcome, total, request, options) do
    with :ok <-
           post_once(
             %{"message" => text},
             "slack-collection:#{request.request_ref}:#{outcome}",
             request,
             options
           ) do
      {:ok, %{outcome: outcome, shown: 0, total: total}}
    end
  end

  defp post_once(document, delivery_ref, request, options) do
    case options.api.find_message(
           options.client,
           request.channel_ref,
           request.thread_ref,
           delivery_ref
         ) do
      {:ok, _message_ref} ->
        :ok

      :not_found ->
        with {:ok, _message_ref} <-
               options.api.post_message(
                 options.client,
                 request.channel_ref,
                 request.thread_ref,
                 document,
                 delivery_ref
               ) do
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp load(kind, scope) do
    conversation_refs = Enum.map(scope.channel_refs, &"slack:#{scope.workspace_ref}:#{&1}")
    {:ok, entities(kind, scope.workspace_ref, conversation_refs, DateTime.utc_now())}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp entities(:schedules, _workspace_ref, conversation_refs, now) do
    Repo.all(
      from(schedule in Schedule,
        where:
          schedule.destination_transport == "slack" and
            schedule.destination_conversation_ref in ^conversation_refs and
            schedule.status in [:active, :paused] and
            (is_nil(schedule.expires_at) or schedule.expires_at > ^now),
        order_by: [asc: schedule.next_occurrence_at, asc: schedule.inserted_at, asc: schedule.id]
      )
    )
  end

  defp entities(:standing_rules, workspace_ref, conversation_refs, now) do
    Repo.all(
      from(behavior in Behavior,
        where:
          behavior.kind == :standing_assignment and
            behavior.workspace_ref == ^"slack:#{workspace_ref}" and
            behavior.scope_kind == :conversation and
            behavior.scope_ref in ^conversation_refs and
            behavior.status in [:active, :disabled] and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
        order_by: [desc: behavior.updated_at, desc: behavior.id]
      )
    )
  end

  defp entities(:knowledge, workspace_ref, conversation_refs, now) do
    slack_workspace = "slack:#{workspace_ref}"

    behaviors = knowledge_behaviors(slack_workspace, conversation_refs, now)
    memories = knowledge_memories(slack_workspace, conversation_refs, now)
    Enum.sort_by(behaviors ++ memories, & &1.updated_at, {:desc, DateTime})
  end

  # Operator-scoped (private) guidance belongs to one person and is never
  # listed for a channel; conversation items are listed only in their channel.
  defp knowledge_behaviors(slack_workspace, conversation_refs, now) do
    Repo.all(
      from(behavior in Behavior,
        where:
          behavior.kind in [:preference, :guidance] and
            behavior.workspace_ref == ^slack_workspace and
            ((behavior.scope_kind == :conversation and
                behavior.scope_ref in ^conversation_refs) or
               behavior.scope_kind in [:workspace, :repository]) and
            behavior.status in [:active, :disabled] and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
        order_by: [desc: behavior.updated_at, desc: behavior.id]
      )
    )
  end

  defp knowledge_memories(slack_workspace, conversation_refs, now) do
    Repo.all(
      from(memory in MemoryEntry,
        where:
          memory.workspace_ref == ^slack_workspace and memory.status == :active and
            (is_nil(memory.expires_at) or memory.expires_at > ^now) and
            ((memory.scope_kind == :conversation and memory.scope_ref in ^conversation_refs) or
               (memory.scope_kind in [:workspace, :repository] and
                  memory.visibility == :workspace)),
        order_by: [desc: memory.updated_at, desc: memory.id]
      )
    )
  end

  defp empty(:schedules), do: "No active schedules are set up in this channel."
  defp empty(:standing_rules), do: "No standing rules are set up in this channel."

  defp empty(:knowledge),
    do: "I haven't saved any preferences, guidance or memories for this channel."

  defp unavailable(kind),
    do: "I couldn't load this channel's #{label(kind)} right now. Try again in a moment."

  defp label(:schedules), do: "schedules"
  defp label(:standing_rules), do: "standing rules"
  defp label(:knowledge), do: "saved knowledge items"
end
