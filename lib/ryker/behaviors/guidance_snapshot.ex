defmodule Ryker.Behaviors.GuidanceSnapshot do
  @moduledoc "Content-free custody for the exact guidance a native Work session was shown."
  alias Ryker.Behaviors.{Behavior, Recall}
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work

  @maximum 10_000

  @doc "Authorize exact guidance documents without charging another recall."
  def authorize(documents, %Episodes.Episode{} = destination, %Work.Session{} = session, kind)
      when is_list(documents) and kind in [:explicit, :submission] do
    entries =
      Enum.reduce_while(documents, %{}, fn
        %{"kind" => "guidance", "behavior_ref" => ref, "revision" => revision} = document, entries
        when is_binary(ref) and is_integer(revision) and revision > 0 ->
          receipt = %{
            "revision" => revision,
            "sha256" => CanonicalJSON.digest(document),
            "automatic" => kind == :submission
          }

          {:cont, merge!(entries, %{ref => receipt})}

        _, _ ->
          {:halt, nil}
      end)

    case authorize_entries(entries, destination, session) do
      :ok -> {:ok, entries}
      other -> other
    end
  end

  def authorize(_documents, _destination, _session, _kind), do: :error

  @doc "Reauthorize a retained native transcript, including source and scope changes."
  def authorize_session(%Episodes.Episode{} = destination, %Work.Session{} = session) do
    case session.guidance_exposures do
      nil ->
        # An old native transcript has no proof of explicit guidance reads.
        # Rotate it before reuse; never manufacture an empty disclosure history.
        query = session.id |> Work.Turn.Query.by_session_id() |> Work.Turn.Query.begun()
        if is_nil(session.coop_session_id) and not Repo.exists?(query), do: :ok, else: :error

      entries ->
        authorize_entries(entries, destination, session)
    end
  end

  def authorize_session(_destination, _session), do: :error

  @doc "Retain validated direct and inherited guidance under the receiver's Session lock."
  def retain!(%Work.Session{} = session, entries, inherited) when is_map(entries) do
    producers =
      if inherited == [], do: [], else: inherited |> Work.Session.Query.by_ids() |> Repo.all()

    ledger =
      Enum.reduce(producers, session.guidance_exposures || %{}, fn producer, ledger ->
        merge!(ledger, producer.guidance_exposures)
      end)
      |> merge!(entries)

    if ledger != session.guidance_exposures do
      session |> Ecto.Changeset.change(guidance_exposures: ledger) |> Repo.update!()
    end

    :ok
  end

  def retain!(_session, _entries, _inherited), do: Repo.rollback(:work_knowledge_context_stale)

  defp authorize_entries(entries, %Episodes.Episode{} = destination, %Work.Session{} = session)
       when is_map(entries) and map_size(entries) <= @maximum do
    if map_size(entries) == 0 do
      :ok
    else
      authorize_nonempty(entries, destination, session)
    end
  end

  defp authorize_entries(_entries, _destination, _session), do: :error

  defp authorize_nonempty(entries, %Episodes.Episode{} = destination, %Work.Session{} = session) do
    # Channel deletion owns this fence before redacting Behavior rows. Match
    # that order even when guidance is the only source in the saved briefing.
    case Slack.ChannelFence.authorize_in_transaction(
           destination.destination_transport,
           destination.destination_conversation_ref
         ) do
      :ok -> authorize_locked_entries(entries, destination, session)
      _ -> :error
    end
  end

  defp authorize_nonempty(_entries, _destination, _session), do: :error

  defp authorize_locked_entries(
         entries,
         %Episodes.Episode{} = destination,
         %Work.Session{} = session
       ) do
    context = context(destination, session)
    refs = Map.keys(entries)

    query =
      refs
      |> Behavior.Query.by_refs()
      |> Behavior.Query.by_workspace(context.workspace_ref)
      |> Behavior.Query.by_kind(:guidance)
      |> Behavior.Query.by_status(:active)
      |> Behavior.Query.unexpired()
      |> Behavior.Query.visible_to(:guidance, context)
      |> Behavior.Query.ordered_by_ref()

    rows = query |> Behavior.Query.lock_for_share_skip_locked() |> Repo.all()

    cond do
      length(rows) != map_size(entries) and Repo.aggregate(query, :count) == map_size(entries) ->
        {:error, :work_derived_context_busy}

      length(rows) == map_size(entries) and
          Enum.all?(rows, &valid_entry?(&1, entries[&1.ref], context)) ->
        :ok

      true ->
        :error
    end
  end

  defp authorize_locked_entries(_entries, _destination, _session), do: :error

  defp valid_entry?(%Behavior{} = behavior, receipt, context) when is_map(receipt) do
    document = Recall.guidance_document(behavior)
    digest = CanonicalJSON.digest(document)

    Maps.exact_keys?(receipt, ~w(automatic revision sha256)) and
      is_boolean(receipt["automatic"]) and receipt["revision"] == behavior.revision and
      Crypto.sha256_hex?(receipt["sha256"]) and
      receipt["sha256"] == digest and
      (not receipt["automatic"] or applicable?(behavior, context))
  end

  defp valid_entry?(_behavior, _receipt, _context), do: false

  defp applicable?(%Behavior{scope_kind: :workspace, scope_ref: ref}, context),
    do: ref == context.workspace_ref

  defp applicable?(%Behavior{scope_kind: :conversation, scope_ref: ref}, context),
    do: ref == context.conversation_ref

  defp applicable?(%Behavior{scope_kind: :repository, scope_ref: ref}, context),
    do: ref == context.repository

  defp applicable?(%Behavior{scope_kind: :operator, scope_ref: ref}, context),
    do: ref == context.operator_ref

  defp applicable?(_behavior, _context), do: false

  defp context(%Episodes.Episode{} = destination, %Work.Session{} = session) do
    operator_ref = destination |> Episodes.Event.Query.select_asking_actor() |> Repo.one()

    %{
      conversation_ref: destination.destination_conversation_ref,
      workspace_ref: Episodes.Scope.workspace_ref(destination),
      repository: session.repository_ref,
      operator_ref: operator_ref
    }
  end

  defp context(_destination, _session), do: Repo.rollback(:work_knowledge_context_stale)

  defp merge!(left, right) when is_map(left) and is_map(right) do
    entries =
      Map.merge(left, right, fn _ref, previous, next ->
        if Map.drop(previous, ["automatic"]) != Map.drop(next, ["automatic"]),
          do: Repo.rollback(:work_knowledge_context_stale)

        automatic = previous["automatic"] or next["automatic"]
        Map.put(previous, "automatic", automatic)
      end)

    unless map_size(entries) <= @maximum,
      do: Repo.rollback(:work_memory_source_capacity_exceeded)

    refs = Map.keys(entries)

    unless Enum.all?(refs, &(Reference.valid?(&1, 256) and Reference.token?(&1))),
      do: Repo.rollback(:work_knowledge_context_stale)

    entries
  end

  defp merge!(_left, _right), do: Repo.rollback(:work_knowledge_context_stale)
end
