defmodule Responder.State.LearningSources do
  @moduledoc "Bounded, host-owned source receipts carried across derived conversation memory."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Ingress.Inbox.Entry

  alias Responder.State.{
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    KnowledgeRevision,
    Observations
  }

  @maximum_sources 128
  @maximum_bytes 65_536
  @receipt_fields ~w(observation_id source_input_id revision fingerprint transport workspace_ref conversation_ref repository_ref visibility retained_at)

  def merge(groups) do
    with true <- Enum.all?(groups, &is_list/1),
         sources = List.flatten(groups),
         true <- Enum.all?(sources, &valid_shape?/1),
         sources = earliest_receipts(sources),
         true <-
           length(sources) <= @maximum_sources and
             byte_size(CanonicalJSON.encode!(sources)) <= @maximum_bytes do
      sources
    else
      _ -> nil
    end
  end

  defp earliest_receipts(sources) do
    sources
    |> Enum.group_by(&Map.delete(&1, "retained_at"))
    |> Enum.map(fn {_identity, receipts} -> Enum.min_by(receipts, &retained_at/1, DateTime) end)
    |> Enum.sort_by(&CanonicalJSON.encode!/1)
  end

  def oldest(sources, fallback \\ nil) do
    dates = for source <- sources || [], valid_shape?(source), do: retained_at(source)
    dates = if fallback, do: [fallback | dates], else: dates
    Enum.min(dates, DateTime, fn -> nil end)
  end

  defp retained_at(receipt) do
    {:ok, date, 0} = DateTime.from_iso8601(receipt["retained_at"])
    date
  end

  @doc "Filter inherited source eligibility before recall limits; locked validation still follows."
  def eligible(query, scope) do
    seconds = retention_seconds()

    from(item in query,
      where: not is_nil(item.source_dependencies),
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(COALESCE(?, '[]')::jsonb) r
            LEFT JOIN conversation_observations o ON o.id::text = r->>'observation_id'
            WHERE o.id IS NULL OR o.source_input_id::text IS DISTINCT FROM r->>'source_input_id'
              OR o.revision::text IS DISTINCT FROM r->>'revision'
              OR o.source_fingerprint IS DISTINCT FROM r->>'fingerprint'
              OR o.workspace_ref IS DISTINCT FROM ?
              OR o.workspace_ref IS DISTINCT FROM r->>'workspace_ref'
              OR o.transport IS DISTINCT FROM r->>'transport'
              OR o.conversation_ref IS DISTINCT FROM r->>'conversation_ref'
              OR o.repository_ref IS DISTINCT FROM r->>'repository_ref'
              OR (?::bigint IS NOT NULL AND (r->>'retained_at')::timestamptz <= clock_timestamp() - (? * interval '1 second'))
              OR NOT (
                o.conversation_ref = ? OR (? AND o.visibility = 'public' AND EXISTS (
                  SELECT 1 FROM slack_channel_memberships m
                  WHERE 'slack:' || m.workspace_ref || ':' || m.channel_ref = o.conversation_ref
                    AND m.status = 'joined' AND NOT m.private AND NOT m.external_shared
                ))
              )
          )
          """,
          item.source_dependencies,
          ^scope.workspace_ref,
          ^seconds,
          ^seconds,
          ^scope.conversation_ref,
          ^(scope.visibility == :public and scope.transport == "slack")
        )
    )
  end

  defp valid_shape?(receipt) when is_map(receipt) do
    Enum.sort(Map.keys(receipt)) == Enum.sort(@receipt_fields) and
      Enum.all?(
        ~w(observation_id source_input_id),
        &(Ecto.UUID.cast(receipt[&1]) == {:ok, receipt[&1]})
      ) and
      is_integer(receipt["revision"]) and receipt["revision"] > 0 and
      text?(receipt["fingerprint"], 64) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["fingerprint"]) and
      scope_shape?(receipt) and timestamp?(receipt["retained_at"])
  end

  defp valid_shape?(_), do: false

  defp scope_shape?(receipt) do
    Enum.all?(~w(transport workspace_ref conversation_ref), &text?(receipt[&1], 1024)) and
      (is_nil(receipt["repository_ref"]) or text?(receipt["repository_ref"], 1024)) and
      receipt["visibility"] in ~w(public private direct conversation)
  end

  defp text?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_), do: false

  def for_entry(entry) do
    identity = Observations.source_identity(entry)
    source = Repo.one(from(o in ConversationObservation, where: o.identity_key == ^identity))

    case source do
      %{source_input_id: id, revision: revision}
      when id == entry.id and revision == entry.revision ->
        [receipt(source)]

      _ ->
        nil
    end
  end

  def for_source(source) do
    existing =
      Repo.one(from(o in ConversationObservation, where: o.identity_key == ^source.identity_key))

    source = if existing, do: %{source | id: existing.id}, else: source

    source =
      if existing && existing.revision == source.revision &&
           existing.source_input_id == source.source_input_id,
         do: %{source | updated_at: existing.updated_at},
         else: source

    [receipt(source)]
  end

  def authorize_context(context, entry) do
    with {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
         true <- valid?(context.source_dependencies, scope) do
      context.source_dependencies
    else
      _ -> nil
    end
  end

  defp receipt(source) do
    %{
      "observation_id" => source.id,
      "source_input_id" => source.source_input_id,
      "revision" => source.revision,
      "fingerprint" => source.source_fingerprint,
      "transport" => source.transport,
      "workspace_ref" => source.workspace_ref,
      "conversation_ref" => source.conversation_ref,
      "repository_ref" => source.repository_ref,
      "visibility" => Atom.to_string(source.visibility),
      "retained_at" => DateTime.to_iso8601(source.updated_at)
    }
  end

  def freeze(context) do
    base =
      merge([for_entry(context.input_entry) | Enum.map(context.candidates, &candidate_sources/1)])

    fit(context, base)
  end

  defp fit(context, nil), do: %{context | source_dependencies: nil}

  defp fit(context, base) do
    sources =
      merge([base | Enum.map(context.observations ++ context.knowledge, &document_sources/1)])

    cond do
      is_list(sources) ->
        %{context | source_dependencies: sources}

      context.observations != [] ->
        fit(%{context | observations: Enum.drop(context.observations, -1)}, base)

      context.knowledge != [] ->
        omitted = List.last(context.knowledge)

        receipt =
          omitted
          |> Map.take(~w(source_ref version topic_key conversation_ref repository_ref))
          |> Map.put("reason", "source_capacity")

        fit(
          %{
            context
            | knowledge: Enum.drop(context.knowledge, -1),
              knowledge_omissions: context.knowledge_omissions ++ [receipt]
          },
          base
        )

      true ->
        %{context | source_dependencies: nil}
    end
  end

  defp candidate_sources(candidate),
    do: candidate.source_documents |> Enum.map(&input_sources/1) |> merge()

  defp input_sources(%{
         "source" => %{"kind" => kind, "ref" => ref},
         "native_input_id" => native,
         "revision" => revision,
         "content" => content
       }) do
    identity =
      CanonicalJSON.digest(%{
        "source_kind" => kind,
        "source_ref" => ref,
        "native_input_id" => native
      })

    with %{} = source <-
           Repo.one(from(o in ConversationObservation, where: o.identity_key == ^identity)),
         true <- source.revision == revision,
         %Entry{content: ^content} <- Repo.get(Entry, source.source_input_id) do
      [receipt(source)]
    else
      _ -> nil
    end
  end

  defp input_sources(_), do: nil

  def document_sources(%{"source_ref" => "observation:" <> id} = document) do
    case get_uuid(ConversationObservation, id) do
      %{note: note, source_dependencies: sources} = source when is_map(note) ->
        if Observations.document(source) == document, do: sources

      _ ->
        nil
    end
  end

  def document_sources(%{"source_ref" => "knowledge:" <> id, "version" => version}) do
    case if(Ecto.UUID.cast(id) == {:ok, id} and is_integer(version),
           do: Repo.get_by(KnowledgeRevision, knowledge_id: id, version: version)
         ) do
      %{source_dependencies: sources} -> sources
      _ -> nil
    end
  end

  def document_sources(%{"source_ref" => "continuity:" <> id} = document),
    do: summary_sources(get_uuid(ConversationSummary, id), document)

  def document_sources(%{"source_ref" => "continuity-rollup:" <> _} = document),
    do: summary_sources(Repo.get_by(ConversationRollup, ref: document["source_ref"]), document)

  def document_sources(_), do: []

  defp get_uuid(schema, id), do: if(Ecto.UUID.cast(id) == {:ok, id}, do: Repo.get(schema, id))

  defp summary_sources(%{state: state, source_dependencies: sources}, %{"state" => state}),
    do: sources

  defp summary_sources(_, _), do: nil

  def valid?(sources, scope) when is_list(sources) do
    if merge([sources]) == sources do
      ids = Enum.map(sources, & &1["observation_id"])

      notes =
        Repo.all(
          from(o in ConversationObservation,
            where: o.id in ^ids,
            order_by: [asc: o.id],
            lock: "FOR SHARE"
          )
        )

      notes = notes |> Observations.authorized_notes(scope) |> Map.new(&{&1.id, &1})
      Enum.all?(sources, &valid_receipt?(&1, notes[&1["observation_id"]], scope))
    else
      false
    end
  end

  def valid?(_, _), do: false

  defp valid_receipt?(_receipt, nil, _scope), do: false

  defp valid_receipt?(receipt, source, scope) do
    source.source_input_id == receipt["source_input_id"] and
      source.revision == receipt["revision"] and
      source.source_fingerprint == receipt["fingerprint"] and
      source.workspace_ref == scope.workspace_ref and
      source.workspace_ref == receipt["workspace_ref"] and
      source.transport == receipt["transport"] and
      source.conversation_ref == receipt["conversation_ref"] and
      source.repository_ref == receipt["repository_ref"] and
      unexpired?(receipt["retained_at"])
  end

  defp unexpired?(at) do
    seconds = retention_seconds()

    case DateTime.from_iso8601(at || "") do
      {:ok, time, 0} ->
        not is_integer(seconds) or seconds <= 0 or
          DateTime.after?(time, DateTime.add(DateTime.utc_now(), -seconds))

      _ ->
        false
    end
  end

  defp retention_seconds do
    settings = Application.get_env(:responder, :retention) || %{}

    value =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    if is_integer(value) and value > 0, do: value
  end
end
