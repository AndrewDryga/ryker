defmodule Ryker.Flywheel.LedgerTest do
  use Ryker.DataCase, async: false
  alias Ryker.Flywheel
  alias Ryker.Flywheel.{Finding, Receipt, Run}

  @from "2026-10-01T00:00:00.000000Z"
  @until "2026-10-02T00:00:00.000000Z"

  test "a failed source remains a gap while another source advances" do
    run = start!()
    review_empty!(run, "logs")

    assert {:ok, _run} =
             command(run, "gap", %{
               "source" => "metrics",
               "status" => "unavailable",
               "reason" => "No retained metrics"
             })

    assert {:ok, %{"status" => "partial"}} = command(run, "finish")

    assert {:ok, next} =
             Flywheel.execute(%{
               "action" => "start",
               "request_ref" => "second",
               "mode" => "suggest",
               "since_last" => true,
               "until" => "2026-10-04T00:00:00.000000Z",
               "sources" => ["logs", "metrics"],
               "policy" => policy()
             })

    assert next["progress"]["metrics"]["from"] == @from
    assert next["progress"]["logs"]["from"] == @from
    assert next["progress"]["logs"]["status"] == "pending"
  end

  test "an interrupted pass resumes with a new lease and refuses the old writer" do
    run = start!()

    assert {:error, :flywheel_run_busy} ==
             Flywheel.execute(%{"action" => "resume", "run_id" => run["id"]})

    assert {:ok, resumed} =
             Flywheel.execute(%{
               "action" => "resume",
               "run_id" => run["id"],
               "lease_ref" => run["lease_ref"]
             })

    refute resumed["lease_ref"] == run["lease_ref"]
    assert {:error, :flywheel_lease_lost} == command(run, "heartbeat")
    assert {:ok, _run} = command(resumed, "heartbeat")
  end

  test "findings and reviewed versions commit together and a changed page refuses stale analysis" do
    run = start!()
    page = page([record("event", "one")])
    assert {:ok, first} = command(run, "stage", %{"source" => "logs", "page" => page})
    changed = page([record("event", "two")])
    assert {:ok, second} = command(run, "stage", %{"source" => "logs", "page" => changed})

    assert {:error, :flywheel_page_changed} ==
             command(run, "review", %{
               "source" => "logs",
               "digest" => first["digest"],
               "findings" => []
             })

    invalid = proposal("retry-loop", "ryker", "one")

    assert {:error, :flywheel_evidence_not_reviewed} ==
             command(run, "review", %{
               "source" => "logs",
               "digest" => second["digest"],
               "findings" => [invalid]
             })

    assert Repo.aggregate(Receipt, :count) == 0
    assert Repo.aggregate(Finding, :count) == 0
    valid = proposal("retry-loop", "ryker", "two")

    assert {:ok, _result} =
             command(run, "review", %{
               "source" => "logs",
               "digest" => second["digest"],
               "findings" => [valid]
             })

    assert Repo.aggregate(Receipt, :count) == 1
    assert Repo.aggregate(Finding, :count) == 1
  end

  test "suggest mode requires selection and a user prerequisite never enters the runnable list" do
    run = start!()
    finding = finding!(run, "both")
    assert {:error, :flywheel_user_selection_required} == decide(run, finding, "select")

    assert {:ok, %{"status" => "waiting_user"}} =
             decide(run, finding, "select", %{"approved" => true})

    assert {:error, :flywheel_task_not_ready} == decide(run, finding, "start")
    assert {:ok, %{"findings" => report}} = Flywheel.execute(%{"action" => "report"})
    assert report["ready"] == []
    assert length(report["for_you"]) == 1
    assert {:ok, %{"status" => "ready"}} = decide(run, finding, "user_done")
    assert {:ok, %{"status" => "in_progress"}} = decide(run, finding, "start")
  end

  test "automatic work honors its allowed kinds and task count" do
    run = start!("auto", %{policy() | "max_tasks" => 1, "allowed_kinds" => ["code"]})

    {:ok, staged} =
      command(run, "stage", %{"source" => "logs", "page" => page([record("event", "one")])})

    proposals = [
      proposal("first", "ryker", "one"),
      proposal("second", "ryker", "one"),
      Map.put(proposal("settings", "ryker", "one"), "kind", "settings")
    ]

    {:ok, %{"findings" => [finding, second, settings]}} =
      command(run, "review", %{
        "source" => "logs",
        "digest" => staged["digest"],
        "findings" => proposals
      })

    assert {:error, :flywheel_kind_not_authorized} == decide(run, settings, "select")
    assert {:ok, %{"status" => "ready"}} = decide(run, finding, "select")
    assert {:error, :flywheel_budget_exhausted} == decide(run, second, "select")
  end

  test "deployment leaves the outcome pending and no traffic cannot prove improvement" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    assert {:ok, _finding} = decide(run, finding, "select")
    assert {:ok, _finding} = decide(run, finding, "start")
    followup = DateTime.to_iso8601(DateTime.add(Repo.now!(), 7, :day))

    assert {:ok, %{"status" => "shipped", "outcome" => nil}} =
             decide(run, finding, "ship", %{
               "version" => "0.1.0-g1234567",
               "followup_at" => followup
             })

    outcome = %{
      "verdict" => "improved",
      "version" => "0.1.0-g1234567",
      "comparison" => "No retries",
      "guardrails" => "Completion unchanged",
      "requests" => 0,
      "evidence" => [identity("one")]
    }

    assert {:error, :flywheel_insufficient_traffic} ==
             decide(run, finding, "outcome", %{"outcome" => outcome, "followup_at" => followup})
  end

  test "processing an episode does not write human ratings" do
    run = start!()
    review_empty!(run, "logs")
    assert Repo.aggregate(Ryker.Operator.EpisodeReview, :count) == 0
  end

  test "missing sources prevent claiming a finished pass" do
    run = start!()
    assert {:error, :flywheel_sources_pending} == command(run, "finish")
    assert Repo.aggregate(Run, :count) == 1
  end

  test "the same request key cannot silently change the selected period" do
    run = start!()

    request = %{
      "action" => "start",
      "request_ref" => "pass",
      "mode" => "suggest",
      "from" => "2026-09-01T00:00:00.000000Z",
      "until" => @until,
      "sources" => ["logs", "metrics"],
      "policy" => policy()
    }

    assert Flywheel.execute(request) == {:error, :flywheel_request_conflict}
    assert command(run, "finish") == {:error, :flywheel_sources_pending}
  end

  test "a retried review is one receipt and does not recreate a task" do
    run = start!()

    {:ok, staged} =
      command(run, "stage", %{"source" => "logs", "page" => page([record("event", "one")])})

    review = %{
      "source" => "logs",
      "digest" => staged["digest"],
      "findings" => [proposal("retry-loop", "ryker", "one")]
    }

    assert {:ok, _result} = command(run, "review", review)
    assert {:ok, %{"replayed" => true}} = command(run, "review", review)
    assert Repo.aggregate(Receipt, :count) == 1
    assert Repo.aggregate(Finding, :count) == 1
  end

  test "dismissal survives another pass and old evidence cannot reopen it" do
    run = start!()
    finding = finding!(run, "ryker")
    assert {:ok, _finding} = decide(run, finding, "dismiss")

    assert decide(run, finding, "reopen", %{
             "new_evidence" => identity("one"),
             "material_change" => true
           }) ==
             {:error, :flywheel_material_change_required}
  end

  test "deferral need not create a reminder the user did not request" do
    run = start!()
    finding = finding!(run, "user")
    assert {:ok, %{"status" => "deferred", "revisit_at" => nil}} = decide(run, finding, "defer")

    assert {:ok, %{"findings" => %{"followups" => []}}} =
             Flywheel.execute(%{"action" => "report"})
  end

  test "a recorded cost is idempotent and exhausts the automatic work budget" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    charge = %{"source" => "logs", "reference" => "analysis-one", "amount_usd" => "20.00"}
    assert {:ok, first} = command(run, "charge", charge)
    assert {:ok, second} = command(run, "charge", charge)
    assert first["progress"] == second["progress"]
    assert decide(run, finding, "select") == {:error, :flywheel_budget_exhausted}
  end

  test "elapsed time does not strand authorized work or erase its recorded policy" do
    # A two-hour cutoff stopped an approved recovery with work still outstanding.
    # Old run documents keep that historical field; time no longer revokes work.
    run = start!("auto")
    finding = finding!(run, "ryker")
    recorded_policy = Map.put(run["policy"], "max_minutes", 120)

    run["id"]
    |> Run.Query.by_id()
    |> Repo.fetch!()
    |> Ecto.Changeset.change(
      inserted_at: DateTime.add(Repo.now!(), -3, :hour),
      policy: recorded_policy
    )
    |> Repo.update!()

    assert {:ok, %{"status" => "ready"}} = decide(run, finding, "select")
    assert {:ok, %{"status" => "in_progress"}} = decide(run, finding, "start")
    assert Repo.fetch!(Run.Query.by_id(run["id"])).policy == recorded_policy
  end

  test "selected automatic work cannot start after its budget is exhausted" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    assert {:ok, _finding} = decide(run, finding, "select")

    assert {:ok, _run} =
             command(run, "charge", %{
               "source" => "logs",
               "reference" => "analysis",
               "amount_usd" => "20.00"
             })

    assert decide(run, finding, "start") == {:error, :flywheel_budget_exhausted}
  end

  test "changed bodies invalidate pending analysis even when a connector reuses a version" do
    run = start!()

    {:ok, first} =
      command(run, "stage", %{"source" => "logs", "page" => page([record("event", "one")])})

    changed = Map.put(record("event", "one"), "data", %{"count" => 3})
    {:ok, _second} = command(run, "stage", %{"source" => "logs", "page" => page([changed])})

    assert command(run, "review", %{
             "source" => "logs",
             "digest" => first["digest"],
             "findings" => []
           }) ==
             {:error, :flywheel_page_changed}
  end

  test "a repeated finding keeps its decision while a new record version is analyzed" do
    run = start!()
    finding = finding!(run, "ryker")
    assert {:ok, _finding} = decide(run, finding, "dismiss")
    review_empty!(run, "metrics")
    assert {:ok, _run} = command(run, "finish")

    request = %{
      "action" => "start",
      "request_ref" => "later",
      "mode" => "suggest",
      "from" => @from,
      "until" => @until,
      "sources" => ["logs"],
      "policy" => policy()
    }

    {:ok, later} = Flywheel.execute(request)

    {:ok, staged} =
      command(later, "stage", %{
        "source" => "logs",
        "page" => page([record("event", "one"), record("event", "two")])
      })

    assert length(staged["page"]["records"]) == 1

    {:ok, %{"findings" => [observed]}} =
      command(later, "review", %{
        "source" => "logs",
        "digest" => staged["digest"],
        "findings" => [proposal("retry-loop", "ryker", "two")]
      })

    assert observed["status"] == "dismissed"
    assert observed["id"] == finding["id"]

    assert {:ok, %{"status" => "proposed"}} =
             decide(later, observed, "reopen", %{
               "new_evidence" => identity("two"),
               "material_change" => true
             })
  end

  test "local source collection uses bounded pages and timestamp ties do not lose records" do
    now = Repo.now!()
    at = DateTime.add(now, -10, :second)

    for revision <- 1..101 do
      Repo.insert!(%Ryker.Settings.Edit{
        domain: :work,
        revision: revision,
        actor_ref: "test",
        fingerprint: String.duplicate("a", 64),
        inserted_at: at
      })
    end

    {:ok, run} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "settings",
        "mode" => "suggest",
        "from" => DateTime.to_iso8601(DateTime.add(at, -1, :second)),
        "until" => DateTime.to_iso8601(now),
        "sources" => ["settings_history"],
        "policy" => policy()
      })

    {:ok, first} = command(run, "collect", %{"source" => "settings_history"})
    assert length(first["page"]["records"]) == 100
    refute first["page"]["complete"]

    {:ok, _result} =
      command(run, "review", %{
        "source" => "settings_history",
        "digest" => first["digest"],
        "findings" => []
      })

    {:ok, second} = command(run, "collect", %{"source" => "settings_history"})
    assert length(second["page"]["records"]) == 1
    assert second["page"]["complete"]

    {:ok, _result} =
      command(run, "review", %{
        "source" => "settings_history",
        "digest" => second["digest"],
        "findings" => []
      })

    assert Repo.aggregate(Receipt, :count) == 101
  end

  test "every local inventory reads its actual schema without a model or source bodies" do
    {:ok, catalog} = Flywheel.execute(%{"action" => "catalog"})

    {:ok, run} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "catalog",
        "mode" => "suggest",
        "from" => @from,
        "until" => @until,
        "sources" => catalog["local"],
        "policy" => policy()
      })

    for source <- catalog["local"] do
      assert {:ok, result} = command(run, "collect", %{"source" => source})
      assert result["page"]["records"] == []
    end
  end

  test "the last retained page can leave explicit partial period coverage" do
    run = start!()

    partial =
      Map.merge(page([record("event", "one")]), %{
        "coverage" => "partial",
        "limitation" => "Older logs rotated away"
      })

    assert {:ok, staged} = command(run, "stage", %{"source" => "logs", "page" => partial})

    assert {:ok, result} =
             command(run, "review", %{
               "source" => "logs",
               "digest" => staged["digest"],
               "findings" => []
             })

    assert result["run"]["progress"]["logs"]["status"] == "partial"
    assert result["run"]["progress"]["logs"]["reason"] == "Older logs rotated away"
    assert Repo.aggregate(Receipt, :count) == 1
  end

  test "a second starter cannot inherit the active writer's lease" do
    _run = start!()

    request = %{
      "action" => "start",
      "request_ref" => "pass",
      "mode" => "suggest",
      "from" => @from,
      "until" => @until,
      "sources" => ["logs", "metrics"],
      "policy" => policy()
    }

    assert Flywheel.execute(request) == {:error, :flywheel_run_busy}
  end

  test "a source cannot change its query between acknowledged pages" do
    run = start!()
    first = Map.merge(page([]), %{"complete" => false, "next_cursor" => "second"})
    {:ok, staged} = command(run, "stage", %{"source" => "logs", "page" => first})

    {:ok, _result} =
      command(run, "review", %{"source" => "logs", "digest" => staged["digest"], "findings" => []})

    changed = Map.merge(page([]), %{"cursor" => "second", "query" => "A different project"})

    assert command(run, "stage", %{"source" => "logs", "page" => changed}) ==
             {:error, :flywheel_source_query_changed}
  end

  test "carried work needs this run's authorization and narrowed kinds remain enforced" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    {:ok, _} = decide(run, finding, "select")
    review_empty!(run, "metrics")
    {:ok, _} = command(run, "finish")
    later = later!("auto", %{policy() | "allowed_kinds" => ["settings"]})
    assert decide(later, finding, "start") == {:error, :flywheel_selection_required}

    assert decide(later, finding, "link", %{"task_id" => "2026-10-25-old-code"}) ==
             {:error, :flywheel_selection_required}

    assert decide(later, finding, "select") == {:error, :flywheel_kind_not_authorized}
  end

  test "repeated selection does not consume another task slot" do
    run = start!("auto", %{policy() | "max_tasks" => 1})
    finding = finding!(run, "ryker")
    {:ok, first} = decide(run, finding, "select")
    assert {:ok, repeated} = decide(run, finding, "select")
    assert repeated["history"] == first["history"]
  end

  test "a duplicate task link returns a refusal and preserves both findings" do
    run = start!("auto")

    {:ok, staged} =
      command(run, "stage", %{"source" => "logs", "page" => page([record("event", "one")])})

    {:ok, %{"findings" => [first, second]}} =
      command(run, "review", %{
        "source" => "logs",
        "digest" => staged["digest"],
        "findings" => [proposal("first", "ryker", "one"), proposal("second", "ryker", "one")]
      })

    for finding <- [first, second], do: decide(run, finding, "select")
    link = %{"task_id" => "2026-10-25-one-task"}
    assert {:ok, _} = decide(run, first, "link", link)
    assert decide(run, second, "link", link) == {:error, :flywheel_task_link_conflict}
    assert Repo.get!(Finding, second["id"]).task_id == nil
  end

  test "renewing a lease never shortens its existing expiry" do
    run = start!()
    expires = DateTime.add(Repo.now!(), 3600, :second)

    run["id"]
    |> then(&Repo.get!(Run, &1))
    |> Ecto.Changeset.change(lease_expires_at: expires)
    |> Repo.update!()

    {:ok, renewed} = command(run, "heartbeat")
    assert renewed["lease_expires_at"] == DateTime.to_iso8601(expires)
  end

  test "pending outcomes remain visible and a regression starts a fresh audited task cycle" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    {:ok, _} = decide(run, finding, "select")
    {:ok, _} = decide(run, finding, "link", %{"task_id" => "2026-10-25-first-fix"})
    {:ok, _} = decide(run, finding, "start")
    followup = DateTime.to_iso8601(DateTime.add(Repo.now!(), 1, :day))

    {:ok, _} =
      decide(run, finding, "ship", %{"version" => "revision-one", "followup_at" => followup})

    {:ok, report} = Flywheel.execute(%{"action" => "report"})
    assert length(report["findings"]["pending_outcomes"]) == 1
    at = DateTime.add(Repo.now!(), -60, :second)

    finding["id"]
    |> then(&Repo.get!(Finding, &1))
    |> Ecto.Changeset.change(shipped_at: at)
    |> Repo.update!()

    outcome = %{
      "verdict" => "regressed",
      "version" => "revision-one",
      "from" => DateTime.to_iso8601(at),
      "until" => DateTime.to_iso8601(Repo.now!()),
      "requests" => 10,
      "comparison" => "More repeats per eligible request",
      "guardrails" => "Delivery unchanged",
      "evidence" => [identity("one")]
    }

    {:ok, _} = decide(run, finding, "outcome", %{"outcome" => outcome, "followup_at" => followup})
    {:ok, selected} = decide(run, finding, "select")
    assert selected["task_id"] == nil
    assert List.last(selected["history"])["before"]["outcome"] == outcome
    assert List.last(selected["history"])["before"]["deployed_version"] == "revision-one"
    assert List.last(selected["history"])["before"]["task_id"] == "2026-10-25-first-fix"
    assert {:ok, _} = decide(run, finding, "link", %{"task_id" => "2026-10-25-second-fix"})
  end

  test "verified followups become due and preserve the prior result" do
    run = start!()
    finding = finding!(run, "ryker")
    at = DateTime.add(Repo.now!(), -60, :second)

    finding["id"]
    |> then(&Repo.get!(Finding, &1))
    |> Ecto.Changeset.change(status: :verified, revisit_at: at)
    |> Repo.update!()

    {:ok, report} = Flywheel.execute(%{"action" => "report"})
    assert Enum.map(report["findings"]["followups"], & &1["id"]) == [finding["id"]]
  end

  test "explicitly closed expired history remains visible without pinning every later pass" do
    {:ok, run} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "expired-first",
        "mode" => "suggest",
        "from" => @from,
        "until" => "2026-10-04T00:00:00.000000Z",
        "sources" => ["logs", "metrics"],
        "policy" => policy()
      })

    assert {:ok, _} =
             command(run, "gap", %{
               "source" => "logs",
               "status" => "expired",
               "closed" => true,
               "reason" => "Confirmed log rotation removed this history"
             })

    review_empty!(run, "metrics")
    {:ok, _} = command(run, "finish")
    later = later!("suggest", policy(), "2026-10-05T00:00:00.000000Z")
    assert later["progress"]["logs"]["from"] == "2026-10-03T00:00:00.000000Z"
    review_empty!(later, "logs")
    review_empty!(later, "metrics")
    {:ok, _} = command(later, "finish")

    {:ok, latest} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "third",
        "mode" => "suggest",
        "since_last" => true,
        "until" => "2026-10-07T00:00:00.000000Z",
        "sources" => ["logs", "metrics"],
        "policy" => policy()
      })

    assert latest["progress"]["logs"]["from"] == "2026-10-04T00:00:00.000000Z"
    assert Repo.get!(Run, run["id"]).progress["logs"]["status"] == "expired"
  end

  test "a deliberate proposal revision preserves decisions and requires a new selection" do
    run = start!()
    finding = finding!(run, "user")
    {:ok, _} = decide(run, finding, "select", %{"approved" => true})
    replacement = proposal("retry-loop", "ryker", "one")
    {:ok, revised} = decide(run, finding, "revise", %{"replacement" => replacement})
    assert revised["status"] == "proposed"
    assert revised["owner"] == "ryker"
    assert List.last(revised["history"])["before"]["owner"] == "user"
    assert decide(run, revised, "start") == {:error, :flywheel_selection_required}
    assert {:ok, _} = decide(run, revised, "select", %{"approved" => true})
  end

  test "expired gap closure cannot skip a retained continuation page" do
    run = start!()
    first = Map.merge(page([]), %{"complete" => false, "next_cursor" => "retained-page"})
    {:ok, staged} = command(run, "stage", %{"source" => "logs", "page" => first})

    {:ok, _} =
      command(run, "review", %{"source" => "logs", "digest" => staged["digest"], "findings" => []})

    assert command(run, "gap", %{
             "source" => "logs",
             "status" => "expired",
             "closed" => true,
             "reason" => "Older history expired"
           }) == {:error, :invalid_flywheel_gap_closure}
  end

  test "a started investigation can close with no change and no fictional deployment" do
    run = start!("auto")
    finding = finding!(run, "ryker")
    {:ok, _} = decide(run, finding, "select")
    {:ok, _} = decide(run, finding, "start")
    assert {:ok, closed} = decide(run, finding, "close", %{"evidence" => [identity("one")]})
    assert closed["status"] == "dismissed"
    assert closed["deployed_version"] == nil
    assert closed["outcome"]["verdict"] == "no_change"
  end

  defp later!(mode, policy, until \\ @until) do
    {:ok, run} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "later",
        "mode" => mode,
        "since_last" => true,
        "until" => until,
        "sources" => ["logs", "metrics"],
        "policy" => policy
      })

    run
  end

  defp start!(mode \\ "suggest", policy \\ policy()) do
    {:ok, run} =
      Flywheel.execute(%{
        "action" => "start",
        "request_ref" => "pass",
        "mode" => mode,
        "from" => @from,
        "until" => @until,
        "sources" => ["logs", "metrics"],
        "policy" => policy
      })

    run
  end

  defp policy,
    do: %{
      "max_tasks" => 3,
      "max_cost_usd" => "20.00",
      "allowed_kinds" => ["code", "settings", "tools", "user_action"]
    }

  defp command(run, action, extra \\ %{}) do
    Flywheel.execute(
      Map.merge(
        %{"action" => action, "run_id" => run["id"], "lease_ref" => run["lease_ref"]},
        extra
      )
    )
  end

  defp record(ref, version), do: %{"ref" => ref, "version" => version, "data" => %{"count" => 2}}

  defp page(records),
    do: %{
      "records" => records,
      "cursor" => nil,
      "next_cursor" => nil,
      "complete" => true,
      "query" => "all retained test records"
    }

  defp identity(version), do: %{"source" => "logs", "ref" => "event", "version" => version}

  defp proposal(key, owner, version) do
    %{
      "key" => key,
      "owner" => owner,
      "kind" => "code",
      "evidence" => [identity(version)],
      "proposal" => %{
        "title" => "Stop repeated failures",
        "example" => "The same attempt repeats",
        "benefit" => "Less waiting",
        "tradeoffs" => "May stop sooner",
        "change" => "Bound repeated attempts",
        "verification" => "Compare failures per request",
        "baseline" => "Two repeats in the reviewed request",
        "user_action" => if(owner == "ryker", do: nil, else: "Grant read access"),
        "confidence" => "high",
        "priority" => "high"
      }
    }
  end

  defp finding!(run, owner) do
    {:ok, staged} =
      command(run, "stage", %{"source" => "logs", "page" => page([record("event", "one")])})

    {:ok, %{"findings" => [finding]}} =
      command(run, "review", %{
        "source" => "logs",
        "digest" => staged["digest"],
        "findings" => [proposal("retry-loop", owner, "one")]
      })

    finding
  end

  defp review_empty!(run, source) do
    {:ok, staged} = command(run, "stage", %{"source" => source, "page" => page([])})

    {:ok, _reviewed} =
      command(run, "review", %{"source" => source, "digest" => staged["digest"], "findings" => []})
  end

  defp decide(run, finding, decision, extra \\ %{}) do
    command(
      run,
      "decide",
      Map.merge(
        %{
          "finding_id" => finding["id"],
          "decision" => decision,
          "note" => "Reviewed the evidence"
        },
        extra
      )
    )
  end
end
