defmodule Ryker.CoopFleet.PublicationGrantsTest do
  use Ryker.DataCase, async: true

  import Ecto.Changeset, only: [change: 2]
  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.{ControlPlane, PublicationGrants, Router}
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
    hash = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)
    # A shared worker ID deadlocked async fixtures that took the settings lock
    # after enrollment; sandbox rollback does not isolate unique-index locks.
    worker_id = "worker:#{suffix}"
    {:ok, _worker} = ControlPlane.authorize_worker(worker_id, "workspace-main", hash)

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
       context do
    provider = provider!()

    for status <- [:delivered, :succeeded] do
      if status == :succeeded, do: complete!(context.command, 202)

      {task, minter} = begin_mint(context, provider)
      send(minter, :complete)
      assert {:ok, grant} = Task.await(task)
      assert grant["token"] == "host-only-publication-token"
      assert grant["github_repository_id"] == 17
      assert grant["actor_id"] == 30
      refute Map.has_key?(context.request, "token")
    end
  end

  test "changed command, candidate, job, review, approval or owner cannot obtain a grant",
       context do
    assert {:ok, _authority} = authority(context)

    for request <- [
          Map.put(context.request, "command_key", "wrong"),
          Map.put(context.request, "review_operation_id", "wrong"),
          Map.put(context.request, "job_digest", String.duplicate("f", 64)),
          put_in(context.request, ["request", "authorization_ref"], "wrong"),
          put_in(context.request, ["request", "candidate_head"], String.duplicate("f", 40)),
          put_in(context.request, ["request", "body"], "Changed after approval")
        ] do
      assert {:error, :publication_grant_denied} = authority(%{context | request: request})
    end

    assert {:error, :publication_grant_denied} =
             authority(%{context | certificate: "another-worker"})

    context.review
    |> change(payload: Map.put(context.review.payload, "expected_revision", 8))
    |> Repo.update!()

    assert {:error, :publication_grant_denied} = authority(context)

    context.review.__struct__
    |> Repo.get!(context.review.id)
    |> change(payload: context.review.payload)
    |> Repo.update!()

    assert {:ok, _authority} = authority(context)

    context.publication
    |> change(
      review_document: Map.put(context.publication.review_document, "candidate_retained", false)
    )
    |> Repo.update!()

    assert {:error, :publication_grant_denied} = authority(context)
  end

  # A review waits for a person; its placement's lease does not. Once a publish could follow the
  # session to a newer placement on the worker holding it (2026-09-30), the grant still demanded
  # the review's own placement, so both waiting publications came back as
  # publication_authorization_revoked.
  test "a review from an earlier placement on the same worker grants the publish that follows it",
       context do
    context.placement
    |> change(state: :replaced, lease_expires_at: DateTime.add(Repo.now!(), -60))
    |> Repo.update!()

    {:ok, replaced} =
      ControlPlane.place_session(
        context.session.id,
        %{capability_names: [], repository_ref: "ryker", workspace_ref: "workspace-main"},
        60
      )

    assert replaced.worker_id == context.placement.worker_id
    assert replaced.generation > context.placement.generation
    Repo.delete!(context.command)

    {:ok, command} =
      ControlPlane.enqueue_command(
        replaced.id,
        "api_request",
        context.command.payload,
        context.command.idempotency_key
      )

    command |> change(status: :delivered) |> Repo.update!()
    assert {:ok, %{placement: {id, _generation}}} = authority(context)
    assert id == replaced.id
  end

  # Andrew's PR #2, 2026-10-01: Coop pushed the commit, then its first attempt ended before
  # GitHub showed the new head. Each retry asked for a grant at :44 past the minute while Ryker
  # held the publication's lease for a second at :48 to check on it, so every retry was refused
  # and the publish never finished: the card said it was updating the PR for as long as anyone
  # looked. The grant rests on the exact command Ryker sent; Ryker's own checks need no lease.
  test "a worker retrying an in-flight publish gets its grant between Ryker's checks", context do
    context.publication
    |> change(
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: DateTime.add(Repo.now!(), 60)
    )
    |> Repo.update!()

    assert {:ok, _authority} = authority(context)
  end

  test "placement lease expiry is temporary but a retired placement is a terminal denial",
       context do
    context.placement |> change(lease_expires_at: DateTime.add(Repo.now!(), -1)) |> Repo.update!()
    assert route(context).status == 503
    assert {:error, :publication_grant_unavailable} = authority(context)
    context.placement |> change(state: :retired) |> Repo.update!()
    assert {:error, :publication_grant_denied} = authority(context)
    assert route(context).status == 403
  end

  test "a placement revoked while GitHub mints the token never receives it", context do
    provider = provider!()
    {task, minter} = begin_mint(context, provider)
    context.placement |> change(state: :revoking) |> Repo.update!()
    send(minter, :complete)
    assert {:error, :publication_grant_denied} = Task.await(task)
  end

  test "a binding changed during token minting never receives the old repository credential",
       context do
    provider = provider!()
    {task, minter} = begin_mint(context, provider)
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

  defp authority(context),
    do:
      PublicationGrants.publication_grant_authority(
        context.certificate,
        context.session.external_ref,
        context.request
      )

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

  defp begin_mint(context, provider) do
    task =
      Task.async(fn ->
        receive do
          :begin ->
            PublicationGrants.publication_grant(
              context.certificate,
              context.session.external_ref,
              context.request,
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

  defp route(context) do
    :post
    |> conn(
      "/v1/coop-workers/jobs/#{context.session.external_ref}/publication-grants",
      Jason.encode!(context.request)
    )
    |> put_req_header("content-type", "application/json")
    |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: context.certificate})
    |> Router.call([])
  end
end
