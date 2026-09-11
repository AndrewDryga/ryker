defmodule Responder.CoopFleet.SessionEvidenceTest do
  use Responder.DataCase, async: true

  alias Responder.CoopFleet.{ControlPlane, SessionEvidence, SessionEvidenceCapture}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.Custody

  defmodule FailingAPI do
    @moduledoc false
    # The client argument carries the scripted response, so one module covers
    # every failure mode without an agent to keep alive.
    def get_session_evidence(:raise, _session_id), do: raise("the evidence export blew up")
    def get_session_evidence(:exit, _session_id), do: exit(:evidence_transport_died)

    def get_session_evidence(:foreign, _session_id) do
      document =
        Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("session_id", "remote_someone_elses_session")

      {:ok, document}
    end

    def get_session_evidence({:error, _reason} = error, _session_id), do: error
    def get_session_evidence(document, _session_id) when is_map(document), do: {:ok, document}
  end

  defmodule ExportlessAPI do
    @moduledoc false
  end

  defmodule ExportingAPI do
    @moduledoc false
    def get_session_evidence(_client, _session_id), do: {:ok, %{}}
  end

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @fixture Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)

  defp evidence(overrides \\ %{}) do
    @fixture |> File.read!() |> Jason.decode!() |> deep_merge(overrides)
  end

  defp deep_merge(%{} = base, %{} = overrides) do
    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp bound_session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "evidence:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: DateTime.utc_now(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    {:ok, _transition} = Episodes.apply(command)

    {:ok, session} =
      Custody.pin_episode(
        command.episode_id,
        "work-read-only",
        @policy_digest,
        @authority_digest,
        "responder"
      )

    {:ok, bound} =
      session
      |> Ecto.Changeset.change(coop_session_id: "remote_01j9zq3f8m0c7e6kq9y2s4x1nt")
      |> Repo.update()

    bound
  end

  @sandbox_digest String.duplicate("a", 64)

  # A real worker, a real poll advertising the export, and a real placement: the
  # capture path only reaches the read when all three exist.
  defp placed_session!(suffix, options \\ []) do
    session = bound_session!(suffix)
    worker_id = "worker-#{suffix}"

    capabilities =
      Keyword.get(options, :capabilities, [
        %{"name" => "responder-state", "version" => "1"},
        %{"name" => "session-evidence", "version" => "1"}
      ])

    {:ok, _worker} =
      ControlPlane.authorize_worker(
        worker_id,
        "workspace-main",
        :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)
      )

    {:ok, _response} =
      ControlPlane.handle_poll(worker_id, %{
        "acknowledged_command_ids" => [],
        "command_results" => [],
        "event_batches" => [],
        "poll_ref" => "poll:#{worker_id}:1",
        "version" => 1,
        "worker" => %{
          "build_version" => "coop-evidence",
          "capabilities" => capabilities,
          "capacity" => %{
            "session_slots_free" => 2,
            "session_slots_total" => 4,
            "turn_slots_free" => 2,
            "turn_slots_total" => 4,
            "workspace_slots_free" => 2,
            "workspace_slots_total" => 4,
            "state" => "eligible",
            "cooldown_until" => nil
          },
          "clock_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "id" => worker_id,
          "policy_authority_digests" => %{"work-read-only" => @authority_digest},
          "policy_digests" => %{"work-read-only" => @policy_digest},
          "protocol_version" => "1",
          "repositories" => [%{"ref" => "responder", "revision" => "commit:abc123"}],
          "sandbox_digest" => @sandbox_digest,
          "state" => "eligible",
          "storage" => nil,
          "workspace_ref" => "workspace-main"
        }
      })

    {:ok, placement} =
      ControlPlane.place_session(
        session.id,
        %{
          capability_names: ["responder-state"],
          repository_ref: "responder",
          workspace_ref: "workspace-main"
        },
        60
      )

    {session, placement}
  end

  defp record(session, document \\ nil, options \\ []) do
    SessionEvidence.record(
      session.id,
      document || evidence(),
      Keyword.merge([worker_id: "worker-a", placement_generation: 1], options)
    )
  end

  test "one capture records the exact validated export against its session and worker" do
    session = bound_session!("record")

    assert {:ok, %{evidence: stored, recorded: :inserted}} = record(session)

    assert stored.session_id == session.id
    assert stored.episode_id == session.episode_id
    assert stored.coop_session_id == "remote_01j9zq3f8m0c7e6kq9y2s4x1nt"
    assert stored.worker_id == "worker-a"
    assert stored.placement_generation == 1
    assert stored.network_mode == "filtered"
    assert stored.task_status == "bound"
    assert stored.capture_count == 1
    assert stored.first_captured_at == stored.last_captured_at

    assert {:ok, document} = SessionEvidence.document(stored)
    assert document["network"]["observation"]["run_id"] == "run-7f3a"

    # The counter above 2^53 has to come back out of the database exactly.
    assert document["network"]["observation"]["counters"]["denied_packets"] ==
             "18446744073709551615"
  end

  test "a redelivered capture of the same state advances its times without inventing history" do
    session = bound_session!("idempotent")

    assert {:ok, %{evidence: first, recorded: :inserted}} = record(session)

    later = evidence(%{"captured_at" => "2026-09-11T15:00:00Z"})
    assert {:ok, %{evidence: again, recorded: :unchanged}} = record(session, later)

    assert again.id == first.id
    assert again.capture_count == 2
    assert again.first_captured_at == first.first_captured_at
    assert DateTime.compare(again.last_captured_at, first.last_captured_at) == :gt
    assert length(SessionEvidence.for_session(session.id)) == 1

    # A capture whose clock runs backwards still counts, and never rewinds the
    # latest observation to an earlier one.
    earlier = evidence(%{"captured_at" => "2026-09-11T10:00:00Z"})
    assert {:ok, %{evidence: rewound, recorded: :unchanged}} = record(session, earlier)
    assert rewound.capture_count == 3
    assert rewound.last_captured_at == again.last_captured_at
    assert rewound.first_captured_at == first.first_captured_at
  end

  test "a genuinely changed session records a new state beside the old one" do
    session = bound_session!("changed")

    assert {:ok, %{evidence: first, recorded: :inserted}} = record(session)

    progressed =
      evidence(%{
        "captured_at" => "2026-09-11T15:00:00Z",
        "task" => %{"snapshot" => %{"state" => "done"}}
      })

    assert {:ok, %{evidence: second, recorded: :inserted}} = record(session, progressed)

    assert second.id != first.id
    assert length(SessionEvidence.for_session(session.id)) == 2

    # The earlier snapshot keeps saying what it said: a later capture is not a
    # correction of an earlier one.
    assert {:ok, old} = SessionEvidence.document(Repo.get!(SessionEvidence, first.id))
    assert old["task"]["snapshot"]["state"] == "in_progress"
  end

  test "evidence for another remote session is refused rather than rebound" do
    session = bound_session!("custody")

    stolen = evidence(%{"session_id" => "remote_someone_elses_session"})

    assert {:error, {:coop_session_evidence_session_conflict, "remote_someone_elses_session"}} =
             record(session, stolen)

    assert SessionEvidence.for_session(session.id) == []
  end

  test "an unbound local session cannot be named by the export it is given" do
    session = bound_session!("unbound")
    {:ok, unbound} = session |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update()

    assert {:error, {:coop_session_evidence_session_conflict, _remote}} = record(unbound)
    assert SessionEvidence.for_session(unbound.id) == []
  end

  test "malformed evidence never reaches the table" do
    session = bound_session!("malformed")

    assert {:error, {:invalid_coop_session_evidence, :network_mode}} =
             record(session, evidence(%{"network" => %{"mode" => "maybe"}}))

    assert {:error, {:invalid_coop_session_evidence, :worker_id}} =
             record(session, evidence(), worker_id: "")

    assert {:error, {:invalid_coop_session_evidence, :placement_generation}} =
             record(session, evidence(), placement_generation: 0)

    assert SessionEvidence.for_session(session.id) == []
  end

  for {label, response} <- [
        {"a read that fails", {:error, {:coop_error, 503, "unavailable", "registry unreadable"}}},
        {"a read that raises", :raise},
        {"a transport that dies mid-read", :exit},
        {"an export that violates its own contract", %{"version" => 1, "broken" => true}},
        {"an export naming another session", :foreign}
      ] do
    test "a placed capture reports #{label} as a reason and records nothing" do
      # The capture runs against a real placement on a worker that advertises the
      # export, so this exercises the read itself rather than an early skip. Every
      # failure mode has to come back as a value: an exception or an exit escaping
      # here would kill the executor holding an already-accepted turn.
      {session, _placement} = placed_session!("failure-#{System.unique_integer([:positive])}")

      result =
        SessionEvidenceCapture.capture(
          session,
          FailingAPI,
          unquote(Macro.escape(response))
        )

      assert match?({:error, _reason}, result), "capture returned #{inspect(result)}"
      assert SessionEvidence.for_session(session.id) == []
    end
  end

  test "a placed capture on an advertising worker records the export" do
    {session, placement} = placed_session!("placed")

    assert {:ok, %{evidence: stored, recorded: :inserted}} =
             SessionEvidenceCapture.capture(session, FailingAPI, evidence())

    assert stored.worker_id == placement.worker_id
    assert stored.placement_generation == placement.generation
  end

  test "a worker that stops advertising the export is not asked again" do
    # Still a placeable worker -- it advertises responder-state -- but it no
    # longer advertises the export, which is the only thing that changes.
    {session, _placement} =
      placed_session!("unadvertised",
        capabilities: [%{"name" => "responder-state", "version" => "1"}]
      )

    assert SessionEvidenceCapture.capture(session, FailingAPI, evidence()) ==
             {:skipped, :export_not_advertised}

    assert SessionEvidence.for_session(session.id) == []
  end

  test "capture is skipped, never faked, when the worker does not advertise the export" do
    session = bound_session!("capability")

    # No placement, no worker, no adapter support: three different skips, and
    # none of them records an absence as an observation.
    assert {:skipped, :export_unsupported} =
             SessionEvidenceCapture.capture(session, ExportlessAPI, :client)

    assert {:skipped, :no_active_placement} =
             SessionEvidenceCapture.capture(session, ExportingAPI, :client)

    assert SessionEvidence.for_session(session.id) == []
  end

  test "an unbound session is never captured" do
    session = bound_session!("capture-unbound")
    {:ok, unbound} = session |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update()

    assert SessionEvidenceCapture.capture(unbound, ExportingAPI, :client) ==
             {:skipped, :session_not_bound}
  end

  test "the latest capture per session is what a card reads, with the rest retained" do
    session = bound_session!("latest")

    assert {:ok, _first} = record(session)

    assert {:ok, %{evidence: newest}} =
             record(
               session,
               evidence(%{
                 "captured_at" => "2026-09-11T16:00:00Z",
                 "task" => %{"snapshot" => %{"state" => "done"}}
               })
             )

    assert [latest] = SessionEvidence.latest_for_episode(session.episode_id)
    assert latest.id == newest.id
    assert length(SessionEvidence.for_session(session.id)) == 2

    # An episode nobody captured reads as no evidence at all, which the page
    # must render as "not recorded" rather than as a session with no network.
    assert SessionEvidence.latest_for_episode(Ecto.UUID.generate()) == []
  end
end
