defmodule Ryker.CoopFleet.PublicationGrants do
  @moduledoc false

  import Ecto.Query
  alias Ryker.CoopFleet.{Command, ControlPlane, JobAuthority, Placement}
  alias Ryker.GitHub.InstallationTokens
  alias Ryker.Publication.{Custody, Executor, Publication}
  alias Ryker.{Repo, Settings}
  alias Ryker.Work.Session

  @identity ~w(repository_ref github_repository github_repository_id)
  @request ~w(session_id review_operation_id job_ref job_digest repository command_key request)
  @body ~w(authorization_ref candidate_head candidate_tree branch base_branch expected_head pull_request_number title body)

  def publication_grant(certificate, job_ref, request, provider \\ InstallationTokens) do
    with {:ok, authority} <- publication_grant_authority(certificate, job_ref, request),
         {:ok, %{token: token, expires_at: expires_at}} <-
           InstallationTokens.fresh_publication_token(
             provider,
             authority.binding.name,
             Map.take(authority.binding, [:repository_id, :installation_id])
           ),
         {:ok, current} <- publication_grant_authority(certificate, job_ref, request) do
      if current == authority do
        {:ok,
         Map.merge(request["repository"], %{
           "token" => token,
           "expires_at" => DateTime.to_iso8601(expires_at),
           "actor_id" => authority.binding.ryker_actor_id
         })}
      else
        {:error, :publication_grant_unavailable}
      end
    end
  end

  # A placement lease or the settings can be temporarily unavailable; an exact authority denial
  # is distinct so Coop can finish a revoked publication without retrying forever.
  def publication_grant_authority(certificate, job_ref, request) when is_map(request) do
    with true <- is_binary(request["command_key"]),
         {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         %Command{} = command <- Repo.get_by(Command, idempotency_key: request["command_key"]),
         true <- is_binary(command.placement_id),
         %Placement{worker_id: ^worker_id, state: :active} = placement <-
           Repo.get(Placement, command.placement_id),
         :ok <- live_placement(placement),
         %Session{} = session <- Repo.get(Session, placement.session_id),
         {:ok, snapshot} <- settings() do
      authorize(request, job_ref, session, placement, command, snapshot)
    else
      {:error, :publication_grant_unavailable} = error -> error
      _revoked_or_unproven -> {:error, :publication_grant_denied}
    end
  end

  def publication_grant_authority(_certificate, _job_ref, _request),
    do: {:error, :publication_grant_denied}

  defp live_placement(placement) do
    if DateTime.compare(placement.lease_expires_at, Repo.now!()) == :gt,
      do: :ok,
      else: {:error, :publication_grant_unavailable}
  end

  defp settings do
    case Settings.fetch() do
      {:ok, snapshot} -> {:ok, snapshot}
      _unavailable -> {:error, :publication_grant_unavailable}
    end
  end

  defp authorize(request, job_ref, session, placement, command, snapshot) do
    job = session.worker_job_document
    body = request["request"]
    source = job && job["source"]

    with true <- Enum.sort(Map.keys(request)) == Enum.sort(@request),
         true <- is_map(body) and Enum.sort(Map.keys(body)) == Enum.sort(@body),
         true <- is_binary(body["base_branch"]) and is_binary(body["authorization_ref"]),
         {:ok, ^session} <- JobAuthority.validate(session),
         true <- exact_job?(request, job_ref, session),
         true <- "refs/heads/" <> body["base_branch"] == source["binding"]["default_ref"],
         [%Publication{} = publication] <- publications(session.id, body["authorization_ref"]),
         true <- Custody.publication_authorized?(publication),
         true <- exact_review?(publication, session, request),
         true <- exact_commands?(publication, session, placement, command, request),
         %{repository_id: repository_id} = binding <-
           Enum.find(snapshot.github_bindings, &(&1.repository_ref == source["repository_ref"])),
         %{github_access: :available, github_repository: github_repository} <-
           Enum.find(snapshot.repositories, &(&1.ref == source["repository_ref"])),
         true <-
           repository_id == source["github_repository_id"] and
             github_repository == source["github_repository"] do
      # No publication lease is asked for: Ryker holds one only for the second it takes to check
      # on the worker, and a worker retrying the exact command it was sent must be able to finish
      # between those checks (Andrew's PR #2, 2026-10-01, stuck "updating" until anyone looked).
      {:ok,
       %{
         binding: Map.take(binding, [:name, :repository_id, :installation_id, :ryker_actor_id]),
         placement: {placement.id, placement.generation},
         command: {command.id, command.payload_fingerprint},
         approval:
           {publication.approval_ref, publication.approved_by_actor_ref, publication.approved_at},
         review: publication.review_fingerprint
       }}
    else
      _unproven -> {:error, :publication_grant_denied}
    end
  end

  defp exact_job?(request, job_ref, session) do
    job = session.worker_job_document

    is_map(job["source"]) and job["mode"] == "normal" and job["repository_read_only"] == false and
      request["repository"] == Map.take(job["source"], @identity) and
      request["job_ref"] == job_ref and job_ref == session.external_ref and
      request["job_digest"] == session.worker_job_digest and
      request["session_id"] == session.coop_session_id
  end

  defp publications(session_id, approval_ref) do
    Repo.all(
      from(publication in Publication,
        where:
          publication.session_id == ^session_id and publication.approval_ref == ^approval_ref,
        limit: 2
      )
    )
  end

  defp exact_review?(publication, session, request) do
    review = publication.review_document
    body = request["request"]

    is_map(review) and review["candidate_retained"] == true and
      review["job_digest"] == session.worker_job_digest and
      review["session_id"] == session.coop_session_id and
      review["session_revision"] == publication.review_expected_revision and
      review["operation_id"] == request["review_operation_id"] and
      review["candidate_head"] == body["candidate_head"] and
      review["candidate_tree"] == body["candidate_tree"] and
      publication.repository == request["repository"]["repository_ref"]
  end

  defp exact_commands?(publication, session, placement, command, request) do
    path =
      "/v1/sessions/#{session.coop_session_id}/reviews/#{request["review_operation_id"]}/publish"

    command.kind == "api_request" and command.idempotency_key == Executor.publish_key(publication) and
      command.session_id == session.id and command.worker_id == placement.worker_id and
      command.placement_generation == placement.generation and
      command.status in [:delivered, :acknowledged, :succeeded, :uncertain] and
      command.payload == %{"method" => "POST", "path" => path, "body" => request["request"]} and
      exact_review_command?(publication, session, placement)
  end

  # The review lives in the worker's session, not in the placement that ran it: a person may
  # approve the draft after that placement lapsed, and the publish then runs on a newer placement
  # of the same session on the same worker (`Ryker.CoopFleet.Client.publish_review/6`). A review
  # from another worker, or from a placement newer than the publish, grants nothing.
  defp exact_review_command?(publication, session, placement) do
    review = Repo.get_by(Command, idempotency_key: Executor.review_key(publication))

    match?(%Command{kind: "run_review"}, review) and review.session_id == session.id and
      review.worker_id == placement.worker_id and
      review.placement_generation <= placement.generation and
      review.status in [:succeeded, :uncertain] and
      review.payload == %{
        "coop_session_id" => session.coop_session_id,
        "expected_revision" => publication.review_expected_revision
      }
  end
end
