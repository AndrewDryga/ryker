defmodule Ryker.RepositoryKnowledge.FleetSession do
  @moduledoc """
  The worker session one knowledge run executes in: the repository, checked
  out read-only at exactly the commit the run reads, and nothing else, owned
  by exactly that run (execution kind `knowledge`). Cleanup closes it once the
  run has stopped (`Ryker.Retention.Custody`).
  """

  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.Run
  alias Ryker.Work.{Custody, Session}

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
    session = %Session{
      execution_kind: :knowledge,
      policy: policy.name,
      policy_digest: policy.digest,
      repository_ref: repository_ref
    }

    if Code.ensure_loaded?(api) and function_exported?(api, :accepts_session?, 2),
      do: api.accepts_session?(client, session),
      else: true
  end

  @doc "The run's session, created once with the run's exact policy, repository and commit."
  @spec ensure(Run.t()) :: {:ok, Session.t()} | {:error, term()}
  def ensure(%Run{} = run) do
    Repo.transaction(fn ->
      Repo.insert!(
        %Session{
          id: Ecto.UUID.generate(),
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

      session = locked(run)

      unless session.policy == run.policy and session.policy_digest == run.policy_digest and
               session.repository_ref == run.repository_ref and
               session.repository_source == source(run),
             do: Repo.rollback(:repository_knowledge_session_authority_conflict)

      Custody.broadcast_session_updated(session)
      session
    end)
  end

  @doc "Binds the run's session to the Coop session created for it, once."
  @spec bind(Run.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def bind(%Run{} = run, remote_id)
      when is_binary(remote_id) and byte_size(remote_id) in 1..1024 do
    Repo.transaction(fn ->
      session = locked(run)

      case session.coop_session_id do
        nil ->
          session
          |> Ecto.Changeset.change(coop_session_id: remote_id)
          |> Repo.update!()
          |> tap(&Custody.broadcast_session_updated/1)

        ^remote_id ->
          session

        _other ->
          Repo.rollback(:repository_knowledge_session_identity_conflict)
      end
    end)
  end

  def bind(_run, _remote_id), do: {:error, :repository_knowledge_session_identity_conflict}

  @doc "The run's session, or nil before `ensure/1`."
  @spec for_run(Run.t() | Ecto.UUID.t()) :: Session.t() | nil
  def for_run(%Run{id: id}), do: for_run(id)

  def for_run(id) when is_binary(id),
    do: Repo.one(Session.Query.for_knowledge_run(id))

  defp locked(run) do
    run.id
    |> Session.Query.for_knowledge_run()
    |> Session.Query.lock_for_update()
    |> Repo.one!()
  end
end
