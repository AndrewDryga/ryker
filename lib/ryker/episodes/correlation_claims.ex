defmodule Ryker.Episodes.CorrelationClaims do
  @moduledoc """
  Exclusive ownership of trusted occurrence identities.

  The claim is the only cross-conversation uniqueness fence: it holds a
  validated, source-backed occurrence identity scoped by security domain and
  reporting source. Fuzzy resource or symptom fingerprints never become
  claims, because two genuine incidents can share them.
  """

  import Ecto.Query

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
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(CorrelationClaim, [row],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(scope_ref, namespace, occurrence_ref) WHERE status = 'active'"},
           returning: true
         ) do
      {1, [claim]} ->
        {:ok, claim}

      {0, []} ->
        row.scope_ref
        |> owner(row.namespace, row.occurrence_ref)
        |> reconcile(row)
    end
  end

  defp reconcile(%CorrelationClaim{} = owner, row) when owner.episode_id == row.episode_id do
    if owner.lifecycle_state == row.lifecycle_state do
      {:ok, owner}
    else
      owner
      |> Ecto.Changeset.change(lifecycle_state: row.lifecycle_state)
      |> Repo.update()
    end
  end

  defp reconcile(%CorrelationClaim{} = owner, _row), do: {:error, {:occurrence_claimed, owner}}

  @spec owner(String.t(), String.t(), String.t()) :: CorrelationClaim.t() | nil
  def owner(scope_ref, namespace, occurrence_ref) do
    Repo.one(
      from(claim in CorrelationClaim,
        where:
          claim.scope_ref == ^scope_ref and claim.namespace == ^namespace and
            claim.occurrence_ref == ^occurrence_ref and claim.status == :active
      )
    )
  end

  @spec for_episode(Ecto.UUID.t()) :: [CorrelationClaim.t()]
  def for_episode(episode_id) do
    Repo.all(
      from(claim in CorrelationClaim,
        where: claim.episode_id == ^episode_id,
        order_by: [asc: claim.established_at, asc: claim.occurrence_ref]
      )
    )
  end

  @doc "Active occurrence identities owned by the given episodes, grouped by episode."
  @spec active_by_episode([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [CorrelationClaim.t()]}
  def active_by_episode([]), do: %{}

  def active_by_episode(episode_ids) do
    Repo.all(
      from(claim in CorrelationClaim,
        where: claim.episode_id in ^episode_ids and claim.status == :active,
        order_by: [asc: claim.established_at, asc: claim.occurrence_ref]
      )
    )
    |> Enum.group_by(& &1.episode_id)
  end

  @spec all_terminal?(Ecto.UUID.t()) :: boolean()
  def all_terminal?(episode_id) do
    not Repo.exists?(
      from(claim in CorrelationClaim,
        where:
          claim.episode_id == ^episode_id and claim.status == :active and
            claim.lifecycle_state == :active
      )
    )
  end

  @doc "Retires every active claim of an episode after an audited correction; rows are kept."
  @spec retire_in_transaction(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def retire_in_transaction(episode_id) do
    {count, _} =
      Repo.update_all(
        from(claim in CorrelationClaim,
          where: claim.episode_id == ^episode_id and claim.status == :active
        ),
        set: [status: :retired, updated_at: DateTime.utc_now()]
      )

    {:ok, count}
  end
end
