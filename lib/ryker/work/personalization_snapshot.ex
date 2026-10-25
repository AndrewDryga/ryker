defmodule Ryker.Work.PersonalizationSnapshot do
  @moduledoc "Reauthorize saved personal context before disclosing or reusing it."
  alias Ryker.Behaviors
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.People
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work.Session
  alias Ryker.Work.Turn

  @maximum 10_000
  @empty %{"facts" => %{}, "preferences" => %{}}

  @doc "Resolve a frozen briefing to current sources without copying personal text into custody."
  def authorize(_submission, %Episodes.Episode{}, %Session{}, :explicit), do: {:ok, @empty}

  def authorize(submission, %Episodes.Episode{} = destination, %Session{} = session, :submission)
      when is_map(submission) do
    context = get_in(submission, ["context", "operator_context"]) || %{}
    person = context["person_asking"]
    preferences = context["preferences"] || %{}
    actor = actor(destination)

    with {:ok, facts} <- facts(person, actor, destination.destination_conversation_ref),
         {:ok, preferences} <- preferences(preferences, destination, session, actor) do
      {:ok, %{"facts" => facts, "preferences" => preferences}}
    end
  end

  def authorize(_submission, _destination, _session, _kind), do: :error

  defp facts(nil, _actor, _conversation), do: {:ok, %{}}

  defp facts(%{"said_about_themselves" => facts} = document, actor, conversation) do
    if People.valid_facts?(facts) and document == People.model_context(facts),
      do: People.FactSnapshot.authorize(facts, actor, conversation),
      else: :error
  end

  defp facts(_document, _actor, _conversation), do: :error

  defp preferences(documents, %Episodes.Episode{} = destination, %Session{} = session, actor)
       when is_map(documents) do
    Enum.reduce_while(documents, {:ok, %{}}, fn {key, document}, {:ok, entries} ->
      with %{"behavior_ref" => ref} <- document,
           true <- is_binary(ref),
           {:ok, behavior} <- fetch_preference(ref, destination, session, actor),
           true <- key == behavior.payload["key"] and document == preference_document(behavior) do
        digest = preference_digest(behavior)
        {:cont, {:ok, Map.put(entries, ref, digest)}}
      else
        {:error, :work_derived_context_busy} -> {:halt, {:error, :work_derived_context_busy}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp preferences(_documents, _destination, _session, _actor), do: :error

  @doc "Recheck all personal context the native transcript or inherited records could contain."
  def authorize_session(%Episodes.Episode{} = destination, %Session{} = session) do
    case session.personalization_exposures do
      nil ->
        begun = session.id |> Turn.Query.by_session_id() |> Turn.Query.begun()
        if is_nil(session.coop_session_id) and not Repo.exists?(begun), do: :ok, else: :error

      entries ->
        authorize_entries(entries, destination, session)
    end
  end

  def authorize_session(_destination, _session), do: :error

  defp authorize_entries(entries, %Episodes.Episode{} = destination, %Session{} = session)
       when is_map(entries) do
    actor = actor(destination)

    with true <- Maps.exact_keys?(entries, ~w(facts preferences)),
         %{} = facts <- entries["facts"],
         %{} = preferences <- entries["preferences"],
         true <- map_size(facts) + map_size(preferences) <= @maximum,
         :ok <-
           People.FactSnapshot.authorize_receipts(
             facts,
             actor,
             destination.destination_conversation_ref
           ) do
      authorize_preferences(preferences, destination, session, actor)
    else
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> :error
    end
  end

  defp authorize_entries(_entries, _destination, _session), do: :error

  defp authorize_preferences(
         entries,
         %Episodes.Episode{} = destination,
         %Session{} = session,
         actor
       ) do
    Enum.reduce_while(entries, :ok, fn {ref, digest}, :ok ->
      case check_preference(ref, digest, destination, session, actor) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp authorize_preferences(_entries, _destination, _session, _actor), do: :error

  defp check_preference(
         ref,
         digest,
         %Episodes.Episode{} = destination,
         %Session{} = session,
         actor
       ) do
    case fetch_preference(ref, destination, session, actor) do
      {:ok, behavior} -> if digest == preference_digest(behavior), do: :ok, else: :error
      error -> error
    end
  end

  defp check_preference(_ref, _digest, _destination, _session, _actor), do: :error

  defp fetch_preference(ref, %Episodes.Episode{} = destination, %Session{} = session, actor)
       when is_binary(ref) do
    workspace = Episodes.Scope.workspace_ref(destination)

    scopes =
      [
        {:workspace, workspace},
        {:conversation, destination.destination_conversation_ref},
        {:operator, actor},
        {:repository, session.repository_ref}
      ]
      |> Enum.reject(fn {_kind, scope} -> is_nil(scope) end)

    query =
      ref
      |> Behaviors.Behavior.Query.by_ref()
      |> Behaviors.Behavior.Query.by_kind(:preference)
      |> Behaviors.Behavior.Query.by_status(:active)
      |> Behaviors.Behavior.Query.by_workspace(workspace)
      |> Behaviors.Behavior.Query.unexpired()
      |> Behaviors.Behavior.Query.by_any_scope(scopes)

    # Source deletion owns the channel fence before redacting the behavior.
    # Resolve its origin first and verify that origin again after the row lock.
    with {:ok, origin} <- Repo.fetch(query),
         :ok <-
           Slack.ChannelFence.authorize_in_transaction(
             destination.destination_transport,
             destination.destination_conversation_ref
           ),
         :ok <-
           Slack.ChannelFence.synchronize_in_transaction(
             origin.source_transport,
             origin.source_conversation_ref
           ) do
      fetch_and_lock_preference(query, origin)
    else
      _ -> :error
    end
  end

  defp fetch_preference(_ref, _destination, _session, _actor), do: :error

  defp fetch_and_lock_preference(query, %Behaviors.Behavior{} = origin) do
    locked = query |> Behaviors.Behavior.Query.lock_for_share_skip_locked() |> Repo.fetch()

    case locked do
      {:ok, behavior} ->
        if preference_digest(origin) == preference_digest(behavior),
          do: {:ok, behavior},
          else: :error

      _ ->
        if Repo.exists?(query), do: {:error, :work_derived_context_busy}, else: :error
    end
  end

  defp fetch_and_lock_preference(_query, _origin), do: :error

  defp preference_document(%Behaviors.Behavior{} = behavior) do
    %{
      "behavior_ref" => behavior.ref,
      "scope" => Atom.to_string(behavior.scope_kind),
      "value" => behavior.payload["value"]
    }
  end

  defp preference_document(_behavior), do: nil

  defp preference_digest(%Behaviors.Behavior{} = behavior) do
    document = preference_document(behavior)

    CanonicalJSON.digest(%{
      "document" => document,
      "key" => behavior.payload["key"],
      "revision" => behavior.revision,
      "scope_ref" => behavior.scope_ref,
      "source_transport" => behavior.source_transport,
      "source_conversation_ref" => behavior.source_conversation_ref,
      "source_message_ref" => behavior.source_message_ref
    })
  end

  defp preference_digest(_behavior), do: nil

  defp actor(%Episodes.Episode{} = destination),
    do: destination |> Episodes.Event.Query.select_asking_actor() |> Repo.one()

  defp actor(_destination), do: nil

  @doc "Retain the validated union under the receiver's existing Session lock."
  def retain!(%Session{} = session, entries, inherited) when is_map(entries) do
    producers =
      if inherited == [], do: [], else: inherited |> Session.Query.by_ids() |> Repo.all()

    ledger =
      Enum.reduce(producers, session.personalization_exposures || @empty, fn producer, ledger ->
        merge!(ledger, producer.personalization_exposures)
      end)
      |> merge!(entries)

    if ledger != session.personalization_exposures do
      session |> Ecto.Changeset.change(personalization_exposures: ledger) |> Repo.update!()
    end

    :ok
  end

  def retain!(_session, _entries, _inherited), do: Repo.rollback(:work_knowledge_context_stale)

  defp merge!(%{"facts" => left_facts, "preferences" => left_preferences}, %{
         "facts" => right_facts,
         "preferences" => right_preferences
       }) do
    ledger = %{
      "facts" => union!(left_facts, right_facts),
      "preferences" => union!(left_preferences, right_preferences)
    }

    if map_size(ledger["facts"]) + map_size(ledger["preferences"]) > @maximum,
      do: Repo.rollback(:work_memory_source_capacity_exceeded)

    ledger
  end

  defp merge!(_left, _right), do: Repo.rollback(:work_knowledge_context_stale)

  defp union!(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _ref, before, after_value ->
      if before != after_value, do: Repo.rollback(:work_knowledge_context_stale)
      before
    end)
  end

  defp union!(_left, _right), do: Repo.rollback(:work_knowledge_context_stale)
end
