defmodule Responder.CoopFleet.SessionEvidence do
  @moduledoc """
  Durable custody for worker-exported session evidence.

  A worker keeps no task or network transition ledger, so what it can honestly
  offer is the session as it stands right now. Responder records a series of
  those snapshots, keyed on the capture's content rather than its clock: a poll
  that found nothing changed advances the times on the state already recorded,
  and only a genuinely different session records a new row.

  That is also the idempotency rule. A redelivered command, a retried capture
  and two concurrent captures of the same state all converge on one row; the
  unique index is the arbiter, not a read-then-write in application code.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ecto.Changeset
  alias Responder.CanonicalJSON
  alias Responder.CoopFleet.SessionEvidenceDocument, as: Document
  alias Responder.Repo
  alias Responder.Work.Session

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_session_evidence" do
    belongs_to(:session, Responder.Work.Session)
    belongs_to(:episode, Responder.Episodes.Episode)
    field(:coop_session_id, :string)
    field(:worker_id, :string)
    field(:placement_generation, :integer)
    field(:evidence_version, :integer)
    field(:content_fingerprint, :string)
    field(:document, :string)
    field(:session_revision, :integer)
    field(:session_state, :string)
    field(:network_mode, :string)
    field(:task_status, :string)
    field(:first_captured_at, :utc_datetime_usec)
    field(:last_captured_at, :utc_datetime_usec)
    field(:capture_count, :integer)
  end

  @type t :: %__MODULE__{}

  @fields ~w(id session_id episode_id coop_session_id worker_id placement_generation
    evidence_version content_fingerprint document session_revision session_state network_mode
    task_status first_captured_at last_captured_at capture_count)a

  @doc """
  Records one validated export against its exact session, worker and placement.

  Returns `{:ok, %{evidence: row, recorded: :inserted | :unchanged}}`. `:unchanged`
  means this exact state was already recorded -- the capture still counts and its
  time still advances, but no new snapshot is invented.
  """
  @spec record(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{evidence: t(), recorded: :inserted | :unchanged}} | {:error, term()}
  def record(session_id, document, options \\ [])

  def record(session_id, %{} = document, options) when is_binary(session_id) do
    with {:ok, evidence} <- Document.validate(document),
         {:ok, worker_id} <- worker_id(options),
         {:ok, generation} <- placement_generation(options) do
      Repo.transaction(fn ->
        unwrap!(insert_locked(session_id, evidence, worker_id, generation))
      end)
    end
  end

  def record(_session_id, _document, _options),
    do: {:error, {:invalid_coop_session_evidence, :document}}

  @doc "Every recorded capture for one session, oldest state first."
  @spec for_session(Ecto.UUID.t()) :: [t()]
  def for_session(session_id) when is_binary(session_id) do
    Repo.all(
      from(evidence in __MODULE__,
        where: evidence.session_id == ^session_id,
        order_by: [asc: evidence.first_captured_at, asc: evidence.id]
      )
    )
  end

  def for_session(_session_id), do: []

  @doc """
  The latest capture per session for one episode, newest last.

  A card reads the newest state; the earlier rows stay available for the history
  behind it. An episode with no capture returns an empty list, which the caller
  must render as "not recorded" -- never as a session with no network.
  """
  @spec latest_for_episode(Ecto.UUID.t()) :: [t()]
  def latest_for_episode(episode_id) when is_binary(episode_id) do
    latest =
      from(evidence in __MODULE__,
        where: evidence.episode_id == ^episode_id,
        distinct: evidence.session_id,
        order_by: [asc: evidence.session_id, desc: evidence.last_captured_at, desc: evidence.id]
      )

    Repo.all(from(row in subquery(latest), order_by: [asc: row.last_captured_at, asc: row.id]))
  end

  def latest_for_episode(_episode_id), do: []

  @doc "The decoded document of one recorded capture."
  @spec document(t()) :: {:ok, map()} | {:error, term()}
  def document(%__MODULE__{document: document}), do: Document.decode(document)

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp insert_locked(session_id, evidence, worker_id, generation) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :work_session_not_found}

      %Session{coop_session_id: remote} when remote != nil ->
        if remote == evidence["session_id"] do
          upsert(session_id, evidence, worker_id, generation)
        else
          {:error, {:coop_session_evidence_session_conflict, evidence["session_id"]}}
        end

      %Session{} ->
        # An unbound local session has no remote identity to check the export
        # against, and binding it from the export would let a worker name the
        # session it is reporting on.
        {:error, {:coop_session_evidence_session_conflict, evidence["session_id"]}}
    end
  end

  defp upsert(session_id, evidence, worker_id, generation) do
    session = Repo.get!(Session, session_id)
    fingerprint = Document.content_fingerprint(evidence)
    captured_at = captured_at(evidence)

    attributes = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      episode_id: session.episode_id,
      coop_session_id: evidence["session_id"],
      worker_id: worker_id,
      placement_generation: generation,
      evidence_version: evidence["version"],
      content_fingerprint: fingerprint,
      document: CanonicalJSON.encode!(evidence),
      session_revision: evidence["revision"],
      session_state: evidence["state"],
      network_mode: evidence["network"]["mode"],
      task_status: evidence["task"]["status"],
      first_captured_at: captured_at,
      last_captured_at: captured_at,
      capture_count: 1
    }

    %__MODULE__{}
    |> Changeset.cast(attributes, @fields)
    |> Changeset.validate_required(@fields -- [:episode_id])
    |> Changeset.unique_constraint([:session_id, :content_fingerprint])
    |> Changeset.check_constraint(:document, name: :coop_session_evidence_valid)
    # A savepoint, because the losing side of the race has to keep its
    # transaction usable: it still has to find the row that beat it and count
    # its own observation against it.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, stored} ->
        {:ok, %{evidence: stored, recorded: :inserted}}

      {:error, %Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :session_id) do
          observe_again(session_id, fingerprint, captured_at)
        else
          {:error, {:coop_session_evidence_store, errors}}
        end
    end
  end

  # The same state observed again. Its first capture keeps its time, because that
  # is when the session actually reached this state; only the latest observation
  # and the count move. A capture whose clock runs backwards never rewinds them.
  defp observe_again(session_id, fingerprint, captured_at) do
    {count, rows} =
      Repo.update_all(
        from(evidence in __MODULE__,
          where:
            evidence.session_id == ^session_id and evidence.content_fingerprint == ^fingerprint,
          update: [
            set: [
              last_captured_at:
                fragment("GREATEST(?, ?)", ^captured_at, field(evidence, :last_captured_at))
            ],
            inc: [capture_count: 1]
          ],
          select: evidence
        ),
        []
      )

    case {count, rows} do
      {1, [stored]} -> {:ok, %{evidence: stored, recorded: :unchanged}}
      _missing -> {:error, {:coop_session_evidence_store, :conflict}}
    end
  end

  defp captured_at(evidence) do
    {:ok, captured_at, 0} = DateTime.from_iso8601(evidence["captured_at"])
    captured_at
  end

  defp worker_id(options) do
    case Keyword.get(options, :worker_id) do
      value when is_binary(value) and byte_size(value) in 1..256 -> {:ok, value}
      _invalid -> {:error, {:invalid_coop_session_evidence, :worker_id}}
    end
  end

  defp placement_generation(options) do
    case Keyword.get(options, :placement_generation) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_coop_session_evidence, :placement_generation}}
    end
  end
end
