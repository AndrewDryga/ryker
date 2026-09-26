defmodule Ryker.Publication.Followups.Signals do
  @moduledoc """
  What outside sources record against a published pull request: deployment
  and Terraform signals after it merged, and authenticated GitHub review
  feedback while it is open.

  A signal must come from a webhook authorized for publication lifecycle and
  carry an exact recorded PR URL, branch, head SHA or merge SHA before it can
  wake the source task. Feedback must name the exact open pull request of one
  publication; other GitHub conversation stays with ordinary admission. The
  same delivery recorded twice is one event.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.Input
  alias Ryker.Publication.{DeploymentSignal, Followup, LifecycleEvent, Publication}
  alias Ryker.Publication.Followups.Store
  alias Ryker.Repo
  alias Ryker.State.Observations

  def observe_input(
        %Input{
          actor: %{kind: :system},
          source: %{kind: "webhook"},
          source_capabilities: %{"publication_lifecycle" => authority}
        } = input
      ) do
    with {:ok, signal} <- DeploymentSignal.prepare(input.content),
         :ok <- DeploymentSignal.authorize(signal, authority) do
      Store.transaction(fn -> observe_input_locked(input, signal) end)
    else
      _untrusted_or_untyped -> {:ok, 0}
    end
  end

  def observe_input(%Input{}), do: {:ok, 0}
  def observe_input(_input), do: {:error, {:invalid_publication_lifecycle_input, :input}}

  def observe_github_feedback(%Input{} = input) do
    case github_feedback_identity(input) do
      {:ok, repository, pull_request_number} ->
        Store.transaction(fn ->
          observe_github_feedback_locked(input, repository, pull_request_number)
        end)

      :unmatched ->
        {:ok, :unmatched}

      {:error, _reason} = error ->
        error
    end
  end

  def observe_github_feedback(_input),
    do: {:error, {:invalid_publication_review_feedback, :input}}

  # --- deployment and Terraform signals -------------------------------------

  defp observe_input_locked(input, signal) do
    now = Repo.now!()
    references = signal["payload"]["references"]
    repository = signal["payload"]["repository"]
    branch_references = Enum.map(references, &("refs/heads/" <> &1))

    active = matching_lifecycle_followups(repository, references, branch_references, now)

    Enum.reduce(active, 0, fn publication_pair, count ->
      observe_publication_input(publication_pair, input, signal, references, count)
    end)
  end

  defp matching_lifecycle_followups(repository, references, branch_references, now) do
    reference_match = lifecycle_reference_match(references, branch_references)

    Repo.all(
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where:
          publication.status == :published and publication.repository == ^repository and
            followup.pr_state == "merged" and followup.deadline_at > ^now and
            not is_nil(followup.merge_sha),
        where: ^reference_match,
        order_by: [asc: publication.id],
        select: {followup, publication}
      )
    )
  end

  defp lifecycle_reference_match(references, branch_references) do
    dynamic(
      [followup, publication],
      publication.pull_request_url in ^references or
        publication.branch_ref in ^references or
        publication.branch_ref in ^branch_references or
        publication.commit_sha in ^references or followup.merge_sha in ^references
    )
  end

  defp observe_publication_input(
         {followup, publication},
         input,
         signal,
         references,
         count
       ) do
    if exact_reference?(references, publication, followup) do
      event = Store.lifecycle_event(publication, source_event(input, publication, signal))

      case Store.insert_lifecycle_event(event) do
        {:ok, _event} -> count + 1
        {:duplicate, _event} -> count
      end
    else
      count
    end
  end

  defp exact_reference?(supplied, publication, followup) do
    references =
      [
        publication.pull_request_url,
        publication.branch_ref,
        String.replace_prefix(publication.branch_ref || "", "refs/heads/", ""),
        publication.commit_sha,
        followup.merge_sha
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    Enum.any?(supplied, &(&1 in references))
  end

  defp source_event(input, publication, signal) do
    %{"kind" => kind, "state" => state} = signal["payload"]

    key =
      Store.lifecycle_key([
        publication.id,
        input.source.kind,
        input.source.ref,
        input.event_ref,
        Integer.to_string(input.revision),
        kind,
        state
      ])

    %{
      key: key,
      kind: kind,
      observation: signal,
      occurred_at: input.occurred_at,
      source: %{
        conversation_ref: input.destination.conversation_ref,
        item_ref: input.source_item_ref || input.event_ref,
        transport: input.destination.transport
      },
      state: state,
      summary: source_summary(publication, kind, state),
      wakeup?: state in ~w(succeeded failed)
    }
  end

  defp source_summary(publication, kind, state) do
    label = if kind == "terraform", do: "Terraform", else: "Deployment"

    "#{label} #{state} for draft PR ##{publication.pull_request_number}; the source carried an exact publication reference."
  end

  # --- GitHub review feedback -----------------------------------------------

  defp github_feedback_identity(%Input{
         source: %{kind: "github"},
         content: %{
           "event_name" => "issue_comment",
           "payload" => %{
             "issue" => %{"number" => number, "pull_request" => %{}},
             "repository" => %{"full_name" => repository}
           }
         }
       })
       when is_binary(repository) and is_integer(number) and number > 0,
       do: {:ok, repository, number}

  defp github_feedback_identity(%Input{
         source: %{kind: "github"},
         content: %{
           "event_name" => event_name,
           "payload" => %{
             "pull_request" => %{"number" => number},
             "repository" => %{"full_name" => repository}
           }
         }
       })
       when event_name in ~w(pull_request_review pull_request_review_comment) and
              is_binary(repository) and is_integer(number) and number > 0,
       do: {:ok, repository, number}

  defp github_feedback_identity(%Input{source: %{kind: "github"}}), do: :unmatched

  defp github_feedback_identity(_input),
    do: {:error, {:invalid_publication_review_feedback, :source}}

  defp observe_github_feedback_locked(input, repository, pull_request_number) do
    matches = github_feedback_publications(repository, pull_request_number)

    case matches do
      [] ->
        :unmatched

      [%Publication{} = publication] ->
        {status, stored} = record_github_feedback(input, publication)

        case Observations.record_publication_feedback_in_transaction(stored, publication) do
          :ok -> %{event: stored, status: if(status == :ok, do: :recorded, else: :duplicate)}
          {:error, reason} -> Repo.rollback(reason)
        end

      [_first, _second] ->
        Repo.rollback(:publication_review_feedback_ambiguous)
    end
  end

  defp github_feedback_publications(repository, pull_request_number) do
    Repo.all(
      from(publication in Publication,
        join: followup in Followup,
        on:
          followup.publication_id == publication.id and
            followup.episode_id == publication.episode_id,
        where:
          publication.status == :published and
            publication.github_repository == ^repository and
            publication.pull_request_number == ^pull_request_number and
            followup.pr_state == "open",
        order_by: [asc: publication.id],
        limit: 2,
        select: publication,
        lock: "FOR UPDATE"
      )
    )
  end

  defp record_github_feedback(input, publication) do
    # The publication lock serializes equivalent deliveries. Preserve the first
    # receipt: another serialization must not create a competing wakeup for the
    # same native revision, nor replace the source receipt used by warm Work.
    # READ COMMITTED is required so the lookup after a lock wait sees the
    # preceding transaction's committed receipt.
    document = input |> Input.document() |> feedback_document()

    existing =
      Repo.all(
        from(event in LifecycleEvent,
          where:
            event.publication_id == ^publication.id and event.kind == "review_feedback" and
              event.occurred_at == ^input.occurred_at,
          order_by: [asc: event.inserted_at, asc: event.id]
        )
      )
      |> Enum.find(&(not is_nil(document) and feedback_document(&1.observation) == document))

    case existing do
      nil ->
        publication
        |> Store.lifecycle_event(github_feedback_event(input, publication))
        |> Store.insert_lifecycle_event()

      event ->
        {:duplicate, event}
    end
  end

  defp feedback_document(%{"content" => %{}, "event_ref" => ref} = document) do
    if Store.reference(ref, :event_ref) == :ok do
      document
      |> Map.delete("event_ref")
      |> update_in(["content"], &Map.delete(&1, "delivery_ref"))
      |> CanonicalJSON.encode!()
    end
  end

  defp feedback_document(_document), do: nil

  defp github_feedback_event(input, publication) do
    key =
      Store.lifecycle_key([
        publication.id,
        input.source.kind,
        input.source.ref,
        input.event_ref,
        Integer.to_string(input.revision),
        "review_feedback"
      ])

    %{
      key: key,
      kind: "review_feedback",
      observation: Input.document(input),
      occurred_at: input.occurred_at,
      source: %{
        conversation_ref: input.destination.conversation_ref,
        item_ref: input.source_item_ref || input.event_ref,
        transport: input.destination.transport
      },
      state: "pending",
      summary:
        "Authenticated GitHub review feedback arrived for PR ##{publication.pull_request_number}; continuing the exact engineering task.",
      wakeup?: true
    }
  end
end
