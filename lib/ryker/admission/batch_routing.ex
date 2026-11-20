defmodule Ryker.Admission.BatchRouting do
  @moduledoc "Routes separately retained pieces of one person's Slack request from one frozen reading."
  alias Ryker.Admission
  alias Ryker.Admission.{Decision, Prompt}
  alias Ryker.Ingress
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Repo
  alias Ryker.RoutingExamples

  @same_scope ~w(source_kind source_ref actor_kind actor_ref destination_transport destination_conversation_ref destination_thread_ref execution_mode work_profile repository_ref work_policy_digest slack_audience slack_bot_user_ref source_capabilities engagement_receipt)a
  @work_actions [:start_episode, :continue_episode, :reply]

  def attach(%{input_entry: %Ingress.Inbox.Entry{id: id, routing_batch_ref: id}} = context)
      when is_binary(id) do
    entries =
      id
      |> Ingress.Inbox.Entry.Query.by_routing_batch()
      |> Ingress.Inbox.Entry.Query.ordered_by_oldest()
      |> Repo.all()

    siblings =
      entries
      |> Enum.reject(&(&1.id == id))
      |> Enum.take_while(&eligible?(&1, context.input_entry))

    with [_ | _] <- siblings,
         {:ok, scope} <-
           Learning.Observations.fetch_and_lock_scope(
             context.input_entry,
             context.input_entry.repository_ref
           ) do
      Enum.reduce_while(siblings, context, &fit_input(&1, &2, scope))
    else
      _ -> context
    end
  end

  def attach(%{input_entry: %{routing_batch_ref: batch} = entry} = context)
      when is_binary(batch) do
    with {:ok, head, parent} <- parent_for(entry),
         true <- Enum.any?(context.candidates, &(&1.episode.id == head.episode_id)),
         sources when is_list(sources) <-
           Learning.LearningSources.merge([
             context.source_dependencies,
             parent.source_dependencies
           ]),
         proof =
           head
           |> RoutingExamples.quoted_provenance()
           |> Map.merge(%{"id" => head.id, "decision_ref" => head.decision_ref}),
         fitted = %{context | batch_parent: proof, source_dependencies: sources},
         true <- Prompt.fits?(fitted) do
      fitted
    else
      _unavailable -> context
    end
  end

  def attach(context), do: context

  defp fit_input(entry, fitted, scope) do
    sources = Learning.LearningSources.for_entry(entry)
    merged = Learning.LearningSources.merge([fitted.source_dependencies, sources])
    doc = document(entry)
    next = %{fitted | batch_inputs: fitted.batch_inputs ++ [doc], source_dependencies: merged}

    if is_list(merged) and is_list(sources) and
         Learning.LearningSources.valid?(sources, scope) and Prompt.fits?(next) do
      {:cont, next}
    else
      {:halt, fitted}
    end
  end

  defp eligible?(
         %Ingress.Inbox.Entry{status: :pending, attempt_count: 0, operational_pruned_at: nil} =
           other,
         first
       ) do
    same_scope?(other, first) and is_binary(other.content["text"]) and
      not is_nil(other.source_item_ref)
  end

  defp eligible?(_entry, _first), do: false

  defp same_scope?(a, b), do: Map.take(a, @same_scope) == Map.take(b, @same_scope)

  defp document(entry) do
    %{
      "id" => entry.id,
      "fingerprint" => entry.event_fingerprint,
      "revision" => entry.revision,
      "message_ref" => entry.source_item_ref,
      "at" => DateTime.to_iso8601(entry.occurred_at),
      "text" => Ingress.MessageText.authored(entry.content)
    }
  end

  def model_inputs(inputs), do: Enum.map(inputs, &Map.take(&1, ~w(id at text)))

  def validate_selection(_context, %Decision{same_request_inputs: []}), do: :ok

  def validate_selection(context, %Decision{action: action, same_request_inputs: refs}) do
    offered = Enum.map(context.batch_inputs, & &1["id"])

    if action in @work_actions and Enum.all?(refs, &(&1 in offered)),
      do: :ok,
      else: {:error, {:admission_rejected, :batch_inputs}}
  end

  def schema(schema, []), do: schema

  def schema(schema, inputs) do
    put_in(schema, ["properties", "same_request_inputs"], %{
      "type" => "array",
      "maxItems" => length(inputs),
      "items" => %{"enum" => Enum.map(inputs, & &1["id"])},
      "uniqueItems" => true
    })
  end

  # Edits, forgetting or a change of access can invalidate a frozen reading
  # before submission, on replay or before its decision is committed.
  def authorize(%{input_entry: entry, batch_parent: %{"id" => id, "decision_ref" => ref}}) do
    case parent_for(entry) do
      {:ok, head, _context} when head.id == id and head.decision_ref == ref -> :ok
      _stale -> {:error, {:admission_rejected, :context_stale}}
    end
  end

  def authorize(%{batch_inputs: []}), do: :ok

  def authorize(%{input_entry: head, batch_inputs: inputs}) do
    case Repo.transaction(fn -> authorized?(head, inputs) end) do
      {:ok, true} -> :ok
      _stale -> {:error, {:admission_rejected, :context_stale}}
    end
  end

  defp authorized?(head, inputs) do
    entries = inputs |> Enum.map(& &1["id"]) |> Ingress.Inbox.Entry.Query.by_ids() |> Repo.all()
    frozen = Map.new(inputs, &{&1["id"], &1})

    with true <- length(entries) == map_size(frozen),
         {:ok, scope} <- Learning.Observations.fetch_and_lock_scope(head, head.repository_ref) do
      Enum.all?(entries, fn entry ->
        entry.routing_batch_ref == head.id and still_eligible?(entry, head) and
          document(entry) == frozen[entry.id] and current?(entry) and
          Learning.LearningSources.valid?(Learning.LearningSources.for_entry(entry), scope)
      end)
    else
      _ -> false
    end
  end

  defp still_eligible?(entry, %{status: :decided} = head) do
    same_scope?(entry, head) and entry.status != :superseded and
      is_nil(entry.operational_pruned_at)
  end

  defp still_eligible?(entry, head), do: eligible?(entry, head)

  defp current?(entry) do
    case Learning.LearningSources.for_entry(entry) do
      [_ | _] -> not Repo.exists?(Ingress.Inbox.Entry.Query.later_revisions_of(entry))
      _ -> false
    end
  end

  def related_decision(%{batch_parent: %{}, candidates: candidates, input_entry: entry}) do
    with {:ok, head, _context} <- parent_for(entry),
         %{ref: candidate} <- Enum.find(candidates, &(&1.episode.id == head.episode_id)) do
      %Decision{
        action: :continue_episode,
        relation: :same_work,
        episode_ref: candidate,
        work_class:
          if(head.decision_document["work_class"] == "deep", do: :deep, else: :standard),
        repository_source: nil,
        reason: "The sender added detail to the same request."
      }
    else
      _ -> nil
    end
  end

  def related_decision(_context), do: nil

  # The grouping came from the whole reading. A change to a third message,
  # a forgotten observation or newly private evidence invalidates that choice.
  defp parent_for(%{id: id, routing_batch_ref: batch} = entry) do
    with %Ingress.Inbox.Entry{
           status: :decided,
           decision_document: decision,
           admission_context: snapshot,
           episode_id: episode_id,
           decision_ref: ref
         } = head
         when is_binary(episode_id) and is_binary(ref) <-
           Repo.peek(Ingress.Inbox.Entry.Query.by_id(batch)),
         true <- head.routing_batch_ref == head.id and same_scope?(entry, head),
         false <- String.starts_with?(ref, "host:"),
         true <- id in List.wrap(decision["same_request_inputs"]),
         true <- Enum.member?(List.wrap(snapshot["batch_inputs"]), document(entry)),
         true <- is_nil(snapshot["batch_parent"]) and current?(head),
         false <- RoutingExamples.quotes_forgotten?(head),
         {:ok, parent} <- Admission.decided_context(head),
         :ok <- Admission.reauthorize_work_scope(parent),
         :ok <-
           Learning.Observations.reauthorize(entry, entry.repository_ref, parent.observations),
         :ok <- Knowledge.still_current(entry, entry.repository_ref, parent.knowledge) do
      {:ok, head, parent}
    else
      _ -> :stale
    end
  end
end
