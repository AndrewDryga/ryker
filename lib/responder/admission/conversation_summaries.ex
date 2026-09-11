defmodule Responder.Admission.ConversationSummaries do
  @moduledoc """
  Selects the latest thread and parent-channel summary a captured context may show.

  A summary is a bounded hint, never evidence. Selection is source-safe: a
  revision derived from a message after this input's cutoff is refused rather
  than shown, because a newer summary would otherwise leak future messages
  into an earlier decision. A withdrawn or unauthorized source makes the
  summary unavailable rather than laundering its text. When none is available
  the manifest says so, and the actual recent messages carry the context.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.State.{Continuity, ConversationSummary, LearningSources}

  @freshness_window 24 * 60 * 60

  @type selection :: map()

  @doc "The thread summary of this input's exact thread, or an explicit unavailability."
  @spec thread(Entry.t(), DateTime.t()) :: selection()
  def thread(%Entry{destination_thread_ref: nil}, _now), do: unavailable("not_applicable")

  def thread(%Entry{} = entry, now),
    do: selected(entry, entry.destination_thread_ref, now)

  @doc "The parent-channel summary, which is never one episode's work summary."
  @spec channel(Entry.t(), DateTime.t()) :: selection()
  def channel(%Entry{} = entry, now), do: selected(entry, nil, now)

  defp selected(entry, thread_ref, now) do
    case Repo.transaction(fn -> selected_locked(entry, thread_ref, now) end) do
      {:ok, selection} -> selection
      {:error, _reason} -> unavailable("scope_unavailable")
    end
  end

  defp selected_locked(entry, thread_ref, now) do
    with {:ok, scope} <-
           Continuity.destination_context(destination(entry, thread_ref), entry.repository_ref),
         %ConversationSummary{} = summary <- latest(identity_key(entry, thread_ref)) do
      cond do
        after_cutoff?(summary, entry) ->
          unavailable("after_cutoff")

        not LearningSources.valid?(summary.source_dependencies, scope) ->
          unavailable("source_withdrawn")

        true ->
          document(summary, now)
      end
    else
      nil -> unavailable("absent")
      {:error, _reason} -> unavailable("scope_unavailable")
    end
  end

  defp destination(entry, thread_ref) do
    %{
      destination_transport: entry.destination_transport,
      destination_conversation_ref: entry.destination_conversation_ref,
      destination_thread_ref: thread_ref
    }
  end

  defp identity_key(entry, thread_ref) do
    CanonicalJSON.digest(%{
      "conversation_ref" => entry.destination_conversation_ref,
      "thread_ref" => thread_ref,
      "transport" => entry.destination_transport
    })
  end

  defp latest(identity_key) do
    Repo.one(
      from(summary in ConversationSummary,
        where: summary.identity_key == ^identity_key,
        order_by: [desc: summary.updated_at],
        limit: 1
      )
    )
  end

  # Slack message references are zero-padded decimal timestamps, so the
  # captured item of the summary's newest source orders against this input's
  # own item without parsing either as a number.
  defp after_cutoff?(%ConversationSummary{source_message_ref: ref}, %Entry{source_item_ref: item})
       when is_binary(ref) and is_binary(item),
       do: ref >= item

  defp after_cutoff?(%ConversationSummary{updated_at: updated_at}, %Entry{
         occurred_at: occurred_at
       }),
       do: DateTime.compare(updated_at, occurred_at) == :gt

  defp document(summary, now) do
    %{
      "status" => "available",
      "freshness" => freshness(summary, now),
      "covered_through" => DateTime.to_iso8601(summary.updated_at),
      "covered_source" => summary.source_message_ref,
      "document" => %{
        "state" => summary.state,
        "covered_through" => DateTime.to_iso8601(summary.updated_at),
        "freshness" => freshness(summary, now)
      }
    }
  end

  defp freshness(summary, now) do
    if DateTime.diff(now, summary.updated_at, :second) <= @freshness_window,
      do: "current",
      else: "stale"
  end

  defp unavailable(reason),
    do: %{"status" => "unavailable", "reason" => reason, "document" => nil}
end
