defmodule Ryker.Work.CompletionReview do
  @moduledoc "Evidence-based completion review before a substantive Work answer is accepted."
  alias Ryker.{Knowledge, Records, Repo}
  alias Ryker.Work.CompletionReview.{Custody, Evidence, Executor, Prompt, Run}
  alias Ryker.Work.{Final, FinalPreflight}

  @doc "Whether this live result needs a completion decision, including silent task results."
  def required?(%{episode: %{execution_mode: :shadow}}, _delivery), do: false

  def required?(claim, delivery) when delivery in [:reply, :none] do
    context = (claim.turn.submission || %{})["context"] || %{}

    (context["completion_review_required"] == true and delivery != :none) or
      is_map(claim.session.workspace_task) or Records.goals(claim.episode.id) != []
  end

  @doc "An accepted judgment, a concrete correction, or a durable pending/error state."
  def review(claim, final, settings) do
    result =
      if required?(claim, final.delivery), do: review_required(claim, final, settings), else: :ok

    case result do
      {:error, :completion_review_evidence_changed} -> pending()
      {:error, :coop_worker_capacity_unavailable} -> pending()
      other -> other
    end
  end

  defp review_required(claim, final, settings) do
    with :ok <-
           Knowledge.KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ),
         {:ok, snapshot} <- Custody.with_lease(claim, fn -> Evidence.snapshot(claim, final) end),
         {:ok, run} <- Custody.prepare(claim, snapshot) do
      review_snapshot(claim, run, snapshot, final, settings)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_snapshot(claim, run, snapshot, final, settings) do
    if run.candidate_sha256 != FinalPreflight.candidate_sha256(snapshot["candidate"]) or
         run.ledger_sha256 != snapshot["ledger_sha256"] do
      with {:ok, ended} <- Custody.end_attempt(claim, run.id, :completion_review_stale),
           do: settle_obsolete(claim, ended, settings)
    else
      progress(claim, run, final, settings)
    end
  end

  defp progress(claim, %Run{status: :applied} = run, final, _settings) do
    with {:ok, judgment} <- Prompt.parse(run.result),
         {:ok, _run} <- Custody.apply_feedback(claim, run.id, final),
         do: verdict(claim, judgment, final)
  end

  defp progress(claim, run, final, settings) do
    case Executor.step(claim, run, settings) do
      {:ok, {:applied, applied}} -> progress(claim, applied, final, settings)
      {:ok, state} when state in [:waiting, :stopped] -> pending()
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_obsolete(claim, run, settings) do
    case Executor.step(claim, run, settings) do
      {:ok, _state} -> pending()
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending, do: {:error, {:work_poll_window_elapsed, :completion_review}}

  defp verdict(_claim, %{"decision" => "complete"}, %Final{state: :complete}), do: :ok

  defp verdict(_claim, %{"decision" => "wait_for_event"}, %Final{state: :waiting_for_event}),
    do: :ok

  defp verdict(claim, %{"decision" => "request_input"} = judgment, final) do
    cond do
      not Ryker.Episodes.Origins.person_participated?(claim.episode.id) ->
        {:error, :completion_review_no_addressee}

      final.state == :waiting_for_input ->
        :ok

      true ->
        {:reject, [Prompt.feedback(judgment)]}
    end
  end

  defp verdict(_claim, judgment, _final), do: {:reject, [Prompt.feedback(judgment)]}

  @doc "Stop a pending reviewer before the parent is cancelled, transferred, or blocked."
  def cancel(claim, settings) do
    case Custody.outstanding(claim.turn.id) do
      nil ->
        :ok

      run ->
        with {:ok, run} <- Custody.end_attempt(claim, run.id, :completion_review_parent_stopped),
             do: settle_cancelled(claim, run, settings)
    end
  end

  defp settle_cancelled(claim, run, settings) do
    case Executor.step(claim, run, settings) do
      {:ok, :stopped} ->
        :ok

      {:ok, _pending} ->
        pending()

      {:error, reason} ->
        case Custody.stop_removed_worker(claim, run.id) do
          {:ok, _stopped} -> :ok
          {:error, :completion_review_worker_not_removed} -> {:error, reason}
          {:error, failure} -> {:error, failure}
        end
    end
  end

  @doc "Under the parent lock, an acceptance must still match its reviewed candidate and evidence."
  def authorize_in_transaction(claim, %Final{} = final) do
    if required?(claim, final.delivery), do: reviewed_verdict(claim, final), else: :ok
  end

  defp reviewed_verdict(claim, final) do
    candidate_sha = FinalPreflight.candidate_sha256(Final.document(final))
    ledger_sha = Evidence.fingerprint(claim)
    runs = Repo.all(Run.Query.by_turn_id(claim.turn.id))

    run =
      Enum.find(
        runs,
        &(&1.status == :applied and &1.candidate_sha256 == candidate_sha and
            &1.ledger_sha256 == ledger_sha)
      )

    case run do
      nil ->
        {:error, :completion_review_required}

      %Run{} ->
        with {:ok, judgment} <- Prompt.parse(run.result), do: verdict(claim, judgment, final)
    end
  end
end
