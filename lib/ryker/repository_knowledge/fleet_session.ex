defmodule Ryker.RepositoryKnowledge.FleetSession do
  @moduledoc """
  The worker session one knowledge run executes in: the repository, checked
  out read-only at exactly the commit the run reads, and nothing else, owned
  by exactly that run (execution kind `knowledge`). Cleanup closes it once the
  run has stopped (`Ryker.Retention.Custody`).
  """
  alias Ryker.Adapter
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.Run
  alias Ryker.Work

  @doc "The task reference Coop knows the run's session by."
  @spec external_ref(Run.t()) :: String.t()
  def external_ref(%Run{id: id}), do: "ryker-knowledge:#{id}"

  @doc "The source the run's session starts from: the exact commit it reads."
  @spec source(Run.t()) :: map()
  def source(%Run{source_commit: commit}), do: %{"kind" => "commit", "sha" => commit}

  @doc """
  Whether a worker would take a new knowledge session of this policy over
  this repository now, asked without taking a slot. A transport that cannot
  say is not asked.
  """
  @spec placeable?(map(), String.t(), map()) :: boolean()
  def placeable?(%{api: api, client: client}, repository_ref, policy) do
    session = %Work.Session{
      execution_kind: :knowledge,
      policy: policy.name,
      policy_digest: policy.digest,
      repository_ref: repository_ref
    }

    if Adapter.implements?(api, accepts_session?: 2),
      do: api.accepts_session?(client, session),
      else: true
  end

  @doc """
  The run's session, created once with the run's exact policy, repository and
  commit, and announced when it is: every step asks for it, and each one
  announced it, so every page listing sessions redrew while a run was out.
  """
  @spec ensure(Run.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def ensure(%Run{} = run) do
    Repo.transaction(fn ->
      session = run |> run_session() |> Repo.peek() || create!(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest and
               session.repository_ref == run.repository_ref and
               session.repository_source == source(run),
             do: Repo.rollback(:repository_knowledge_session_authority_conflict)

      session
    end)
  end

  defp create!(run) do
    Repo.insert!(
      %Work.Session{
        execution_kind: :knowledge,
        knowledge_run_id: run.id,
        policy: run.policy,
        policy_digest: run.policy_digest,
        repository_ref: run.repository_ref,
        repository_source: source(run),
        external_ref: external_ref(run)
      },
      on_conflict: :nothing
    )

    run |> run_session() |> Repo.one!() |> tap(&Work.Custody.broadcast_session_updated/1)
  end

  @doc "Binds the run's session to the Coop session created for it, once."
  @spec bind(Run.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def bind(%Run{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = run |> run_session() |> Repo.one!()

      case session.coop_session_id do
        nil ->
          session
          |> Ecto.Changeset.change(coop_session_id: remote_id)
          |> Repo.update!()
          |> tap(&Work.Custody.broadcast_session_updated/1)

        ^remote_id ->
          session

        _other ->
          Repo.rollback(:repository_knowledge_session_identity_conflict)
      end
    end)
  end

  def bind(_run, _remote_id), do: {:error, :repository_knowledge_session_identity_conflict}

  @doc "The run's session, which `ensure/1` makes."
  @spec fetch_for_run(Run.t()) :: {:ok, Work.Session.t()} | {:error, :not_found}
  def fetch_for_run(%Run{id: id}), do: Repo.fetch(Work.Session.Query.by_knowledge_run_id(id))

  @doc "The Coop session the run's session is bound to, or nil before it is."
  @spec coop_session_id(Run.t()) :: String.t() | nil
  def coop_session_id(%Run{id: id}) do
    id
    |> Work.Session.Query.by_knowledge_run_id()
    |> Work.Session.Query.select_coop_session_ids()
    |> Repo.one()
  end

  defp run_session(run),
    do: run.id |> Work.Session.Query.by_knowledge_run_id() |> Work.Session.Query.lock_for_update()
end
