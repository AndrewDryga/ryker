defmodule Ryker.Work.Custody.CurrentAuthority do
  @moduledoc """
  The authority current settings give a session no worker ever took.

  A session keeps the policy and repositories it was admitted with, and
  "Run the task again" reuses it. On 2026-10-03 a tenant task stopped on
  tenantcorp/tenant-core, a read-only repository whose submodule Ryker cannot
  fetch. Once tenant-core was taken out of the environment, the retry pinned
  the same repositories, and Ryker's settings no longer matched them (Andrew:
  a retry of a task that never started should pick up the environment as it
  is now). A session a worker has taken keeps its authority, since the worker
  may hold its job.

  The policy is found by its name, which settings never change; its digests,
  the environment's repositories and its Emisar account are taken as they are
  now. A session whose policy or working repository settings no longer have
  keeps what it had, and its retry says why.
  """

  alias Ryker.CoopFleet.{JobAuthority, JobTemplates}
  alias Ryker.Emisar.Connections, as: EmisarConnections
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Settings.Environment
  alias Ryker.Work.{RepositoryContext, Session, SessionChangeset}

  @doc "The session as current settings would admit it, saved; else the session as it was."
  @spec refresh_locked(Session.t()) :: Session.t()
  def refresh_locked(%Session{} = session) do
    with true <- JobAuthority.unstarted?(session),
         {:ok, snapshot} <- Settings.fetch(),
         {:ok, current} <- current(snapshot, session),
         true <- current != saved(session),
         {:ok, refreshed} <- Repo.update(SessionChangeset.refresh_authority(session, current)) do
      refreshed
    else
      _unchanged -> session
    end
  end

  defp current(snapshot, session) do
    with %{policy_digest: policy_digest, authority_digest: authority_digest} <-
           Enum.find(JobTemplates.from_settings(snapshot), &(&1.policy_name == session.policy)),
         {:ok, context} <- context(snapshot, session) do
      {:ok,
       %{
         policy_digest: policy_digest,
         authority_digest: session.authority_digest && authority_digest,
         repository_context: context,
         emisar: emisar(snapshot, session.environment_ref)
       }}
    else
      _unavailable -> :unavailable
    end
  end

  defp context(_snapshot, %Session{repository_context: nil}), do: {:ok, nil}

  defp context(snapshot, %Session{environment_ref: ref, repository_ref: primary})
       when is_binary(ref) do
    with %Environment{} = environment <- Environment.find(snapshot, :ref, ref),
         true <- primary in Environment.writable_refs(environment) do
      {:ok,
       RepositoryContext.document(%{
         context_ref: environment.ref,
         parallel_goal_limit: environment.parallel_goal_limit,
         primary_repository: primary,
         read_only_repositories: List.delete(Environment.repository_refs(environment), primary)
       })}
    else
      _gone -> :unavailable
    end
  end

  defp context(_snapshot, _session), do: :unavailable

  defp emisar(snapshot, environment_ref) do
    case EmisarConnections.resolve(snapshot, environment_ref) do
      {:ok, pin} -> pin
      {:error, _none} -> nil
    end
  end

  defp saved(session) do
    %{
      policy_digest: session.policy_digest,
      authority_digest: session.authority_digest,
      repository_context: session.repository_context,
      emisar:
        session.emisar_connection_ref &&
          %{
            connection_ref: session.emisar_connection_ref,
            account_ref: session.emisar_account_ref,
            rpc_url: session.emisar_rpc_url
          }
    }
  end
end
