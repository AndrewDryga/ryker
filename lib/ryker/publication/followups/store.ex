defmodule Ryker.Publication.Followups.Store do
  @moduledoc """
  The rows every follow-up stage writes: a published pull request's follow-up,
  and the lifecycle events recorded against it.

  A lifecycle event's ref, id and delivery ref all derive from one key, so the
  same observation recorded twice is one row: the second insert finds the
  first and reports a duplicate. The argument checks and the transaction
  wrapper here are the ones every stage's entry uses. Every row written here
  is announced as a change to its publication (`Ryker.Publication.Custody`).
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Publication.Custody
  alias Ryker.Publication.{Followup, LifecycleEvent}
  alias Ryker.Repo

  # --- entries --------------------------------------------------------------

  @doc "Runs `fun` in one transaction; the reason it rolled back with is the error."
  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reference(term(), atom()) :: :ok | {:error, {:invalid_publication_followup, atom()}}
  def reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication_followup, field}}
  end

  @spec positive(term(), atom()) :: :ok | {:error, {:invalid_publication_followup, atom()}}
  def positive(value, _field) when is_integer(value) and value > 0, do: :ok
  def positive(_value, field), do: {:error, {:invalid_publication_followup, field}}

  # --- follow-ups -----------------------------------------------------------

  @doc "Locks the follow-up of a publication that must have one."
  @spec lock_followup(Ecto.UUID.t()) :: Followup.t()
  def lock_followup(publication_id) do
    publication_id
    |> Followup.Query.by_publication_id()
    |> Followup.Query.lock_for_update()
    |> Repo.one!()
  end

  @spec update_followup!(Followup.t(), map(), DateTime.t()) :: Followup.t()
  def update_followup!(followup, attributes, now) do
    followup
    |> Followup.Changeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
    |> tap(&Custody.broadcast_publication_updated(&1.publication_id))
  end

  # --- lifecycle events -----------------------------------------------------

  @spec lock_lifecycle_event(String.t()) :: {:ok, LifecycleEvent.t()} | {:error, :not_found}
  def lock_lifecycle_event(event_ref) do
    event_ref
    |> LifecycleEvent.Query.by_ref()
    |> LifecycleEvent.Query.lock_for_update()
    |> Repo.fetch()
  end

  @spec update_event!(LifecycleEvent.t(), map(), DateTime.t()) :: LifecycleEvent.t()
  def update_event!(event, attributes, now) do
    event
    |> LifecycleEvent.Changeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
    |> tap(&Custody.broadcast_publication_updated(&1.publication_id))
  end

  @doc "The key a lifecycle event is known by: a digest of what makes it the same event."
  @spec lifecycle_key([term()]) :: String.t()
  def lifecycle_key(parts), do: CanonicalJSON.digest(parts) |> binary_part(0, 32)

  @doc "A lifecycle event's row: its ref, id and delivery ref all come from its key."
  @spec lifecycle_event(map(), map()) :: map()
  def lifecycle_event(publication, attributes) do
    key = attributes.key
    source = attributes.source
    id = deterministic_uuid(key)

    %{
      delivery_ref: "publication-lifecycle:#{key}",
      episode_id: publication.episode_id,
      id: id,
      kind: attributes.kind,
      observation: attributes.observation,
      occurred_at: attributes.occurred_at,
      publication_id: publication.id,
      ref: "publication-event:#{key}",
      source_conversation_ref: source && source.conversation_ref,
      source_item_ref: source && source.item_ref,
      source_transport: source && source.transport,
      state: attributes.state,
      summary: attributes.summary,
      wakeup_state: if(attributes.wakeup?, do: :pending, else: :none)
    }
  end

  @spec insert_lifecycle_event!(map()) :: LifecycleEvent.t()
  def insert_lifecycle_event!(attributes) do
    case insert_lifecycle_event(attributes) do
      {:ok, event} -> event
      {:duplicate, event} -> event
    end
  end

  @doc "Inserts a lifecycle event once; recording it again returns the first as a duplicate."
  @spec insert_lifecycle_event(map()) ::
          {:ok, LifecycleEvent.t()} | {:duplicate, LifecycleEvent.t()}
  def insert_lifecycle_event(attributes) do
    changeset = LifecycleEvent.Changeset.insert(attributes)

    if changeset.valid? do
      now = Repo.now!()

      row =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.from_struct()
        |> Map.drop([:__meta__, :episode, :publication])
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {count, _rows} =
        Repo.insert_all(LifecycleEvent, [row],
          conflict_target: [:ref],
          on_conflict: :nothing
        )

      event = Repo.one!(LifecycleEvent.Query.by_ref(attributes.ref))

      if count == 1 do
        Custody.broadcast_publication_updated(event.publication_id)
        {:ok, event}
      else
        {:duplicate, event}
      end
    else
      Repo.rollback({:publication_lifecycle_persistence_failed, changeset.errors})
    end
  end

  defp deterministic_uuid(key) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _rest::binary>> =
      Crypto.sha256_hex(key)

    Enum.join([a, b, c, d, e], "-")
  end
end
