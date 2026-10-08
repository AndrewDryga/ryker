defmodule Ryker.Admission.AttemptsTest do
  use Ryker.DataCase, async: true
  alias Ryker.Accounting.Execution
  alias Ryker.Admission.{Attempt, Attempts}
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input

  setup do
    {entry, settings} = claimed_input!()
    %{entry: entry, settings: settings}
  end

  test "transport retries reuse frozen request bytes after instructions change", %{
    entry: entry,
    settings: settings
  } do
    first = %{"prompt" => "Host-authored first request", "output_schema" => %{"type" => "object"}}
    next = %{first | "prompt" => "Later code must not rewrite the same operation"}
    assert {:ok, attempt} = Attempts.prepare(entry, settings)
    assert attempt.submission == nil
    assert {:ok, saved} = Attempts.freeze(entry, first, settings)
    assert {:ok, retried} = Attempts.freeze(entry, next, settings)
    assert retried.id == saved.id
    assert retried.submission == first

    assert Repo.query!(
             "SELECT submission, pg_typeof(submission)::text FROM admission_attempts WHERE id = $1",
             [Ecto.UUID.dump!(saved.id)]
           ).rows ==
             [[Ryker.CanonicalJSON.encode!(first), "text"]]

    assert Repo.aggregate(Attempt, :count) == 1
  end

  test "an expired executor cannot replace a newer generation's evidence", %{
    entry: entry,
    settings: settings
  } do
    assert {:ok, _} = Attempts.prepare(entry, settings)

    assert {:ok, _} =
             Inbox.defer_after_terminal(
               Inbox.ref(entry),
               settings.lease_ref,
               settings.now.(),
               0,
               "failed",
               "Confirmed terminal turn"
             )

    {:ok, claim} = Inbox.claim_next("new-slot", settings.now.(), 60)

    assert Attempts.observe(entry, "provider_running", %{}, settings) ==
             {:error, :admission_attempt_lease_lost}

    assert {:ok, current} =
             Attempts.prepare(claim.entry, %{settings | lease_ref: claim.lease_ref})

    assert current.generation == 2
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "admission usage is counted before an episode exists and survives a sparse terminal poll",
       %{entry: entry, settings: settings} do
    settings = Map.put(settings, :execution_target, "codex:gpt-5.6-terra/medium")

    remote = %{
      "id" => "admission-cost",
      "state" => "running",
      "usage" => %{
        "input_tokens" => 1200,
        "output_tokens" => 300,
        "cost_recorded" => true,
        "cost_usd" => 0.0125
      }
    }

    assert Attempts.observe_turn(entry, remote, settings) == :ok

    assert Attempts.observe_turn(entry, %{"id" => remote["id"], "state" => "failed"}, settings) ==
             :ok

    row = Repo.one!(Ryker.Accounting.Execution)
    assert row.kind == "admission"
    assert row.episode_id == nil
    assert row.status == "failed"
    assert row.usage_input_tokens == 1200
    assert row.usage_cost_recorded
    assert Repo.aggregate(Execution.Query.ledger(nil), :count) == 1
  end

  # Activity says "Routing" while a message is being routed, and its page
  # shows each phase. Until 2026-09-26 both waited on a trigger's NOTIFY and a
  # five-second poll; the context now says so itself once the phase commits.
  test "each routing phase a message reaches is announced to the pages showing it", %{
    entry: entry,
    settings: settings
  } do
    id = entry.id
    :ok = Inbox.subscribe_input(id)

    assert {:ok, _attempt} = Attempts.prepare(entry, settings)
    assert_received {:input_updated, ^id}

    assert Attempts.observe(entry, "provider_running", %{}, settings) == :ok
    assert_received {:input_updated, ^id}
  end

  defp claimed_input! do
    now = DateTime.utc_now()

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Show this request"},
        event_kind: :message,
        event_ref: Ecto.UUID.generate(),
        message_ref: "1787832000.000100",
        occurred_at: now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TB509DF5B0F14"
      })

    {:ok, %{entry: recorded}} = Inbox.record(input)
    {:ok, claim} = Inbox.claim_next("test-slot", now, 60)
    assert claim.entry.id == recorded.id

    {claim.entry,
     %{
       lease_ref: claim.lease_ref,
       now: fn -> now end,
       policy: "admission-test",
       policy_digest: String.duplicate("a", 64)
     }}
  end
end
