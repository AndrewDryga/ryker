defmodule Responder.Admission.OccurrenceClaimTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission
  alias Responder.Admission.{Decision, Occurrences}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, CorrelationClaims}
  alias Responder.Ingress.{Inbox, Input}

  @now ~U[2026-09-11 12:00:00.000000Z]

  test "one authenticated occurrence reported twice gets one active owner" do
    # A conversation lock cannot protect an occurrence that arrives in two
    # conversations: each admission holds a different lock, sees an empty
    # candidate set and creates its own active work for the same object.
    first = record!("eval", 4120, "Please review pull request 4120")
    second = record!("eval", 4120, "Reminder: pull request 4120 is still open")

    assert {:ok, result} = admit(first)
    assert result.status == :applied

    owner = CorrelationClaims.owner("github:eval", "github:eval", "github:pull:4120")
    assert owner.episode_id == result.episode.id
    assert owner.lifecycle_state == :active

    assert {:error, {:admission_rejected, :occurrence_claimed, details}} = admit(second)
    assert details[:owner_episode_id] == result.episode.id
  end

  test "a different object in the same repository is its own occurrence" do
    first = record!("eval", 4120, "Please review pull request 4120")
    other = record!("eval", 4121, "Please review pull request 4121")

    assert {:ok, first_result} = admit(first)
    assert {:ok, other_result} = admit(other)
    refute first_result.episode.id == other_result.episode.id
  end

  test "a Slack message reference is a clue, never an exclusive claim" do
    {:ok, input} =
      Responder.Slack.Input.new(%{
        actor: %{kind: :app, ref: "A123"},
        channel_ref: "CDEVOPS",
        content: %{"text" => "Run run-TT4LiosRo6Eh8Rnq needs confirmation"},
        event_kind: :message,
        event_ref: "Ev-1789000000",
        message_ref: "1789000000.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TROUTE"
      })

    assert Occurrences.for_input(input) == []
  end

  test "one recovered run leaves the incident's other run firing" do
    # A rollout reported by two runs looked resolved the moment either one
    # succeeded, so the still-pending half stopped being worked. Each
    # adapter-authenticated run is now its own signal with its own lifecycle.
    {:ok, started} = admit(lifecycle!("deployment-run:a", "pending"))
    {:ok, joined} = continue(lifecycle!("deployment-run:b", "pending"), started.episode)
    assert joined.episode.id == started.episode.id

    {:ok, _recovered} =
      continue(lifecycle!("deployment-run:a", "succeeded"), started.episode)

    assert [
             %{occurrence_ref: "deployment-run:a", lifecycle_state: :terminal},
             %{occurrence_ref: "deployment-run:b", lifecycle_state: :active}
           ] =
             started.episode.id
             |> CorrelationClaims.for_episode()
             |> Enum.sort_by(& &1.occurrence_ref)

    refute CorrelationClaims.all_terminal?(started.episode.id)
  end

  test "a finished episode releases its occurrence so the next report is new work" do
    # The claim fences concurrent active work, not the identity forever: a
    # later comment on a pull request whose episode already finished was
    # rejected until its attempts ran out and an operator had to unblock it.
    {:ok, first} = admit(record!("eval", 5001, "Please review pull request 5001"))

    {:ok, _transition} =
      Episodes.apply(%Command.CancelEpisode{
        cancel_ref: "cancel:#{first.episode.id}",
        episode_key: first.episode.key,
        expected_owner: %{kind: first.episode.owner_kind, ref: first.episode.owner_ref},
        occurred_at: DateTime.add(@now, 60, :second),
        reason: "The author withdrew the request."
      })

    assert [%{status: :retired}] = CorrelationClaims.for_episode(first.episode.id)

    {:ok, second} = admit(record!("eval", 5001, "Reopened: pull request 5001 needs review"))
    refute second.episode.id == first.episode.id
  end

  defp admit(entry) do
    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: @now,
        continuation_window: 30 * 60,
        history_window: 30 * 24 * 60 * 60,
        candidate_limit: 20
      )

    {:ok, decision} =
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "This pull request needs a review.",
        "work_class" => "standard"
      })

    Admission.commit(context, decision, "occurrence-test:#{entry.id}")
  end

  defp continue(entry, episode) do
    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: @now,
        continuation_window: 30 * 60,
        history_window: 30 * 24 * 60 * 60,
        candidate_limit: 20
      )

    candidate = Enum.find(context.candidates, &(&1.episode.id == episode.id))
    assert candidate, "the owning episode was not offered as a candidate"

    {:ok, decision} =
      Decision.parse(%{
        "action" => "continue_episode",
        "episode_ref" => candidate.ref,
        "reaction" => nil,
        "relation" => "same_work",
        "reason" => "This run belongs to the rollout already being tracked.",
        "work_class" => "standard"
      })

    Admission.commit(context, decision, "occurrence-test:#{entry.id}")
  end

  defp lifecycle!(run_ref, state) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :system, ref: "webhook-route:deployments"},
        content: %{
          "event_type" => "responder.publication_lifecycle.v1",
          "payload" => %{
            "environment" => "production",
            "kind" => "deployment",
            "references" => ["release/rollout"],
            "repository" => "responder",
            "run_ref" => run_ref,
            "state" => state,
            "target" => "responder"
          }
        },
        destination: %{
          conversation_ref: "slack:TROUTE:CDEPLOYS",
          thread_ref: nil,
          transport: "slack"
        },
        event_kind: :event,
        event_ref: "lifecycle-event-#{unique}",
        native_input_id: "webhook-item:#{run_ref}:#{state}",
        occurred_at: DateTime.add(@now, unique, :second),
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "webhook", ref: "deployments"},
        source_capabilities: %{
          "publication_lifecycle" => %{
            "environments" => ["production"],
            "kinds" => ["deployment", "terraform"],
            "repositories" => ["responder"],
            "targets" => ["responder"]
          }
        },
        source_item_ref: nil
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp record!(binding, item_id, text) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "octocat"},
        content: %{"text" => text},
        destination: %{
          conversation_ref: "github:#{binding}:repository:99",
          thread_ref: "github:pull:#{item_id}",
          transport: "github"
        },
        event_kind: :message,
        event_ref: "gh-event-#{unique}",
        native_input_id: "github:#{binding}:pull:#{item_id}:comment:#{unique}",
        occurred_at: DateTime.add(@now, unique, :second),
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "github", ref: binding},
        source_capabilities: %{},
        source_item_ref: "github:pull:#{item_id}"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end
end
