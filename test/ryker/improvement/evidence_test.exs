defmodule Ryker.Improvement.EvidenceTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{Evidence, Prompt}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.RoutingExamples

  @workspace "TIMPROVEEVIDENCE"
  @channel "CEVIDENCE"
  @now ~U[2026-09-27 12:00:00.000000Z]
  @bob "The payroll export still runs from the old billing box until Friday."

  # Found in review before it shipped (2026-09-27). Routing examples are off
  # by default, so the analysis reads most routing prompts from the routing
  # attempt itself, which deleting and forgetting never reach. A prompt that
  # quoted Bob's thread message sent his words to the model after he had
  # deleted them, kept them in the analysis run's prompt and, once the
  # candidate was accepted, in the eval case and its download.
  test "a routing prompt is never read once a person deleted a message it quoted" do
    bob =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UBOB",
        text: @bob,
        ts: "1790500100.000100"
      )

    alice =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UALICE",
        text: "Is the staging database healthy?",
        ts: "1790500200.000100",
        thread: "1790500100.000100"
      )

    reply =
      Answers.work_reply!(
        alice,
        "The production database is healthy.",
        "1790500300.000100",
        DateTime.add(@now, 60, :second)
      )

    routed_quoting!(alice, bob)

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:evidence-thumbs-down",
               occurred_at: DateTime.add(@now, 120, :second),
               request: {:episode, reply.episode.id}
             })

    candidate = Improvement.for_request({:episode, reply.episode.id})

    # While nothing it quotes is gone, the analysis reads the attempt's own
    # prompt, and names Bob's message among those forgetting reaches it by.
    evidence = Evidence.gather(candidate)
    assert [%{"kept" => "attempt", "prompt" => prompt}] = evidence.routing
    assert prompt =~ @bob
    assert key(bob) in evidence.message_keys

    Answers.slack_message!(
      workspace: @workspace,
      channel: @channel,
      actor: "UBOB",
      text: "",
      ts: "1790500100.000100",
      thread: "1790500100.000100",
      kind: :delete,
      revision: 2,
      at: DateTime.add(@now, 180, :second)
    )

    evidence = Evidence.gather(Improvement.for_request({:episode, reply.episode.id}))
    assert [%{"kept" => "forgotten", "prompt" => nil, "answer" => nil}] = evidence.routing

    assert "Routing prompts that quoted something a person forgot or deleted." in evidence.omitted

    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "payroll"

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    refute CanonicalJSON.encode!(accepted.case_evidence) =~ "payroll"
  end

  # What routing froze beside the decision about `entry` quotes `quoted` as
  # its thread's root, and the committed attempt's prompt holds its words, as
  # a real routing turn records them.
  defp routed_quoting!(%Entry{} = entry, %Entry{} = quoted) do
    context = %{
      "conversation_context" => %{
        "root" => %{
          "source_message_ref" => quoted.source_item_ref || quoted.native_input_id,
          "text" => @bob
        }
      }
    }

    Repo.update_all(
      from(input in Entry, where: input.id == ^entry.id),
      set: [
        admission_context: context,
        admission_context_fingerprint: CanonicalJSON.digest(context)
      ]
    )

    submission = %{
      "prompt" =>
        "Thread root (UBOB): #{@bob}\nCurrent message (UALICE): Is the staging database healthy?",
      "output_schema" => %{"type" => "object"}
    }

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: entry.execution_generation,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      submission: submission,
      submission_fingerprint: CanonicalJSON.digest(submission),
      execution_target: "codex/terra",
      phase: "committed",
      response: %{"assistant_message" => ~s({"action":"start_episode"})}
    })
  end

  defp key(%Entry{} = entry),
    do:
      RoutingExamples.message_key(
        entry.destination_conversation_ref,
        entry.source_item_ref || entry.native_input_id
      )
end
