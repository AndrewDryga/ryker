defmodule Ryker.Publication.FixLoop do
  @moduledoc """
  What Ryker does, without a person, about a task's change its trusted review
  refused.

  Andrew, 2026-09-28, after a refused change's card asked him to reply to have
  it fixed: "why I should ask it myself, it should be automatic feedback loop,
  agent needs to get errors from CI, fix them without me doing a man in the
  middle."

  `Ryker.Publication.Review.remedy/1` sorts every refusal. One the task's own
  work can fix — the repository's checks failed, the change conflicts with the
  latest base branch, or running the checks changed its files — goes back to
  that work. The review is delivered as a short notice instead of a card that
  asks for a reply, and in the same transaction the refusal is admitted into
  the task's episode as a host-written input, which runs as a new turn in the
  same worker session. When that turn commits and finishes, the ordinary
  readiness path (`Custody.ensure_task_review_in_transaction/3`) reviews the new
  change. A refusal that is only the moment it was checked — the base branch
  or the working copy moved, or the working copy was still in use — is asked
  again unchanged, with nothing posted. Anything else waits for a person, a
  policy finding such as a possible credential above all.

  Both loops are bounded per publication, three fix rounds and three re-checks,
  and then the refusal is delivered as it always was. A round starts only for a
  confirmed task's publication whose work is at rest: a refusal that lands
  while a person's own follow-up runs leaves it alone, because that turn's
  commit is reviewed afresh when it finishes.
  """

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, ConversationLock, Episode}
  alias Ryker.Ingress.Input
  alias Ryker.Publication.{Publication, Review}
  alias Ryker.Repo
  alias Ryker.Work.Session

  @rounds 3
  # A working copy still in use is usually free again within a minute.
  @recheck_seconds 30
  # What a fix round shows the agent of a failed gate's output: its end, where
  # a test run prints what failed.
  @output_tail_bytes 16_384
  @source "publication-review"

  @spec rounds() :: pos_integer()
  def rounds, do: @rounds

  @doc "Whether a stored review is asked again unchanged instead of delivered."
  @spec recheck?(Publication.t(), map()) :: boolean()
  def recheck?(%Publication{recheck_rounds: rounds}, review),
    do: rounds < @rounds and Review.remedy(review) == :recheck

  @doc "A fresh review generation for the same change, a little later."
  @spec recheck_attributes(Publication.t(), DateTime.t()) :: map()
  def recheck_attributes(%Publication{} = publication, now) do
    %{
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: DateTime.add(now, @recheck_seconds, :second),
      recheck_rounds: publication.recheck_rounds + 1,
      review_expected_revision: nil,
      review_generation: publication.review_generation + 1
    }
  end

  @doc """
  Whether delivering this refused review starts a fix round. The caller still
  owns the task's grant; this answers everything else.
  """
  @spec round_due?(Publication.t()) :: boolean()
  def round_due?(%Publication{status: :review_ready, fix_rounds: rounds} = publication)
      when rounds < @rounds do
    Review.remedy(publication.review_document) == :fix and task_session?(publication) and
      at_rest?(publication)
  end

  def round_due?(_publication), do: false

  @doc "The round's own fields, set with the delivery that starts it."
  @spec round_attributes(Publication.t()) :: map()
  def round_attributes(%Publication{} = publication),
    do: %{
      fix_review_generation: publication.review_generation,
      fix_rounds: publication.fix_rounds + 1
    }

  @doc "What the thread hears instead of the refusal card when a round starts."
  @spec notice(Publication.t()) :: String.t()
  def notice(%Publication{} = publication) do
    causes = publication.review_document |> Review.refusal() |> sentence_list()

    "#{capitalize(causes)}. I'm fixing it now, attempt #{publication.fix_rounds + 1} of #{@rounds}, and I'll check the new change when I'm done."
  end

  @doc "What the refusal says once every round is spent, or nil."
  @spec exhausted(Publication.t()) :: String.t() | nil
  def exhausted(%Publication{fix_rounds: rounds} = publication) when rounds >= @rounds do
    with :fix <- Review.remedy(publication.review_document),
         false <- running?(publication),
         [cause | _rest] <- Review.fixable(publication.review_document) do
      "I tried to fix it #{@rounds} times; #{still(cause)}."
    else
      _other -> nil
    end
  end

  def exhausted(_publication), do: nil

  @doc """
  Where the loop stands for a task card: `{:fixing, line}` while a round runs,
  `{:stopped, line}` once every round is spent, nil otherwise.
  """
  @spec progress(Publication.t() | nil, Episode.t()) ::
          {:fixing, String.t()} | {:stopped, String.t()} | nil
  def progress(%Publication{status: :blocked} = publication, %Episode{state: state}) do
    cond do
      running?(publication) and state not in [:complete, :cancelled] ->
        [cause | _rest] = Review.fixable(publication.review_document)

        {:fixing, "Fixing: #{cause(cause)} · attempt #{publication.fix_rounds} of #{@rounds}"}

      line = exhausted(publication) ->
        {:stopped, line}

      true ->
        nil
    end
  end

  def progress(_publication, _episode), do: nil

  @doc """
  Takes the task's conversation and episode locks before its publication's.

  Work accepts a result under the episode lock and then re-arms the
  publication, and admission locks the conversation before the episode. A
  delivery that may start a round locks in that same order before it locks the
  publication, so the two can never wait on each other.
  """
  @spec lock_task_in_transaction(String.t()) :: :ok | {:error, term()}
  def lock_task_in_transaction(publication_ref) do
    with %Publication{status: :review_ready, episode_id: episode_id} <-
           Repo.get_by(Publication, ref: publication_ref),
         %Episode{} = episode <- Repo.get(Episode, episode_id),
         :ok <- ConversationLock.lock_many(Repo, [destination(episode)]),
         {:ok, _episode} <- Episodes.lock_current_in_transaction(episode.key) do
      :ok
    else
      {:error, _reason} = error -> error
      _nothing_to_start -> :ok
    end
  end

  @doc """
  Admits the refusal into the task's episode as a host-written input, which
  runs as the task's next turn in the same worker session. Call it after the
  round's fields are stored, inside the delivery's transaction.
  """
  @spec admit_in_transaction(Publication.t(), DateTime.t()) :: :ok | {:error, term()}
  def admit_in_transaction(%Publication{} = publication, now) do
    episode = Repo.get!(Episode, publication.episode_id)
    identity = "#{@source}:#{publication.id}:g#{publication.review_generation}"

    with {:ok, input} <-
           Input.new(%{
             actor: %{kind: :system, ref: @source},
             content: content(publication),
             destination: destination(episode),
             event_kind: :event,
             event_ref: identity,
             native_input_id: identity,
             occurred_at: now,
             occurred_at_source: :source,
             revision: 1,
             source: %{kind: "system", ref: @source},
             source_capabilities: %{},
             source_item_ref: nil
           }),
         {:ok, [_transition]} <-
           Episodes.apply_batch_in_transaction([
             %Command.AdmitInput{
               actor_ref: Input.actor_ref(input),
               destination: input.destination,
               episode_id: episode.id,
               episode_key: episode.key,
               execution_mode: episode.execution_mode,
               linked_episode_id: episode.linked_episode_id,
               native_input_id: input.native_input_id,
               occurred_at: input.occurred_at,
               payload: Input.document(input),
               revision: input.revision,
               turn_ref:
                 "turn:publication-fix:#{publication.id}:g#{publication.review_generation}"
             }
           ]) do
      :ok
    end
  end

  # The message the task's work receives: the review's causes in the host's own
  # words, what to do about each, and the failed gate's own report when Coop
  # sent one. The model reads this as input, never as authority.
  defp content(publication) do
    review = publication.review_document
    report = gate_report(review["gate_failure"])

    details =
      %{
        "attempt" => publication.fix_rounds,
        "attempts" => @rounds,
        "base_commit" => review["parent_head"],
        "causes" => Review.refusal(review),
        "committed_change" => review["candidate_head"]
      }

    %{
      "correction_request" => request(review, report, publication.fix_rounds),
      "kind" => "publication_review_refusal",
      "review" => if(report, do: Map.put(details, "gate_failure", report), else: details)
    }
  end

  defp request(review, report, attempt) do
    [
      "Ryker's trusted review refused the committed change: #{sentence_list(Review.refusal(review))}."
      | Enum.map(Review.fixable(review), &instruction(&1, review, report))
    ]
    |> Kernel.++([
      "Then finish. This is automatic fix attempt #{attempt} of #{@rounds}. Stay inside the task's scope and do not push, open a pull request, merge or deploy: Ryker reviews your new commit when you finish. If you cannot fix it, say exactly what blocks it."
    ])
    |> Enum.join(" ")
  end

  defp instruction("gate_failed", _review, nil),
    do: "Run the repository's gate yourself to see what fails, fix it and commit."

  defp instruction("gate_failed", _review, _report),
    do:
      "The failing command, its exit code and the end of its output are in review.gate_failure. Run the repository's gate, fix what fails and commit."

  defp instruction("rebase_conflict", review, _report),
    do:
      "Bring the change up to date with the latest base branch (commit #{review["parent_head"]}), resolve the conflicts, run the repository's gate and commit."

  defp instruction("gate_modified_candidate", _review, _report),
    do: "Run the repository's gate and commit the files it changes, with anything else they need."

  defp gate_report(%{"output_tail" => output} = report) do
    kept = Review.output_tail(output, @output_tail_bytes)

    %{
      report
      | "output_tail" => kept,
        "output_truncated" => report["output_truncated"] or kept != output
    }
  end

  defp gate_report(_report), do: nil

  defp cause("rebase_conflict"), do: "the change conflicts with the latest base branch"
  defp cause("gate_failed"), do: "the repository's checks failed"
  defp cause("gate_modified_candidate"), do: "running the checks changed the committed files"

  defp still("rebase_conflict"), do: "the change still conflicts with the latest base branch"
  defp still("gate_failed"), do: "the repository's checks still fail"

  defp still("gate_modified_candidate"),
    do: "running the checks still changes the committed files"

  # A round runs while the review it answers is still the publication's own; a
  # new review, a re-arm or a person's recovery ends it without anyone clearing it.
  defp running?(%Publication{fix_review_generation: generation, review_generation: generation}),
    do: true

  defp running?(_publication), do: false

  # Only a confirmed task's session re-arms its publication when a turn finishes
  # (`Custody.ensure_task_review_in_transaction/3`); without that the fix would
  # never be reviewed.
  defp task_session?(publication),
    do: match?(%Session{workspace_task: %{}}, Repo.get(Session, publication.session_id))

  defp at_rest?(publication),
    do: match?(%Episode{state: :complete}, Repo.get(Episode, publication.episode_id))

  defp destination(episode),
    do: %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp sentence_list([only]), do: only

  defp sentence_list(items) do
    {leading, [last]} = Enum.split(items, -1)
    Enum.join(leading, ", ") <> " and " <> last
  end
end
