defmodule Ryker.Records.DerivedContext do
  @moduledoc "Source custody for model-facing episode records and historical answers."
  alias Ryker.{CanonicalJSON, Maps, Repo}
  alias Ryker.Episodes
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Records.Outcomes
  alias Ryker.Records.Record
  alias Ryker.Work

  @kinds ~w(episode_record episode_delivery episode_outcome)
  @stale {:error, :work_knowledge_context_stale}
  @record_bytes 2_048
  @delivery_bytes 2_048

  def derived?(document), do: document["kind"] in @kinds
  def record(document), do: %{"kind" => "episode_record", "document" => document}
  def outcome(document), do: %{"kind" => "episode_outcome", "document" => document}
  def delivery(document), do: %{"kind" => "episode_delivery", "document" => document}

  @doc """
  A record's payload as a briefing keeps it and this module checks it: whole,
  or bounded (`Ryker.CanonicalJSON.bounded/2`) to one limit both share.
  """
  def record_payload(payload), do: CanonicalJSON.bounded(payload, @record_bytes)

  def delivery_document(%Work.Turn{} = turn) do
    %{
      "delivery" => CanonicalJSON.bounded(turn.delivery_document, @delivery_bytes),
      "submission_ref" => turn.submission_fingerprint,
      "source_turn_ref" => turn.id
    }
  end

  def submission_documents(context) do
    previous = continuation_delivery(context)

    Enum.map(context["records"] || [], &record/1) ++
      Enum.map(context["related_outcomes"] || [], &outcome/1) ++
      Enum.map(Enum.reject([context["prior_outcome"], previous], &is_nil/1), &delivery/1)
  end

  defp continuation_delivery(context) do
    case get_in(context, ["continuity", "previous_delivery"]) do
      nil ->
        nil

      previous ->
        %{
          "delivery" => previous,
          "submission_ref" => context["parent_submission_ref"],
          "source_turn_ref" => get_in(context, ["continuity", "previous_turn_ref"])
        }
    end
  end

  @doc "Filter optional history without changing its retained audit representation."
  def filter(documents, destination, repository) do
    {:ok, selected} =
      Repo.transaction(fn ->
        {proofs, sessions} = context(documents, destination, repository)

        proofs
        |> Enum.filter(fn {_document, proof} ->
          eligible?(proof, sessions, destination, repository)
        end)
        |> Enum.map(&elem(&1, 0))
      end)

    selected
  end

  @doc "Resolve only exact host-owned projections; references never authorize arbitrary prose."
  def resolve([], _destination, _repository), do: {:ok, %{sources: [], session_ids: []}}

  def resolve(documents, destination, repository) do
    {proofs, sessions} = context(documents, destination, repository)

    cond do
      Enum.any?(sessions, fn {_, session} ->
        session.sources == {:error, :work_derived_context_busy}
      end) ->
        {:error, :work_derived_context_busy}

      Enum.all?(proofs, fn {_document, proof} ->
        eligible?(proof, sessions, destination, repository)
      end) ->
        merged_context(proofs, sessions)

      true ->
        @stale
    end
  end

  defp merged_context(proofs, sessions) do
    groups =
      Enum.map(sessions, fn {_, session} -> session.sources end) ++
        Enum.map(proofs, fn {_, proof} -> proof.sources end)

    case Learning.LearningSources.merge(groups) do
      sources when is_list(sources) ->
        {:ok, %{sources: sources, session_ids: Map.keys(sessions)}}

      _ ->
        {:error, :work_memory_source_capacity_exceeded}
    end
  end

  defp context(documents, destination, repository) do
    proofs = Enum.map(documents, &{&1, proof(&1, destination)})

    ids =
      proofs
      |> Enum.flat_map(fn {_, proof} -> if proof, do: proof.turn_ids, else: [] end)
      |> Enum.uniq()

    owners = ids |> Work.Turn.Query.by_ids() |> Work.Turn.Query.select_sessions() |> Repo.all()
    session_ids = owners |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    sessions = session_ids |> Work.Session.Query.by_ids() |> Repo.all()

    contexts =
      Map.new(sessions, fn session ->
        # Exposure rows are accumulated for the whole native transcript. Taking
        # that union is conservative: later disclosures may invalidate an older
        # record, but must never make its old roots source-free or younger.
        sources =
          Knowledge.KnowledgeSnapshot.producer_sources(destination, %{
            session
            | repository_ref: repository
          })

        turn_ids = for {id, sid} <- owners, sid == session.id, do: id
        {session.id, %{id: session.id, turn_ids: turn_ids, sources: sources}}
      end)

    {proofs, contexts}
  end

  defp eligible?(nil, _sessions, _destination, _repository), do: false

  defp eligible?(proof, sessions, destination, repository) do
    available =
      sessions
      |> Map.values()
      |> Enum.filter(&is_list(&1.sources))
      |> Enum.flat_map(& &1.turn_ids)
      |> MapSet.new()

    Enum.all?(proof.turn_ids, &MapSet.member?(available, &1)) and
      valid_sources?(proof.sources, destination, repository)
  end

  defp valid_sources?([], _destination, _repository), do: true

  defp valid_sources?(sources, destination, repository) when is_list(sources) do
    case Learning.Observations.locked_scope(destination, repository) do
      {:ok, scope} -> Learning.LearningSources.valid?(sources, scope)
      _ -> false
    end
  end

  defp valid_sources?(_, _, _), do: false

  defp proof(%{"kind" => "episode_record", "document" => document}, destination) do
    with %Record{} = record <- Repo.one(Record.Query.by_ref(document["ref"])),
         true <- record.episode_id == destination.id,
         true <- record_projection?(document, record) do
      %{turn_ids: [record.turn_id], sources: []}
    else
      _ -> nil
    end
  end

  defp proof(%{"kind" => "episode_delivery", "document" => document}, destination) do
    with %Work.Turn{operational_pruned_at: nil} = turn <-
           get_uuid(&Work.Turn.Query.by_id/1, document["source_turn_ref"]),
         true <- turn.episode_id == destination.id,
         true <- not is_nil(turn.result_ref),
         true <- document == delivery_document(turn) do
      %{turn_ids: [turn.id], sources: []}
    else
      _ -> nil
    end
  end

  defp proof(%{"kind" => "episode_outcome", "document" => document}, destination) do
    with %Episodes.Episode{} = episode <-
           get_uuid(&Episodes.Episode.Query.by_id/1, document["episode_ref"]),
         true <- same_conversation?(episode, destination),
         %Work.Turn{episode_id: turn_episode_id, operational_pruned_at: nil} = turn <-
           get_uuid(&Work.Turn.Query.by_id/1, document["source_turn_ref"]),
         true <- turn_episode_id == episode.id,
         true <- outcome_state?(turn, document["state"]),
         %Episodes.Event{episode_id: episode_id, kind: :input_admitted} = event <-
           get_uuid(&Episodes.Event.Query.by_id/1, document["source_event_ref"]),
         true <- episode_id == episode.id,
         records when is_list(records) and length(records) <= 12 <- document["records"],
         proofs <- Enum.map(records, &proof(record(&1), episode)),
         true <- Enum.all?(proofs, &is_map/1),
         ^document <- Outcomes.projection(turn, event, records, document["state"]) do
      %{
        turn_ids: [document["source_turn_ref"] | Enum.flat_map(proofs, & &1.turn_ids)],
        sources: Learning.LearningSources.for_work_input(event.payload["payload"])
      }
    else
      _ -> nil
    end
  end

  defp proof(_, _), do: nil

  defp outcome_state?(%Work.Turn{result_ref: result}, "complete"), do: is_binary(result)

  defp outcome_state?(
         %Work.Turn{cancellation_intent: %{"action" => "block"}, cancellation_receipt: receipt},
         "blocked"
       ),
       do: is_map(receipt)

  defp outcome_state?(_, _), do: false

  defp record_projection?(document, record) do
    # Status is host lifecycle state and may advance after the briefing freezes;
    # only immutable identity/content defines this source-backed projection.
    Maps.only_keys?(document, ~w(kind payload ref status)) and
      document["kind"] == record.kind and
      document["status"] in [nil | ~w(open confirmed answered dismissed superseded)] and
      is_map(record.payload) and
      document["payload"] in [record.payload, record_payload(record.payload)]
  end

  defp same_conversation?(left, right) do
    left.destination_transport == right.destination_transport and
      left.destination_conversation_ref == right.destination_conversation_ref
  end

  # The row `by_id` finds for `id`, or nil when there is none or `id` is no UUID.
  defp get_uuid(by_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(by_id.(id))
      _ -> nil
    end
  end
end
