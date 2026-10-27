defmodule Ryker.Work.CompletionReview.Continuation do
  @moduledoc "Bounded continuation when a reviewed correction exhausts the provider turn."
  alias Ryker.{Episodes, Records, Repo}
  alias Ryker.Work.CompletionReview.{Prompt, Run}
  alias Ryker.Work.Custody
  alias Ryker.Work.Custody.Locks
  alias Ryker.Work.{FinalPreflight, Turn, ValidationIntent}

  @maximum_continuations 2

  # On 2026-10-27 two ordinary corrections used the provider's repair budget
  # before review requested independent work. Its last correction never reached
  # the model. Transfer custody only for that exact recorded review, not for any
  # output-contract failure, and carry the lifetime rerun count across transfers.
  def continue_failed(claim) do
    Repo.transaction(fn ->
      case Episodes.fetch_and_lock_current_in_transaction(claim.episode.key) do
        {:ok, _episode} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      {_session, turn} = Locks.leased!(claim.episode.id, claim.turn.turn_ref, claim.lease_ref)
      continue_locked(claim, turn)
    end)
  end

  defp continue_locked(claim, turn) do
    runs = Custody.reruns(turn.turn_ref)

    if turn.status == :pending and runs < @maximum_continuations and rejected_feedback(turn) do
      case Custody.request_rerun(
             claim.episode.id,
             claim.episode.key,
             turn.turn_ref,
             turn.id,
             claim.lease_ref,
             runs + 1,
             :completion_review
           ) do
        {:ok, _request} -> :continued
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :not_applicable
    end
  end

  @doc "The immediate predecessor's rejected review, only within the same native transcript."
  def context(claim) do
    Repo.transaction(fn -> context_in_transaction(claim) end)
  end

  defp context_in_transaction(claim) do
    predecessor =
      claim.episode.id
      |> Turn.Query.by_episode_id()
      |> Turn.Query.by_session_id(claim.session.id)
      |> Turn.Query.transferred_to(claim.turn.turn_ref)
      |> Turn.Query.ordered_by_recent()
      |> Turn.Query.limit_to(1)
      |> Repo.peek()

    case rejected_feedback(predecessor) do
      nil ->
        nil

      feedback ->
        documents =
          Records.DerivedContext.submission_documents(%{
            "completion_review_feedback" => feedback
          })

        case Records.DerivedContext.resolve(
               documents,
               claim.episode,
               claim.session.repository_ref,
               claim.session
             ) do
          {:ok, _custody} -> feedback
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp rejected_feedback(
         %Turn{
           candidate: candidate,
           validation_intent: %{"verdict" => "reject"} = intent
         } = turn
       )
       when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{} = document} ->
        digest = FinalPreflight.candidate_sha256(document)

        turn.id
        |> Run.Query.by_turn_id()
        |> Run.Query.ordered_by_generation()
        |> Repo.all()
        |> Enum.reverse()
        |> Enum.find_value(&matching_feedback(&1, digest, intent))

      _invalid ->
        nil
    end
  end

  defp rejected_feedback(_turn), do: nil

  defp matching_feedback(
         %Run{status: :applied, candidate_sha256: digest, remote_stopped_at: stopped} = run,
         digest,
         intent
       )
       when not is_nil(stopped) do
    with {:ok, judgment} <- Prompt.parse(run.result),
         true <- judgment["decision"] in ~w(continue request_input wait_for_event),
         feedback = Prompt.feedback(judgment),
         {:ok, ^intent} <- ValidationIntent.new({:reject, [feedback]}, nil) do
      %{"review_ref" => run.id, "judgment" => judgment}
    else
      _different -> nil
    end
  end

  defp matching_feedback(_run, _digest, _intent), do: nil
end
