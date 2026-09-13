defmodule Ryker.CoopFleet.SessionEvidenceDocumentTest do
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.SessionEvidenceDocument, as: Document

  # These are the exact bytes Coop's own exporter test writes
  # (internal/workerproto/testdata/session_evidence*.json). They are the producer
  # half of this contract: a rename on either side fails here, not in production.
  @filtered Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)
  @open Path.expand("../../../testdata/protocol/coop-session-evidence-open-v1.json", __DIR__)

  defp filtered, do: @filtered |> File.read!() |> Jason.decode!()
  defp open_session, do: @open |> File.read!() |> Jason.decode!()

  test "the versioned golden carries a filtered posture, a sealed run and a bound task" do
    assert {:ok, evidence} = Document.decode(File.read!(@filtered))

    assert evidence["session_id"] == "remote_01j9zq3f8m0c7e6kq9y2s4x1nt"
    assert evidence["state"] == "open"
    assert evidence["network"]["mode"] == "filtered"
    assert evidence["network"]["access"]["status"] == "captured"
    assert evidence["network"]["access"]["projection"] == "destinations-withheld"

    observation = evidence["network"]["observation"]
    assert observation["status"] == "observed"
    assert observation["freshness"] == "terminal"
    assert observation["run_id"] == "run-7f3a"
    assert observation["sealed"]

    # Above 2^53: the exact value has to survive as a string, not a float.
    assert observation["counters"]["denied_packets"] == "18446744073709551615"

    assert String.to_integer(observation["counters"]["denied_packets"]) ==
             18_446_744_073_709_551_615

    assert evidence["network"]["receipt"]["status"] == "available"
    assert evidence["network"]["receipt"]["finality"] == "provisional"
    assert evidence["task"]["status"] == "bound"
    assert evidence["task"]["snapshot"]["state"] == "in_progress"

    labels = Enum.map(evidence["task"]["snapshot"]["checklist"], & &1["label"])
    assert "Run make dev-check" in labels
  end

  test "an unmeasured counter stays unknown rather than becoming zero" do
    {:ok, evidence} = Document.decode(File.read!(@filtered))
    counters = evidence["network"]["observation"]["counters"]

    assert counters["maintenance_sent_bytes"] == nil
    assert counters["maintenance_received_bytes"] == nil
    refute Map.get(counters, "maintenance_sent_bytes") == "0"
  end

  test "an open session reports not filtered and unbound instead of empty evidence" do
    assert {:ok, evidence} = Document.decode(File.read!(@open))

    assert evidence["network"]["mode"] == "open"
    assert evidence["network"]["fingerprint"] == nil
    assert evidence["network"]["access"]["status"] == "not_filtered"
    assert evidence["network"]["observation"]["status"] == "not_filtered"
    assert evidence["network"]["receipt"]["status"] == "not_filtered"
    assert evidence["task"]["status"] == "unbound"
    assert evidence["task"]["snapshot"] == nil
  end

  test "a withheld projection may not carry a destination, a rule or a policy rule text" do
    document = filtered()

    leaks = [
      {put_in(document, ~w(network observation denials), [
         document["network"]["observation"]["denials"]
         |> hd()
         |> Map.put("destination", "api.example.com")
       ]), :denial_destination},
      {put_in(document, ~w(network observation connections), [
         document["network"]["observation"]["connections"]
         |> hd()
         |> Map.put("rule_id", "rule-1")
       ]), :connection_rule_id},
      {put_in(document, ~w(network access requested), ["example.com tls/443"]),
       :access_projection}
    ]

    Enum.each(leaks, fn {leaky, field} ->
      assert {:error, {:invalid_coop_session_evidence, ^field}} = Document.validate(leaky)
    end)
  end

  test "an included projection may not also claim the destination was withheld" do
    document =
      filtered()
      |> put_in(~w(network observation projection), "destinations-included")
      |> put_in(~w(network access projection), "destinations-included")

    assert {:error, {:invalid_coop_session_evidence, :denial_destination}} =
             Document.validate(document)
  end

  test "a section that says it read nothing may not carry evidence" do
    document = filtered()

    invalid = [
      {put_in(document, ~w(network observation status), "no_run"), :observation_detail},
      {put_in(document, ~w(network receipt status), "unavailable")
       |> put_in(~w(network receipt reason), "registry unreadable"), :receipt_detail},
      {put_in(document, ~w(task status), "unbound"), :task_detail}
    ]

    Enum.each(invalid, fn {document, field} ->
      assert {:error, {:invalid_coop_session_evidence, ^field}} = Document.validate(document)
    end)
  end

  test "an unavailable section must name its cause" do
    document = filtered()

    Enum.each(
      [
        {~w(network access), :access_reason},
        {~w(network observation), :observation_reason},
        {~w(network receipt), :receipt_reason}
      ],
      fn {path, field} ->
        stripped =
          document
          |> put_in(path ++ ["status"], "unavailable")
          |> put_in(path ++ ["reason"], nil)

        assert {:error, {:invalid_coop_session_evidence, ^field}} = Document.validate(stripped)
      end
    )
  end

  test "malformed evidence fails before any durable write" do
    document = filtered()

    # A version this build does not speak is its own answer: "a newer worker
    # exported something we cannot read" is not "a worker exported nonsense".
    assert {:error, {:unsupported_coop_session_evidence, :version}} =
             Document.validate(Map.put(document, "version", 2))

    invalid = [
      {Map.put(document, "revision", 0), :revision},
      {Map.put(document, "state", "parked"), :state},
      {Map.put(document, "extra", true), :fields},
      {put_in(document, ~w(network mode), "maybe"), :network_mode},
      {put_in(document, ~w(network fingerprint), nil), :network_fingerprint},
      {put_in(document, ~w(network observation counters sent_bytes), "-1"), :counter},
      {put_in(document, ~w(network observation counters sent_bytes), "01"), :counter},
      {put_in(document, ~w(network observation counters sent_bytes), "18446744073709551616"),
       :counter},
      {put_in(document, ~w(network observation coverage proxy_bytes status), "guessed"),
       :coverage_status},
      {put_in(document, ~w(network observation run_id), nil), :observation_run_id},
      {put_in(document, ~w(network observation omitted_denials), -1), :omitted_denials},
      {put_in(document, ~w(network receipt finality), "final"), :receipt_finality},
      {put_in(document, ~w(network receipt digest_scope), "destinations-included"),
       :receipt_digest_scope},
      {put_in(document, ~w(task draft_sha256), "short"), :task_draft_sha256},
      {put_in(document, ~w(task snapshot state), "someday"), :task_state},
      {put_in(document, ~w(task snapshot files), []), :task_files},
      {put_in(document, ~w(task snapshot state_note text), nil), :task_note_text}
    ]

    Enum.each(invalid, fn {document, field} ->
      assert {:error, {:invalid_coop_session_evidence, field}} == Document.validate(document),
             "expected #{inspect(field)} for #{inspect(Map.keys(document))}"
    end)
  end

  test "a bound task keeps its identity when its folder has gone" do
    document =
      filtered()
      |> put_in(~w(task status), "unavailable")
      |> put_in(~w(task reason), "bound workspace task is missing")
      |> put_in(~w(task snapshot), nil)

    assert {:ok, evidence} = Document.validate(document)
    assert evidence["task"]["offer_ref"] == "offer:episode-42:task"
    assert evidence["task"]["snapshot"] == nil
  end

  test "the content fingerprint ignores the capture time and nothing else" do
    {:ok, first} = Document.decode(File.read!(@filtered))
    later = Map.put(first, "captured_at", "2026-09-11T15:00:00Z")
    changed = put_in(first, ~w(task snapshot state), "done")

    assert Document.content_fingerprint(first) == Document.content_fingerprint(later)
    assert Document.content_fingerprint(first) != Document.content_fingerprint(changed)
    assert Document.content_fingerprint(first) != Document.content_fingerprint(open_session())
  end

  test "an oversized or non-JSON document is refused without decoding" do
    assert Document.decode("") == {:error, {:invalid_coop_session_evidence, :document}}
    assert Document.decode("not json") == {:error, {:invalid_coop_session_evidence, :json}}
    assert Document.decode("[]") == {:error, {:invalid_coop_session_evidence, :document}}

    assert Document.decode(String.duplicate("x", 512 * 1_024 + 1)) ==
             {:error, {:invalid_coop_session_evidence, :document}}
  end
end
