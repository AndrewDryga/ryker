defmodule Ryker.RepositoryKnowledge.Executor do
  @moduledoc """
  Repository reading's lane through `Ryker.Coop.RunStep`: a knowledge run's
  session reads the repository at the run's commit, and an offered answer is
  checked against the contract and then against the repository itself: the
  tree at the run's commit and the files its commands cite
  (`Ryker.RepositoryKnowledge.Document.verify/3`). Only an answer that leaves
  something real is accepted; any other ends the run, and the next start is
  told why.
  """
  @behaviour Ryker.Coop.RunStep
  alias Ryker.Accounting
  alias Ryker.Coop
  alias Ryker.RepositoryKnowledge.{Custody, Document, FleetSession, Prompt}

  @doc """
  Moves the run on by one step: `{:ok, {:applied, entry}}` once its checked
  document is the repository's knowledge, `{:ok, :waiting}` while Coop is still
  working, `{:ok, :stopped}` once the run ended without one and has stop
  proof, or an error for a step to try again. `target` is the repository and
  its GitHub binding, or nil once the repository is gone: a run that can no
  longer be checked only stops.
  """
  @spec step(map(), struct(), {map(), map()} | nil, map()) :: Coop.RunStep.result()
  def step(claim, run, target, settings),
    do: Coop.RunStep.step(__MODULE__, claim, Custody.current(run.id), target, settings)

  @impl true
  def store, do: Custody

  @impl true
  def fleet_session, do: FleetSession

  @impl true
  def source(run), do: FleetSession.source(run)

  @impl true
  def error(:execution_timeout), do: :repository_knowledge_execution_timeout
  def error(:lease_renewal_failed), do: :repository_knowledge_lease_renewal_failed
  def error(:provider_failed), do: :repository_knowledge_provider_failed
  def error(:remote_identity_conflict), do: :repository_knowledge_remote_identity_conflict
  def error(:remote_protocol_error), do: :repository_knowledge_remote_protocol_error
  def error(:remote_unresolved), do: :repository_knowledge_remote_unresolved
  def error(:session_authority_conflict), do: :repository_knowledge_session_authority_conflict
  def error(:session_identity_conflict), do: :repository_knowledge_session_identity_conflict
  def error(:session_not_isolated), do: :repository_knowledge_session_not_isolated
  def error(:session_unaddressable), do: :repository_knowledge_session_unaddressable

  @impl true
  def validate_key(run, sha256),
    do: "ryker:knowledge:validate:#{run.id}:a#{run.candidate_attempt}:#{sha256}"

  @impl true
  def contract_version, do: Prompt.contract_version()

  @impl true
  def observe_in_transaction(entry, run, session_id, turn, session, now),
    do: Accounting.observe_knowledge_in_transaction(entry, run, session_id, turn, session, now)

  # An answer the run cannot keep (larger than it holds, or not what its
  # digest names) is refused the same way every time it is asked for: the
  # attempt ends and its turn is cancelled, so the next start comes.
  @impl true
  def refused_candidate?(reason),
    do: reason in [:invalid_repository_knowledge, :invalid_repository_knowledge_candidate]

  @impl true
  def check(claim, run, target, settings) do
    case checked_document(claim, run, target, settings) do
      {:ok, _document} -> :ok
      {:error, reason} when is_atom(reason) -> {:stop, reason}
      {:retry, reason} -> {:error, reason}
    end
  end

  # The answer, checked against the contract and then against the repository
  # at the run's commit, as the document the host writes from it. A document
  # written before (the step is repeated after a crash) is not checked again.
  # GitHub not answering is not the model's fault: the step waits.
  defp checked_document(_claim, %{document: document}, _target, _settings)
       when is_binary(document),
       do: {:ok, document}

  defp checked_document(_claim, _run, nil, _settings), do: {:error, :repository_knowledge_removed}

  defp checked_document(claim, run, {repository, binding}, settings) do
    with {:ok, answer} <- Prompt.parse(run.result),
         {:ok, tree, sources} <-
           Coop.RunStep.with_lease_kept(__MODULE__, claim, settings, fn ->
             read_cited(settings, binding, repository, run.source_commit, answer)
           end),
         {:ok, _kept, dropped, document} <-
           Document.keep(answer, tree, sources, run.source_commit, Date.utc_today()) do
      with {:ok, _run} <- Custody.record_document(claim, run.id, document, dropped),
           do: {:ok, document}
    else
      {:error, reason}
      when reason in [:invalid_repository_knowledge, :repository_knowledge_unusable] ->
        {:error, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  # Reading the tree and every cited file can outlast the lease, which is
  # kept meanwhile, as a source preparation's is (2026-10-04 review).
  defp read_cited(settings, binding, repository, commit, answer) do
    with {:ok, tree} <- remote_tree(settings, binding, repository, commit),
         {:ok, sources} <-
           sources(settings, binding, repository, commit, Document.cited_sources(answer, tree)),
         do: {:ok, tree, sources}
  end

  defp remote_tree(settings, binding, repository, commit) do
    with {:ok, entries} <- settings.remote.tree(binding, repository, commit),
         do: {:ok, Document.tree(entries)}
  end

  # A cited file Ryker cannot read (too large, not text) cites nothing: its
  # commands are dropped, not the answer.
  defp sources(settings, binding, repository, commit, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, sources} ->
      case settings.remote.read(binding, repository, path, commit) do
        {:ok, text} when is_binary(text) -> {:cont, {:ok, Map.put(sources, path, text)}}
        {:ok, :not_found} -> {:cont, {:ok, sources}}
        {:error, :source_unavailable} -> {:cont, {:ok, sources}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
