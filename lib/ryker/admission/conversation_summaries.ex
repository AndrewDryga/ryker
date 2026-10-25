defmodule Ryker.Admission.ConversationSummaries do
  @moduledoc """
  Selects the latest summary of an input's thread a captured context may show.

  The summaries Ryker saves are Work handovers, one per destination thread,
  so the input's own thread is the summary routing can be given. A summary is
  a bounded hint, never evidence. Selection is source-safe: a summary saved
  after this input arrived is refused rather than shown, because the work
  that saved it could have read later messages and would leak them into an
  earlier decision. A withdrawn or unauthorized source makes the summary
  unavailable rather than laundering its text. When none is available the
  manifest says so, and the actual recent messages carry the context.
  """
  alias Ryker.Continuity
  alias Ryker.Ingress
  alias Ryker.Learning
  alias Ryker.Repo
  alias Ryker.Work

  @freshness_window 24 * 60 * 60

  @type selection :: map()

  @doc "The summary of this input's exact thread, or an explicit unavailability."
  @spec thread(Ingress.Inbox.Entry.t(), DateTime.t()) :: selection()
  def thread(%Ingress.Inbox.Entry{destination_thread_ref: nil}, _now),
    do: unavailable("not_applicable")

  def thread(%Ingress.Inbox.Entry{} = entry, now) do
    case Repo.transaction(fn -> selected_locked(entry, now) end) do
      {:ok, selection} -> selection
      {:error, _reason} -> unavailable("scope_unavailable")
    end
  end

  @doc "Recheck a frozen summary's exact projection and sources before another disclosure."
  def reauthorize(%Ingress.Inbox.Entry{} = entry, %{"thread_summary" => %{} = document}, now) do
    if thread(entry, now)["document"] == document,
      do: :ok,
      else: {:error, {:admission_rejected, :context_stale}}
  end

  def reauthorize(%Ingress.Inbox.Entry{}, %{"thread_summary" => nil}, _now), do: :ok
  def reauthorize(%Ingress.Inbox.Entry{}, nil, _now), do: :ok

  def reauthorize(%Ingress.Inbox.Entry{}, %{} = bundle, _now)
      when not is_map_key(bundle, "thread_summary"),
      do: :ok

  def reauthorize(_entry, _bundle, _now),
    do: {:error, {:admission_rejected, :context_stale}}

  # The scope is the one the Work handover saved the summary under, so both
  # name the thread by the same identity key.
  defp selected_locked(entry, now) do
    environment_ref = Work.EnvironmentContext.ref(entry)

    with {:ok, scope} <- Continuity.destination_context(entry, entry.repository_ref),
         {:ok, summary} <- fetch_latest(scope, environment_ref) do
      cond do
        after_cutoff?(summary, entry) ->
          unavailable("after_cutoff")

        not Learning.LearningSources.valid?(summary.source_dependencies, scope) ->
          unavailable("source_withdrawn")

        true ->
          document(summary, now)
      end
    else
      :absent -> unavailable("absent")
      {:error, _reason} -> unavailable("scope_unavailable")
    end
  end

  defp fetch_latest(scope, environment_ref) do
    latest =
      scope.identity_key
      |> Continuity.ConversationSummary.Query.by_identity_key()
      |> Continuity.ConversationSummary.Query.by_environment(environment_ref)
      |> Learning.LearningSources.in_environment(environment_ref)
      |> Learning.LearningSources.eligible(scope)
      |> Continuity.ConversationSummary.Query.ordered_by_recently_updated()
      |> Continuity.ConversationSummary.Query.limit_to(1)

    with {:error, :not_found} <- Repo.fetch(latest), do: :absent
  end

  # When the summary was saved is what bounds what it can know. Its
  # `source_message_ref` names the saving episode's newest input by episode key
  # ("admit_input:<digest>"), which neither orders against a Slack timestamp
  # nor covers what that work read for itself.
  defp after_cutoff?(
         %Continuity.ConversationSummary{updated_at: updated_at},
         %Ingress.Inbox.Entry{
           occurred_at: occurred_at
         }
       ),
       do: DateTime.after?(updated_at, occurred_at)

  defp document(summary, now) do
    %{
      "status" => "available",
      "freshness" => freshness(summary, now),
      "covered_through" => DateTime.to_iso8601(summary.updated_at),
      "covered_source" => summary.source_message_ref,
      "document" => %{
        "source_ref" => summary.ref,
        "environment_ref" => summary.environment_ref,
        "environment_known" => summary.environment_known,
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
