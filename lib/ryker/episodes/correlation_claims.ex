defmodule Ryker.Episodes.CorrelationClaims do
  @moduledoc """
  Exclusive ownership of trusted occurrence identities.

  The claim is the only cross-conversation uniqueness fence: it holds a
  validated, source-backed occurrence identity scoped by security domain and
  reporting source. Fuzzy resource or symptom fingerprints never become
  claims, because two genuine incidents can share them.
  """
  alias Ryker.Episodes.CorrelationClaim
  alias Ryker.Repo

  @type attributes :: %{
          episode_id: Ecto.UUID.t(),
          input_ref: String.t(),
          scope_ref: String.t(),
          namespace: String.t(),
          occurrence_ref: String.t(),
          lifecycle_state: :active | :terminal,
          established_at: DateTime.t()
        }

  @doc """
  Claims one occurrence for an episode, or reports its current active owner.

  Retrying the same input's claim returns the existing row. The insert relies
  on the partial unique index instead of a lookup-then-insert so two
  concurrent admissions cannot both succeed. When the owning episode reports
  the same occurrence again, the adapter's newest lifecycle state is recorded
  on that one signal; the episode's other signals keep their own state.
  """
  @spec claim_in_transaction(attributes()) ::
          {:ok, CorrelationClaim.t()} | {:error, {:occurrence_claimed, CorrelationClaim.t()}}
  def claim_in_transaction(attributes) do
    now = DateTime.utc_now()

    row =
      attributes
      |> Map.take(
        ~w(episode_id input_ref scope_ref namespace occurrence_ref lifecycle_state established_at)a
      )
      |> Map.put_new(:lifecycle_state, :active)
      |> Map.merge(%{id: Repo.generate_id(), inserted_at: now, updated_at: now})

    case Repo.insert_all(CorrelationClaim, [row],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(scope_ref, namespace, occurrence_ref) WHERE status = 'active'"},
           returning: true
         ) do
      {1, [claim]} ->
        Ryker.Episodes.broadcast_episode_updated(claim.episode_id)
        {:ok, claim}

      {0, []} ->
        row.scope_ref
        |> owner(row.namespace, row.occurrence_ref)
        |> reconcile(row)
    end
  end

  defp reconcile(%CorrelationClaim{} = owner_claim, row)
       when owner_claim.episode_id == row.episode_id do
    if owner_claim.lifecycle_state == row.lifecycle_state do
      {:ok, owner_claim}
    else
      Ryker.Episodes.broadcast_episode_updated(owner_claim.episode_id)

      owner_claim
      |> Ecto.Changeset.change(lifecycle_state: row.lifecycle_state)
      |> Repo.update()
    end
  end

  defp reconcile(%CorrelationClaim{} = owner_claim, _row),
    do: {:error, {:occurrence_claimed, owner_claim}}

  defp owner(scope_ref, namespace, occurrence_ref) do
    scope_ref
    |> CorrelationClaim.Query.by_occurrence(namespace, occurrence_ref)
    |> CorrelationClaim.Query.active()
    |> Repo.peek()
  end

  @spec for_episode(Ecto.UUID.t()) :: [CorrelationClaim.t()]
  def for_episode(episode_id) do
    episode_id
    |> CorrelationClaim.Query.by_episode_id()
    |> CorrelationClaim.Query.ordered_by_established_at()
    |> Repo.all()
  end

  @doc "Active occurrence identities owned by the given episodes, grouped by episode."
  @spec active_by_episode([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [CorrelationClaim.t()]}
  def active_by_episode([]), do: %{}

  def active_by_episode(episode_ids) do
    episode_ids
    |> CorrelationClaim.Query.by_episode_ids()
    |> CorrelationClaim.Query.active()
    |> CorrelationClaim.Query.ordered_by_established_at()
    |> Repo.all()
    |> Enum.group_by(& &1.episode_id)
  end

  @spec all_terminal?(Ecto.UUID.t()) :: boolean()
  def all_terminal?(episode_id) do
    not (episode_id
         |> CorrelationClaim.Query.by_episode_id()
         |> CorrelationClaim.Query.active()
         |> CorrelationClaim.Query.lifecycle_active()
         |> Repo.exists?())
  end

  @doc "Retires every active claim of a finished or cancelled episode; rows are kept."
  @spec retire_in_transaction(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def retire_in_transaction(episode_id) do
    {count, _} =
      episode_id
      |> CorrelationClaim.Query.by_episode_id()
      |> CorrelationClaim.Query.active()
      |> Repo.update_all(set: [status: :retired, updated_at: DateTime.utc_now()])

    {:ok, count}
  end
end
