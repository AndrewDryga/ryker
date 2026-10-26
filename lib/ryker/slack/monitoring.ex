defmodule Ryker.Slack.Monitoring do
  @moduledoc """
  Host-owned monitoring receipts for an already delivered reply. Only kernel
  decisions in that reply's wait chain count; model reasoning is never public.
  Reconciliation also runs after restart, so PubSub isn't delivery custody.
  """
  alias Ryker.Config
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.InteractionAudits
  alias Ryker.UTCDateTime
  alias Ryker.Waits
  alias Ryker.Work

  @doc "Follows an original wait through ordered kernel events, ignoring unrelated turns."
  def project(wait_ref, events) do
    Enum.reduce(
      events,
      %{"checks" => 0, "last_check_at" => nil, "state" => "waiting", "owner_ref" => wait_ref},
      &advance/2
    )
  end

  defp advance(
         %{"kind" => "wait_resumed", "payload" => payload},
         %{"state" => "waiting", "owner_ref" => ref} = status
       ) do
    if payload["expected_wait"] == %{"kind" => "event", "ref" => ref},
      do: %{status | "state" => "checking", "owner_ref" => payload["turn_ref"]},
      else: status
  end

  defp advance(
         %{
           "kind" => "owner_transferred",
           "payload" => %{
             "expected_owner" => %{"kind" => "turn", "ref" => ref},
             "new_owner" => %{"kind" => "turn", "ref" => next}
           }
         },
         %{"state" => "checking", "owner_ref" => ref} = status
       )
       when is_binary(next) do
    %{status | "owner_ref" => next}
  end

  defp advance(
         %{"kind" => "result_accepted", "payload" => %{"expected_turn_ref" => ref} = payload},
         %{"state" => "checking", "owner_ref" => ref} = status
       ) do
    status = %{
      status
      | "checks" => status["checks"] + 1,
        "last_check_at" => payload["occurred_at"]
    }

    case payload do
      %{"delivery" => "none", "next_wait" => %{"kind" => "event", "ref" => next}} ->
        %{status | "state" => "waiting", "owner_ref" => next}

      %{"delivery" => "reply"} ->
        %{status | "state" => "reply", "owner_ref" => payload["delivery_ref"]}

      _ ->
        %{status | "state" => "ended", "owner_ref" => nil}
    end
  end

  defp advance(
         %{"kind" => "delivery_confirmed", "payload" => %{"expected_delivery_ref" => ref}},
         %{"state" => "reply", "owner_ref" => ref} = status
       )
       when is_binary(ref) do
    %{status | "state" => "replied", "owner_ref" => nil}
  end

  defp advance(_event, status), do: status

  @doc "Adds the receipt to this exact delivered reply, not the wait record's creator."
  def decorate(documents, turn) do
    case snapshot(turn) do
      {:ok, status} ->
        ref = turn.continuation["wait_ref"]

        Enum.map(documents, fn
          %{"kind" => "event_wait", "ref" => ^ref} = document ->
            Map.put(document, "presentation", %{"monitoring" => status})

          document ->
            document
        end)

      :not_found ->
        documents
    end
  end

  @doc "Queues changed monitoring receipts, paging every retained delivered wait reply."
  def reconcile, do: reconcile_page(nil)

  @doc "Queues the delivered wait replies of the request that just changed."
  def reconcile_episode(id) do
    Work.Turn.Query.monitoring_replies(nil)
    |> Work.Turn.Query.by_episode_id(id)
    |> Repo.all()
    |> queue()
  end

  defp reconcile_page(after_id) do
    turns = after_id |> Work.Turn.Query.monitoring_replies() |> Repo.all()

    case queue(turns) do
      :ok when length(turns) == 100 -> reconcile_page(List.last(turns).id)
      result -> result
    end
  end

  defp queue(turns) do
    Enum.reduce_while(turns, :ok, fn turn, :ok ->
      case queue_turn(turn) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp queue_turn(turn) do
    case snapshot(turn) do
      {:ok, status} ->
        with {:ok, _} <- InteractionAudits.record_monitoring(turn, status), do: :ok

      :not_found ->
        :ok
    end
  end

  @doc "Builds a receipt without reading prompts, tool output, or model decision reasons."
  def snapshot(%Work.Turn{delivered_at: %DateTime{}, operational_pruned_at: nil} = turn) do
    with %{"kind" => "wait", "wait_kind" => "event", "wait_ref" => ref} <- turn.continuation,
         true <- ref in (get_in(turn.delivery_document || %{}, ["outcome", "record_refs"]) || []),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(turn.episode_id)),
         true <- episode.destination_transport == "slack",
         true <- episode.destination_conversation_ref == turn.external_receipt["conversation_ref"],
         true <- episode.destination_thread_ref == turn.external_receipt["thread_ref"] do
      events =
        turn.episode_id
        |> Episodes.Event.Query.by_episode_id()
        |> Episodes.Event.Query.before_sequence(episode.next_sequence)
        |> Episodes.Event.Query.monitoring_decisions()
        |> Episodes.Event.Query.ordered_by_sequence()
        |> Repo.all()

      status = project(ref, events)
      state = current_state(status, episode)

      %{
        "checks" => status["checks"],
        "last_check_at" => status["last_check_at"],
        "state" => state,
        "next_check_at" => if(state == "waiting", do: next_check(episode)),
        "history_url" => history_url(episode.id)
      }
      |> then(&{:ok, &1})
    else
      _unavailable -> :not_found
    end
  end

  def snapshot(_turn), do: :not_found

  defp current_state(_status, %{state: :cancelled}), do: "cancelled"
  defp current_state(%{"state" => "reply"}, _episode), do: "reply"
  defp current_state(%{"state" => "replied"}, _episode), do: "replied"
  defp current_state(_status, %{state: :complete}), do: "ended"

  defp current_state(%{"state" => "waiting", "owner_ref" => ref}, %{
         owner_kind: :event,
         owner_ref: ref
       }),
       do: "waiting"

  defp current_state(
         %{"state" => "checking", "owner_ref" => ref},
         %{owner_kind: :turn, owner_ref: ref} = episode
       ) do
    turn =
      episode.id
      |> Work.Turn.Query.by_episode_id()
      |> Work.Turn.Query.by_turn_ref(ref)
      |> Repo.peek()

    case turn do
      %Work.Turn{status: :blocked} -> "failed"
      _ -> "checking"
    end
  end

  defp current_state(_status, _episode), do: "stopped"

  defp next_check(episode) do
    record =
      episode.id
      |> Records.Record.Query.by_episode_id()
      |> Records.Record.Query.by_ref(episode.owner_ref)
      |> Repo.peek()

    case record do
      %Records.Record{} ->
        subscription =
          record.id
          |> Waits.EventSubscription.Query.by_record_id()
          |> Waits.EventSubscription.Query.active()
          |> Repo.peek()

        if subscription do
          [subscription.poll_after, subscription.deadline_at] |> UTCDateTime.earliest() |> iso()
        end

      nil ->
        nil
    end
  end

  defp history_url(id) do
    base = Config.get_env(:control_public_url, "")

    if String.starts_with?(base, "https://"),
      do: String.trim_trailing(base, "/") <> "/timeline/" <> id
  end

  defp iso(nil), do: nil
  defp iso(at), do: UTCDateTime.iso8601(at)
end
