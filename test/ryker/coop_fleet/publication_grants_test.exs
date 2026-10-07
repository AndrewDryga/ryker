defmodule Ryker.CoopFleet.PublicationGrantsTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Changeset, only: [change: 2]
  import Plug.Conn
  import Plug.Test
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.{ControlPlane, PublicationGrants, Router}
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.GitHub.InstallationTokens
  alias Ryker.Publication.{Custody, Executor, Request}
  alias Ryker.{Repo, Settings}

  @fixture Path.expand("../../../testdata/protocol/coop-worker-v2.json", __DIR__)

  defmodule Requester do
    def request(owner, method, path, body, _headers) do
      send(owner, {:mint, self(), method, path, body})

      receive do
        :complete ->
          {:ok,
           %{
             status: 201,
             body: %{
               "token" => "host-only-publication-token",
               "expires_at" => DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.to_iso8601()
             }
           }}
      after
        5_000 -> {:error, :test_mint_not_released}
      end
    end
  end

  setup do
    suffix = "grant-#{Ecto.UUID.generate()}"
    %{claim: claim, publication: publication} = PublicationFixture.approved!(suffix)
    {:ok, publish} = Custody.claim_next("publication:#{suffix}", 60)
    assert publish.publication.id == publication.id
    publication = publish.publication
    session = claim.session

    {:ok, settings} = Settings.initialize("control-plane:local")

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "ryker", github_repository: "example/repository", base_branch: "main"},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "github-main",
          repository_ref: "ryker",
          installation_id: 41,
          repository_id: 17,
          ryker_actor_id: 30
        },
        settings.installation.revision,
        "control-plane:local"
      )

    certificate = "certificate:#{suffix}"
    hash = digest(certificate)
    # A shared worker ID deadlocked async fixtures that took the settings lock
    # after enrollment; sandbox rollback does not isolate unique-index locks.
    worker_id = "worker:#{suffix}"
    {:ok, _worker} = CoopWorkers.authorize(worker_id, "workspace-main", hash)

    poll =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("poll")
      |> Map.merge(%{
        "acknowledged_command_ids" => [],
        "command_results" => [],
        "event_batches" => []
      })
      |> put_in(["worker", "id"], worker_id)
      |> put_in(["worker", "clock_at"], DateTime.to_iso8601(Repo.now!()))

    {:ok, _response} = ControlPlane.handle_poll_certificate(certificate, poll)

    {:ok, placement} =
      ControlPlane.place_session(
        session.id,
        %{capability_names: [], repository_ref: "ryker", workspace_ref: "workspace-main"},
        60
      )

    {:ok, review} =
      ControlPlane.enqueue_command(
        placement.id,
        "run_review",
        %{
          "coop_session_id" => session.coop_session_id,
          "expected_revision" => publication.review_expected_revision
        },
        Executor.review_key(publication)
      )

    review = complete!(review, 200)

    {:ok, intent} = Request.new(publication)

    {:ok, body} =
      Request.worker_body(intent, %{"ryker" => %{base_branch: "main", branch_prefix: "ryker"}})

    payload = %{
      "method" => "POST",
      "path" =>
        "/v1/sessions/#{session.coop_session_id}/reviews/#{publication.review_document["operation_id"]}/publish",
      "body" => body
    }

    {:ok, command} =
      ControlPlane.enqueue_command(
        placement.id,
        "api_request",
        payload,
        Executor.publish_key(publication)
      )

    command = command |> change(status: :delivered) |> Repo.update!()

    request = %{
      "session_id" => session.coop_session_id,
      "review_operation_id" => publication.review_document["operation_id"],
      "job_ref" => session.external_ref,
      "job_digest" => session.worker_job_digest,
      "repository" =>
        Map.take(
          session.worker_job_document["source"],
          ~w(repository_ref github_repository github_repository_id)
        ),
      "command_key" => command.idempotency_key,
      "request" => body
    }

    %{
      certificate: certificate,
      session: session,
      publication: publication,
      placement: placement,
      review: review,
      command: command,
      request: request
    }
  end

  test "exact manual approval mints a fresh single-repository write token, including after accepted 202",
       %{certificate: certificate, command: command, request: request, session: session} do
    provider = provider!()

    for status <- [:delivered, :succeeded] do
      if status == :succeeded, do: complete!(command, 202)

      {task, minter} = begin_mint(certificate, session, request, provider)
      send(minter, :complete)
      assert {:ok, grant} = Task.await(task)
      assert grant["token"] == "host-only-publication-token"
      assert grant["github_repository_id"] == 17
      assert grant["actor_id"] == 30
      refute Map.has_key?(request, "token")
    end
  end

  test "changed command, candidate, job, review, approval or owner cannot obtain a grant",
       %{
         certificate: certificate,
         publication: publication,
         request: request,
         review: review,
         session: session
       } do
    assert {:ok, _authority} = authority(certificate, session, request)

    for request <- [
          Map.put(request, "command_key", "wrong"),
          Map.put(request, "review_operation_id", "wrong"),
          Map.put(request, "job_digest", String.duplicate("f", 64)),
          put_in(request, ["request", "authorization_ref"], "wrong"),
          put_in(request, ["request", "candidate_head"], String.duplicate("f", 40)),
          put_in(request, ["request", "body"], "Changed after approval")
        ] do
      assert {:error, :publication_grant_denied} = authority(certificate, session, request)
    end

    assert {:error, :publication_grant_denied} =
             authority("another-worker", session, request)

    review
    |> change(payload: Map.put(review.payload, "expected_revision", 8))
    |> Repo.update!()

    assert {:error, :publication_grant_denied} = authority(certificate, session, request)

    review.__struct__
    |> Repo.get!(review.id)
    |> change(payload: review.payload)
    |> Repo.update!()

    assert {:ok, _authority} = authority(certificate, session, request)

    publication
    |> change(review_document: Map.put(publication.review_document, "candidate_retained", false))
    |> Repo.update!()

    assert {:error, :publication_grant_denied} = authority(certificate, session, request)
  end

  # A review waits for a person; its placement's lease does not. Once a publish could follow the
  # session to a newer placement on the worker holding it (2026-09-30), the grant still demanded
  # the review's own placement, so both waiting publications came back as
  # publication_authorization_revoked.
  test "a review from an earlier placement on the same worker grants the publish that follows it",
       %{
         certificate: certificate,
         command: command,
         placement: placement,
         request: request,
         session: session
       } do
    placement
    |> change(state: :replaced, lease_expires_at: DateTime.add(Repo.now!(), -60))
    |> Repo.update!()

    {:ok, replaced} =
      ControlPlane.place_session(
        session.id,
        %{capability_names: [], repository_ref: "ryker", workspace_ref: "workspace-main"},
        60
      )

    assert replaced.worker_id == placement.worker_id
    assert replaced.generation > placement.generation
    Repo.delete!(command)

    {:ok, command} =
      ControlPlane.enqueue_command(
        replaced.id,
        "api_request",
        command.payload,
        command.idempotency_key
      )

    command |> change(status: :delivered) |> Repo.update!()
    assert {:ok, %{placement: {id, _generation}}} = authority(certificate, session, request)
    assert id == replaced.id
  end

  # Andrew's PR #2, 2026-10-01: Coop pushed the commit, then its first attempt ended before
  # GitHub showed the new head. Each retry asked for a grant at :44 past the minute while Ryker
  # held the publication's lease for a second at :48 to check on it, so every retry was refused
  # and the publish never finished: the card said it was updating the PR for as long as anyone
  # looked. The grant rests on the exact command Ryker sent; Ryker's own checks need no lease.
  test "a worker retrying an in-flight publish gets its grant between Ryker's checks",
       %{certificate: certificate, publication: publication, request: request, session: session} do
    publication
    |> change(
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: DateTime.add(Repo.now!(), 60)
    )
    |> Repo.update!()

    assert {:ok, _authority} = authority(certificate, session, request)
  end

  test "placement lease expiry is temporary but a retired placement is a terminal denial",
       %{certificate: certificate, placement: placement, request: request, session: session} do
    placement |> change(lease_expires_at: DateTime.add(Repo.now!(), -1)) |> Repo.update!()
    assert route(certificate, session, request).status == 503
    assert {:error, :publication_grant_unavailable} = authority(certificate, session, request)
    placement |> change(state: :retired) |> Repo.update!()
    assert {:error, :publication_grant_denied} = authority(certificate, session, request)
    assert route(certificate, session, request).status == 403
  end

  test "a placement revoked while GitHub mints the token never receives it",
       %{certificate: certificate, placement: placement, request: request, session: session} do
    provider = provider!()
    {task, minter} = begin_mint(certificate, session, request, provider)
    placement |> change(state: :revoking) |> Repo.update!()
    send(minter, :complete)
    assert {:error, :publication_grant_denied} = Task.await(task)
  end

  test "a binding changed during token minting never receives the old repository credential",
       %{certificate: certificate, request: request, session: session} do
    provider = provider!()
    {task, minter} = begin_mint(certificate, session, request, provider)
    {:ok, snapshot} = Settings.fetch()

    {:ok, _snapshot} =
      Settings.put_github_binding(
        %{
          name: "github-main",
          repository_ref: "ryker",
          installation_id: 42,
          repository_id: 17,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        "control-plane:local"
      )

    send(minter, :complete)
    assert {:error, :publication_grant_unavailable} = Task.await(task)
  end

  defp authority(certificate, session, request) do
    PublicationGrants.publication_grant_authority(certificate, session.external_ref, request)
  end

  defp complete!(command, status) do
    result = %{"status" => status}

    command
    |> change(
      status: :succeeded,
      result: result,
      operation_key: command.idempotency_key,
      result_fingerprint: Ryker.CanonicalJSON.digest(result),
      completed_at: Repo.now!()
    )
    |> Repo.update!()
  end

  defp provider! do
    start_supervised!(
      {InstallationTokens,
       %{
         app_http: self(),
         name: nil,
         requester: Requester,
         bindings: %{"github-main" => %{repository_id: 17, installation_id: 41}}
       }}
    )
  end

  defp begin_mint(certificate, session, request, provider) do
    task =
      Task.async(fn ->
        receive do
          :begin ->
            PublicationGrants.publication_grant(
              certificate,
              session.external_ref,
              request,
              provider
            )
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :begin)

    # Each mint runs in its own process, which the test releases.
    assert_receive {:mint, minter, :post, "/app/installations/41/access_tokens",
                    %{
                      "permissions" => %{"contents" => "write", "pull_requests" => "write"},
                      "repository_ids" => [17]
                    }},
                   5_000

    {task, minter}
  end

  defp route(certificate, session, request) do
    :post
    |> conn(
      "/v1/coop-workers/jobs/#{session.external_ref}/publication-grants",
      Jason.encode!(request)
    )
    |> put_req_header("content-type", "application/json")
    |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
    |> Router.call([])
  end
end
