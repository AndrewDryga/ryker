defmodule Ryker.Work.ThreadUpdates do
  @moduledoc "Human updates received before a Slack briefing freezes, separate from its authorized inputs."
  alias Ryker.{CanonicalJSON, Ingress, Knowledge, Learning, Repo, StateTools, Text, Work}

  @maximum_revisions 12

  def put(context, %{destination_transport: "slack"} = episode, %{first: first} = snapshot)
      when not is_nil(first) do
    source = first.payload["payload"]

    with %{"source" => %{"kind" => "slack"}, "native_input_id" => _} <- source,
         %Ingress.Inbox.Entry{} = opening <-
           Repo.peek(
             Ingress.Inbox.Entry.Query.by_work_source(Ingress.Inbox.Entry.Query.all(), source)
           ),
         true <- same_thread?(opening, episode) do
      seen =
        (snapshot.active ++ snapshot.historical)
        |> MapSet.new(fn event ->
          payload = event.payload["payload"]
          {payload["native_input_id"], payload["revision"]}
        end)

      received = received(opening)
      context = Map.put(context, "thread_receipt", receipt(opening, received))

      updates =
        received
        |> Enum.reject(&MapSet.member?(seen, {&1.native_input_id, &1.revision}))
        |> Enum.flat_map(&document/1)
        |> Enum.reverse()

      if updates == [], do: context, else: Map.put(context, "thread_updates", updates)
    else
      _ -> context
    end
  end

  def put(context, _episode, _snapshot), do: context

  @doc "Return newly received revisions once on a tool response, replaying the same RPC from durable custody."
  def for_tool(%{turn: %{thread_receipt: %{} = receipt}} = binding, call_id)
      when is_integer(call_id) or is_binary(call_id) do
    case Repo.transaction(fn -> tool_update_locked(binding, receipt, call_id) end) do
      {:ok, updates} -> updates
      {:error, _unavailable} -> nil
    end
  end

  def for_tool(_binding, _call_id), do: nil

  defp tool_update_locked(binding, original, call_id) do
    with {:ok, current} <- StateTools.Binding.fetch_and_lock_current_with_episode(binding),
         %{candidate_sha256: nil} <- current.turn,
         %Ingress.Inbox.Entry{} = opening <-
           Repo.peek(Ingress.Inbox.Entry.Query.by_id(original["opening"])),
         true <- same_thread?(opening, current.episode) do
      tool_disclosure(current, opening, original, call_id)
    else
      _ -> nil
    end
  end

  defp tool_disclosure(current, opening, original, call_id) do
    entries = received(opening)
    checkpoint = current.turn.thread_update_checkpoint
    current_receipt = receipt(opening, entries)

    cond do
      checkpoint && checkpoint["call"] == CanonicalJSON.digest(call_id) ->
        replay =
          opening
          |> Ingress.Inbox.Entry.Query.thread_updates(@maximum_revisions)
          |> Ingress.Inbox.Entry.Query.by_ids(checkpoint["exposed_ids"])
          |> Repo.all()

        disclose(current, replay, checkpoint)

      checkpoint || current_receipt == original ->
        nil

      true ->
        ids = current_receipt["inputs"] -- original["inputs"]

        checkpoint = %{
          "call" => CanonicalJSON.digest(call_id),
          "receipt" => current_receipt,
          "exposed_ids" => ids
        }

        with [_ | _] = documents <- disclose(current, entries, checkpoint) do
          current.turn
          |> Work.Turn.Changeset.expose_thread_updates(checkpoint)
          |> Repo.update!()

          documents
        end
    end
  end

  defp disclose(binding, entries, checkpoint) do
    docs =
      entries
      |> Enum.filter(&(&1.id in checkpoint["exposed_ids"]))
      |> Enum.reverse()
      |> Enum.flat_map(&document/1)

    sources = Enum.map(docs, &%{"kind" => "thread_update", "update" => &1})

    if docs != [] and length(docs) == length(checkpoint["exposed_ids"]) and
         Knowledge.KnowledgeSnapshot.expose(binding, sources) == :ok,
       do: docs
  end

  @doc "Checks a briefing against human revisions received in its Slack thread, including an initially empty thread."
  def verify(episode, %{thread_update_checkpoint: %{"receipt" => receipt}}),
    do: verify_receipt(episode, receipt)

  def verify(episode, %{thread_receipt: %{} = receipt}),
    do: verify_receipt(episode, receipt)

  def verify(_episode, _turn), do: :ok

  defp verify_receipt(episode, receipt) do
    with %{"opening" => id} <- receipt,
         {:ok, id} <- Ecto.UUID.cast(id),
         %Ingress.Inbox.Entry{} = opening <- Repo.peek(Ingress.Inbox.Entry.Query.by_id(id)),
         true <- same_thread?(opening, episode),
         ^receipt <- receipt(opening, received(opening)) do
      :ok
    else
      _changed -> {:error, :work_validation_state_changed}
    end
  end

  defp received(opening) do
    opening |> Ingress.Inbox.Entry.Query.thread_updates(@maximum_revisions) |> Repo.all()
  end

  defp receipt(opening, entries) do
    revisions = Enum.map(entries, &[&1.id, &1.revision])

    %{
      "opening" => opening.id,
      "inputs" => Enum.map(entries, & &1.id),
      "sha256" => CanonicalJSON.digest(revisions)
    }
  end

  @doc "Re-read the exact received revision before a session can expose or reuse its text."
  def sources(%{"input_id" => id} = frozen, episode) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Ingress.Inbox.Entry{actor_kind: :user, source_kind: "slack", operational_pruned_at: nil} =
           entry <-
           Repo.peek(Ingress.Inbox.Entry.Query.by_id(id)),
         true <- entry.status != :superseded and same_thread?(entry, episode),
         [^frozen] <- document(entry) do
      frozen["source_dependencies"]
    else
      _ -> nil
    end
  end

  def sources(_invalid, _episode), do: nil

  defp same_thread?(entry, episode) do
    entry.destination_transport == "slack" and episode.destination_transport == "slack" and
      is_binary(entry.destination_thread_ref) and
      entry.destination_thread_ref == episode.destination_thread_ref and
      entry.destination_conversation_ref == episode.destination_conversation_ref and
      entry.execution_mode == episode.execution_mode
  end

  defp document(entry) do
    case Learning.LearningSources.for_entry(entry) do
      [_ | _] = sources ->
        [
          %{
            "input_id" => entry.id,
            "source_item_ref" => entry.source_item_ref,
            "revision" => entry.revision,
            "event_kind" => Atom.to_string(entry.event_kind),
            "actor_ref" => entry.actor_ref,
            "received_at" => DateTime.to_iso8601(entry.inserted_at),
            "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
            "source_dependencies" => sources,
            "text" =>
              if(entry.event_kind != :delete,
                do: Text.shorten(Ingress.MessageText.authored(entry.content), 800)
              )
          }
        ]

      _ ->
        []
    end
  end
end
