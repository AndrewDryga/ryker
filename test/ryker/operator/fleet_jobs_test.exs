defmodule Ryker.Operator.FleetJobsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Operator.{FleetJob, FleetJobs}
  alias Ryker.Work

  test "submission pins an independent work episode and identical retries return its receipt" do
    id = Ecto.UUID.generate()

    assert {:ok, receipt} =
             FleetJobs.submit(
               id,
               %{environment: "local", repository: "project"},
               "Run the check",
               &policy/2
             )

    assert receipt.job_id == id
    assert {:ok, %{items: [^receipt], total: 1, pages: 1}} = FleetJobs.list()

    assert {:ok, ^receipt} =
             FleetJobs.submit(
               id,
               %{environment: "local", repository: "project"},
               "Run the check",
               fn _, _ ->
                 flunk("retry consulted changed policy")
               end
             )

    assert FleetJobs.submit(
             id,
             %{environment: "local", repository: "project"},
             "Other request",
             &policy/2
           ) ==
             {:error, :fleet_job_idempotency_conflict}

    session = receipt.episode_id |> Work.Session.Query.by_episode_id() |> Repo.fetch!()

    assert {session.environment_ref, session.repository_ref, session.policy} ==
             {"local", "project", "contributor"}

    assert session.workspace_task["prompt"] == "Run the check"
    assert session.workspace_task["offer_ref"] == "operator-fleet-job:" <> id

    assert {:ok, %{state: :working, result: nil, last_saved_checkpoint: nil}} =
             FleetJobs.fetch(id)

    assert Repo.aggregate(FleetJob.Query.all(), :count) == 1
  end

  test "verification preserves the source and changing purpose requires another job ID" do
    placement = %{environment: "local", repository: "project"}

    submit = fn id, purpose ->
      FleetJobs.submit(id, Map.put(placement, :purpose, purpose), "Run checks", &policy/2)
    end

    id = Ecto.UUID.generate()
    assert {:ok, receipt} = submit.(id, "verification")
    session = receipt.episode_id |> Work.Session.Query.by_episode_id() |> Repo.fetch!()
    assert session.workspace_task["purpose"] == "verification"
    assert {:ok, ^receipt} = submit.(id, "verification")
    assert submit.(id, "implementation") == {:error, :fleet_job_idempotency_conflict}
    assert submit.(Ecto.UUID.generate(), "other") == {:error, :invalid_fleet_job}

    original = Ecto.UUID.generate()
    assert {:ok, legacy} = submit.(original, nil)
    assert {:ok, ^legacy} = submit.(original, "implementation")
  end

  test "an exact commit travels with the job and participates in replay identity" do
    id = Ecto.UUID.generate()
    placement = %{environment: "local", repository: "project", commit: String.duplicate("a", 40)}
    assert {:ok, receipt} = FleetJobs.submit(id, placement, "Use the pinned commit", &policy/2)
    session = receipt.episode_id |> Work.Session.Query.by_episode_id() |> Repo.fetch!()
    assert session.repository_source == %{"kind" => "commit", "sha" => placement.commit}

    assert FleetJobs.submit(
             id,
             %{placement | commit: String.duplicate("b", 40)},
             "Use the pinned commit",
             &policy/2
           ) ==
             {:error, :fleet_job_idempotency_conflict}

    assert FleetJobs.submit(
             Ecto.UUID.generate(),
             %{placement | commit: "../main"},
             "reject",
             &policy/2
           ) == {:error, :invalid_fleet_job}
  end

  test "cancelling before a worker claims the job settles locally and replay leaves it cancelled" do
    id = Ecto.UUID.generate()

    {:ok, receipt} =
      FleetJobs.submit(
        id,
        %{environment: "local", repository: "project"},
        "Cancel before claim",
        &policy/2
      )

    assert {:ok, %{job_id: ^id, cancellation: :settled}} = FleetJobs.cancel(id)
    assert {:ok, %{state: :cancelled}} = FleetJobs.fetch(id)
    assert {:ok, %{cancellation: :settled}} = FleetJobs.cancel(id)

    assert {:ok, ^receipt} =
             FleetJobs.submit(
               id,
               %{environment: "local", repository: "project"},
               "Cancel before claim",
               &policy/2
             )

    assert {:ok, %{state: :cancelled}} = FleetJobs.fetch(id)
  end

  test "missing policy or mismatched repository never produces a job" do
    id = Ecto.UUID.generate()

    assert FleetJobs.submit(id, %{environment: "local", repository: "other"}, "Task", &policy/2) ==
             {:error, :fleet_job_policy_unavailable}

    assert FleetJobs.submit(id, %{environment: "local", repository: "project"}, "Task", fn _, _ ->
             {:error, :offline}
           end) ==
             {:error, :offline}

    assert FleetJobs.fetch(id) == {:error, :fleet_job_not_found}

    for prompt <- ["", " \t ", String.duplicate("a", 20_001), <<0>>, <<255>>, :eof] do
      assert FleetJobs.submit(
               id,
               %{environment: "local", repository: "project"},
               prompt,
               &policy/2
             ) ==
               {:error, :invalid_fleet_job}
    end

    assert FleetJobs.fetch("invalid") == {:error, :fleet_job_not_found}
    assert {:ok, %{items: [], total: 0}} = FleetJobs.list()
  end

  test "fleet inspection pages all retained events for only the requested job" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    worker = "inspection-worker"

    {:ok, _} =
      Ryker.Fixtures.CoopWorkers.authorize(worker, "pool", Ryker.Crypto.sha256_hex(worker))

    for {job, count} <- [{first, 28}, {second, 1}] do
      {:ok, receipt} =
        FleetJobs.submit(
          job,
          %{environment: "local", repository: "project"},
          "Inspect",
          &policy/2
        )

      session = Repo.fetch!(Work.Session.Query.latest_of_episode(receipt.episode_id))

      placement =
        Repo.insert!(%Ryker.CoopFleet.Placement{
          session_id: session.id,
          worker_id: worker,
          generation: 1,
          lease_ref: "lease:" <> job,
          lease_expires_at: DateTime.add(Repo.now!(), 60),
          state: :active,
          requirements: %{},
          requirements_fingerprint: String.duplicate("a", 64)
        })

      for sequence <- 1..count do
        Repo.insert!(%Ryker.CoopFleet.Event{
          placement_id: placement.id,
          worker_id: worker,
          session_id: session.id,
          placement_generation: 1,
          sequence: sequence,
          kind: "turn",
          payload: %{"marker" => job, "api_key" => "private-canary"},
          payload_fingerprint: String.duplicate("c", 64)
        })
      end
    end

    assert {:ok, %{items: early, page: 1, pages: 2, total: 28}} = FleetJobs.events(first, 1)
    assert {:ok, %{items: late, page: 2}} = FleetJobs.events(first, 2)
    assert Enum.map(early ++ late, & &1.sequence) == Enum.to_list(1..28)
    assert Enum.all?(early ++ late, &(&1.payload["marker"] == first))
    refute Jason.encode!(early ++ late) =~ "private-canary"

    assert {:ok, %{items: [%{id: ^worker, heartbeat_current: false}], total: 1}} =
             FleetJobs.workers(1)

    assert FleetJobs.events(Ecto.UUID.generate(), 1) == {:error, :fleet_job_not_found}
  end

  test "service inspection follows only the current enrolled holder and fences an expired read" do
    worker = "service-worker"

    {:ok, enrolled} =
      Ryker.Fixtures.CoopWorkers.authorize(worker, "pool", Ryker.Crypto.sha256_hex(worker))

    enrolled
    |> Ecto.Changeset.change(
      machine_daemon: String.duplicate("d", 64),
      capabilities: [%{"name" => "service-relay", "version" => "1"}]
    )
    |> Repo.update!()

    job = Ecto.UUID.generate()

    {:ok, receipt} =
      FleetJobs.submit(
        job,
        %{environment: "local", repository: "project"},
        "Read db logs",
        &policy/2
      )

    session = Repo.fetch!(Work.Session.Query.latest_of_episode(receipt.episode_id))
    assert FleetJobs.services(job, []) == {:error, :fleet_services_unavailable}

    session
    |> Work.Session.Changeset.bind("coop-one")
    |> Repo.update!()
    |> Ryker.Fixtures.WorkerJob.pin!()

    placement =
      Repo.insert!(%Ryker.CoopFleet.Placement{
        session_id: session.id,
        worker_id: worker,
        generation: 1,
        lease_ref: "lease:" <> job,
        lease_expires_at: DateTime.add(Repo.now!(), 60),
        state: :active,
        requirements: %{},
        requirements_fingerprint: String.duplicate("a", 64)
      })

    settle = fn path, result ->
      command =
        session.id
        |> Ryker.CoopFleet.Command.Query.by_session_id()
        |> Ryker.CoopFleet.Command.Query.in_flight()
        |> Repo.fetch!()

      assert command.payload["path"] == path

      command
      |> Ryker.CoopFleet.Command.Changeset.settle(%{
        status: :succeeded,
        completed_at: Repo.now!(),
        result: %{"status" => 200, "body" => result}
      })
      |> Repo.update!()

      :ok
    end

    container = String.duplicate("a", 64)
    prefix = "/v1/sessions/coop-one/services"

    services = [
      %{"name" => "db", "container_id" => container, "ports" => [5432], "state" => "running"}
    ]

    assert {:ok, %{services: ^services, worker_id: ^worker, placement_generation: 1}} =
             FleetJobs.services(job, wait: fn -> settle.(prefix, %{"services" => services}) end)

    preview = [
      checkpoint_key: Ryker.Secret.new(:binary.copy(<<7>>, 32)),
      wait: fn -> settle.(prefix, %{"services" => services}) end
    ]

    assert Ryker.CoopFleet.ServiceRelays.issue(job, "db", 6379, preview) ==
             {:error, :fleet_service_unavailable}

    assert {:ok, %{token: token}} = Ryker.CoopFleet.ServiceRelays.issue(job, "db", 5432, preview)
    assert {:ok, binding} = Ryker.CoopFleet.ServiceRelays.verify(token, preview)
    assert binding.container == container and binding.holder.worker == worker
    assert Ryker.CoopFleet.ServiceRelays.verify(token <> "x", preview) == :error

    path = prefix <> "/db/logs?container=" <> container <> "&cursor="

    assert {:ok, %{at_end: true, records: [%{"text" => "database ready"}]}} =
             FleetJobs.service_logs(job, "db", container, "",
               wait: fn ->
                 settle.(path, %{"records" => [%{"text" => "database ready"}], "at_end" => true})
               end
             )

    assert FleetJobs.service_logs(job, "../other", container, "", []) ==
             {:error, :invalid_fleet_log_request}

    assert FleetJobs.services(job,
             wait: fn ->
               settle.(prefix, %{"services" => services})

               placement
               |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Repo.now!(), -1))
               |> Repo.update!()

               :ok
             end
           ) == {:error, :fleet_services_unavailable}

    assert Ryker.CoopFleet.ServiceRelays.verify(token, preview) == :error
  end

  @tag :tmp_dir
  test "local input is bound to the operator receipt, active worker and exact body", %{
    tmp_dir: dir
  } do
    %{certificate: cert} = Ryker.Fixtures.ModelAccess.create!()
    id = Ecto.UUID.generate()
    placement = %{environment: "local", repository: "project", commit: String.duplicate("a", 40)}
    placement = Map.put(placement, :purpose, "verification")
    options = [body_root: dir, checkpoint_key: Ryker.Secret.new(:binary.copy(<<7>>, 32))]
    root = Ryker.Operator.WorkspaceInputs.root(options)
    submit = fn job, placed -> FleetJobs.submit(job, placed, "Use local edits", &policy/2) end

    upload = fn id, data ->
      Ryker.Operator.WorkspaceInputs.submit(
        id,
        placement,
        reference(data),
        [data],
        options,
        submit
      )
    end

    data = archive(id, placement, "local binary content")
    assert {:error, _} = upload.(Ecto.UUID.generate(), data)

    assert {:error, _} =
             upload.(id, archive(id, placement, "controller-only-provider-key-canary"))

    assert {:error, _} = upload.(id, binary_part(data, 0, byte_size(data) - 1))
    assert {:ok, receipt} = upload.(id, data)
    session = receipt.episode_id |> Work.Session.Query.latest_of_episode() |> Repo.fetch!()

    assert session.workspace_task["verification_input_sha256"] ==
             Ryker.Crypto.sha256_hex(String.duplicate(placement.commit <> "\n", 3))

    assert {:ok, ^receipt} = upload.(id, data)

    assert upload.(id, archive(id, placement, "other content")) ==
             {:error, :fleet_job_idempotency_conflict}

    row = Repo.fetch!(FleetJob.Query.by_id(id))
    assert File.ls!(root) == [row.workspace_input_id]

    refute File.read!(Path.join([root, row.workspace_input_id, "request", "data"])) =~
             "local binary content"

    session = receipt.episode_id |> Work.Session.Query.by_episode_id() |> Repo.fetch!()

    job =
      Ryker.Fixtures.WorkerJob.pin!(session).worker_job_document
      |> Map.put("workspace_input", reference(data))

    {:ok, hash} = Ryker.CoopFleet.JobSpec.digest(job)
    session |> Work.Session.Changeset.pin_worker_job(job, hash) |> Repo.update!()

    {:ok, lease} =
      Ryker.CoopFleet.ControlPlane.place_session(
        session.id,
        %{workspace_ref: "model-pool", capability_names: [], repository_ref: "project"},
        60
      )

    assert {:ok, input} = Ryker.Operator.WorkspaceInputs.authorize(cert, session.external_ref)
    assert input.id == row.workspace_input_id

    download = fn certificate ->
      :get
      |> Plug.Test.conn("/v1/coop-workers/jobs/#{session.external_ref}/workspace-input")
      |> Plug.Test.put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Ryker.CoopFleet.Router.call(options)
    end

    response = download.(cert)
    assert response.status == 200
    assert response.resp_body == data
    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]
    assert download.("another-worker").status == 404

    assert {:error, _} =
             Ryker.Operator.WorkspaceInputs.authorize("other-certificate", session.external_ref)

    assert {:error, _} = Ryker.Operator.WorkspaceInputs.authorize(cert, id)
    {:ok, body, _} = Ryker.CoopFleet.Bodies.fetch(root, input.id, :request, input.reference)

    assert Ryker.CoopFleet.Bodies.with_stream(body, options[:checkpoint_key], &Enum.join(&1.())) ==
             data

    # A credential may have been registered while this job waited in the queue.
    assert {:ok, _} =
             Ryker.CoopFleet.ModelAccounts.put_key("claude@work", "local binary content", "test")

    refused = download.(cert)
    assert refused.status == 503
    refute refused.resp_body =~ "local binary content"
    lease |> Ecto.Changeset.change(state: :replaced) |> Repo.update!()
    assert download.(cert).status == 404
    assert {:error, _} = Ryker.Operator.WorkspaceInputs.authorize(cert, session.external_ref)
  end

  defp archive(id, placement, content) do
    manifest = %{
      "version" => 1,
      "job_ref" => "operator-fleet-job:" <> id,
      "repository_ref" => placement.repository,
      "base_revision" => placement.commit,
      "committed_revision" => placement.commit,
      "tracked_tree" => placement.commit,
      "repository" => Map.put(reference(content), "entry", "repository.tar"),
      "untracked_files" => []
    }

    Ryker.Fixtures.WorkspaceCheckpoint.tar([
      {"manifest.json", Jason.encode!(manifest)},
      {"repository.tar", content}
    ])
  end

  defp reference(data),
    do: %{"sha256" => Ryker.Crypto.sha256_hex(data), "byte_size" => byte_size(data)}

  defp policy(_environment, _repository) do
    {:ok,
     %{
       name: "contributor",
       digest: String.duplicate("b", 64),
       environment_ref: "local",
       repository_ref: "project"
     }}
  end
end
