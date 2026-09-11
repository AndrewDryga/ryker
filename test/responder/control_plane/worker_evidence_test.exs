defmodule Responder.ControlPlane.WorkerEvidenceTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.ControlPlane.WorkerEvidence
  alias Responder.CoopFleet.SessionEvidence
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.Custody

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @filtered Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)
  @open Path.expand("../../../testdata/protocol/coop-session-evidence-open-v1.json", __DIR__)

  defp fixture(path, overrides \\ %{}) do
    path |> File.read!() |> Jason.decode!() |> deep_merge(overrides)
  end

  defp deep_merge(%{} = base, %{} = overrides) do
    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "worker-evidence:#{suffix}:#{Ecto.UUID.generate()}",
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

  defp record!(session, document) do
    {:ok, %{evidence: stored}} =
      SessionEvidence.record(session.id, document,
        worker_id: "worker-a",
        placement_generation: 3
      )

    stored
  end

  test "a filtered capture becomes access, network and task cards with its own provenance" do
    session = session!("filtered")
    record!(session, fixture(@filtered))

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert card.state == :recorded
    assert card.worker == "worker-a"
    assert card.placement_generation == 3
    assert card.snapshot.kind == :current

    assert card.access.headline == "Filtered"
    assert card.access.availability.state == :recorded
    refute card.access.destinations_disclosed?
    assert card.access.requested == []

    # Configured is not enforced: the posture comes from the session row, and
    # only the enforcer layer's own observation says it was enforced.
    assert card.access.enforcement == %{state: :observed, status: "ok", reason: nil}

    assert card.network.availability.state == :recorded
    assert card.network.freshness == "terminal"
    assert card.network.scope == "Run run-7f3a · attempt attempt-2"
    assert card.network.sealed?

    assert card.task.state == :bound
    assert card.task.snapshot.state_label == "In progress"
    assert card.task.snapshot.checked.value == 3
    assert card.task.snapshot.total.value == 4
    assert card.task.snapshot.state_note.availability.state == :recorded
  end

  test "the receipt lists the runs it aggregated and says what it left out" do
    # The receipt is the session aggregate; the run references are what it
    # aggregated. A worker keeps no transition ledger, so this list is the only
    # thing behind "2 runs" -- and a reference the export dropped is counted
    # rather than silently shortening the list.
    session = session!("receipt-runs")
    record!(session, fixture(@filtered))

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    receipt = card.network.receipt

    assert receipt.run_count.value == 2
    assert receipt.omitted_run_references.value == 0
    assert [older, newest] = receipt.runs
    assert older.run_id == "run-2b91"
    assert newest.run_id == "run-7f3a"
    assert newest.gateway_epoch == "epoch-1"
    assert newest.completeness == "complete"

    # Final and complete are independent: this receipt is provisional and
    # partial, and its own loss is what makes the totals lower bounds.
    refute receipt.final?
    refute receipt.complete?
    assert receipt.loss.unknown?
    assert receipt.loss.reasons == ["counter_overflow"]

    # The collector's alert crosses as a row with its cause, and the export
    # bound that dropped one is counted rather than hidden.
    assert [alert] = card.network.alerts
    assert alert.category == "collector_health"
    assert alert.reason == "socket_sample_lag"
    refute alert.terminal?
    assert card.network.omitted_alerts.value == 1
  end

  test "an unmeasured counter reads as not recorded, never as zero traffic" do
    session = session!("counters")
    record!(session, fixture(@filtered))

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    counters = card.network.counters.values

    # The exact 64-bit value has to survive the wire, the database and the
    # projection without being rounded by anything on the way.
    assert counters["denied_packets"].value == 18_446_744_073_709_551_615
    assert counters["denied_packets"].known?

    refute counters["maintenance_sent_bytes"].known?
    assert counters["maintenance_sent_bytes"].value == nil
    assert counters["maintenance_sent_bytes"].label == "Not recorded"
  end

  test "a withheld destination is distinguishable from one nobody observed" do
    session = session!("withheld")
    record!(session, fixture(@filtered))

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert [denial] = card.network.denials

    assert denial.destination == %{state: :withheld, name: nil}
    assert denial.basis == "tls"
    assert denial.reason == "no_matching_rule"

    assert [connection] = card.network.connections
    assert connection.destination == %{state: :withheld, name: nil}
    refute card.network.destinations_disclosed?
  end

  test "an included projection names the destination and the rule it matched" do
    session = session!("included")

    disclosed =
      fixture(@filtered, %{
        "network" => %{
          "access" => %{
            "projection" => "destinations-included",
            "requested" => ["example.com tls/443"],
            "effective" => ["example.com tls/443"]
          },
          "observation" => %{
            "projection" => "destinations-included",
            "denials" => [
              fixture(@filtered)["network"]["observation"]["denials"]
              |> hd()
              |> Map.merge(%{"destination" => "blocked.example", "destination_withheld" => false})
            ],
            "connections" => [
              fixture(@filtered)["network"]["observation"]["connections"]
              |> hd()
              |> Map.merge(%{
                "destination" => "api.example.com",
                "destination_withheld" => false,
                "rule_id" => "rule-1"
              })
            ]
          }
        }
      })

    record!(session, disclosed)

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert card.access.destinations_disclosed?
    assert card.access.requested == ["example.com tls/443"]
    assert [%{destination: %{state: :disclosed, name: "blocked.example"}}] = card.network.denials

    assert [%{destination: %{state: :disclosed, name: "api.example.com"}}] =
             card.network.connections
  end

  test "a session that never ran filtered says so instead of showing an empty network" do
    session = session!("open")

    record!(
      session,
      fixture(@open, %{"session_id" => "remote_01j9zq3f8m0c7e6kq9y2s4x1nt"})
    )

    assert [card] = WorkerEvidence.for_episode(session.episode_id)

    assert card.access.headline == "Open"
    assert card.access.availability.state == :not_applicable
    assert card.network.availability.state == :not_applicable
    assert card.network.counters.values == %{}
    assert card.network.receipt.runs == []
    assert card.task.state == :unbound

    # Nothing observed is not a measured zero, and no enforcement observation
    # exists for a session that was never filtered.
    assert card.access.enforcement.state == :not_recorded
  end

  test "an unreadable registry renders its cause, not a quiet session" do
    session = session!("unavailable")

    unreadable =
      fixture(@filtered, %{
        "network" => %{
          "access" => %{
            "status" => "unavailable",
            "reason" => "captured network policy unreadable",
            "projection" => nil,
            "qualification" => nil,
            "requested" => [],
            "effective" => []
          },
          "observation" =>
            fixture(@open)["network"]["observation"]
            |> Map.merge(%{"status" => "unavailable", "reason" => "network registry unreadable"}),
          "receipt" => %{
            "status" => "unavailable",
            "reason" => "network registry unreadable",
            "policy_fingerprint" => nil,
            "authority_digest" => nil,
            "started_at" => nil,
            "closed_at" => nil,
            "finality" => nil,
            "completeness" => nil,
            "scope" => nil,
            "counters" => nil,
            "coverage" => nil,
            "loss" => nil,
            "runs" => [],
            "run_count" => nil,
            "omitted_run_references" => nil,
            "projection" => nil,
            "receipt_digest" => nil,
            "digest_scope" => nil
          }
        }
      })

    record!(session, unreadable)

    assert [card] = WorkerEvidence.for_episode(session.episode_id)

    # The posture survives an unreadable registry: it comes from the session row.
    assert card.access.headline == "Filtered"
    assert card.access.availability.state == :unavailable
    assert card.access.reason == "captured network policy unreadable"
    assert card.network.availability.state == :unavailable
    assert card.network.reason == "network registry unreadable"
    assert card.network.receipt.availability.state == :unavailable
  end

  test "a filtered session with no run is not a session that observed nothing" do
    session = session!("no-run")

    quiet =
      fixture(@filtered, %{
        "network" => %{
          "observation" => fixture(@open)["network"]["observation"] |> Map.put("status", "no_run")
        }
      })

    record!(session, quiet)

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert card.network.availability.state == :not_reached
    assert card.network.availability.label == "Not reached"
    assert card.network.counters.values == %{}
  end

  test "a bound task whose folder is gone keeps its identity and says why" do
    session = session!("task-gone")

    gone =
      fixture(@filtered, %{
        "task" => %{
          "status" => "unavailable",
          "reason" => "bound workspace task is missing",
          "snapshot" => nil
        }
      })

    record!(session, gone)

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert card.task.state == :unavailable
    assert card.task.offer_ref == "offer:episode-42:task"
    assert card.task.reason == "bound workspace task is missing"
    assert card.task.snapshot == nil
  end

  test "a withheld task note is redacted, never shown and never called absent" do
    session = session!("task-note")

    withheld =
      fixture(@filtered, %{
        "task" => %{
          "snapshot" => %{
            "state_note" => %{
              "status" => "withheld",
              "text" => nil,
              "truncated" => false,
              "reason" => "state note contains a likely api token on line 3"
            }
          }
        }
      })

    record!(session, withheld)

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    note = card.task.snapshot.state_note

    assert note.availability.state == :redacted
    assert note.text == nil
    assert note.reason =~ "api token"
  end

  test "an episode nobody captured has no evidence card at all" do
    session = session!("uncaptured")
    assert WorkerEvidence.for_episode(session.episode_id) == []
    assert WorkerEvidence.for_episode(Ecto.UUID.generate()) == []
  end

  test "a stored capture that no longer decodes is an absence with a cause" do
    session = session!("corrupt")
    stored = record!(session, fixture(@filtered))

    Repo.update_all(
      from(row in SessionEvidence, where: row.id == ^stored.id),
      set: [document: ~s({"version":1,"broken":true})]
    )

    assert [card] = WorkerEvidence.for_episode(session.episode_id)
    assert card.state == :unreadable
    assert card.availability.state == :unavailable
    assert card.worker == "worker-a"
  end
end
