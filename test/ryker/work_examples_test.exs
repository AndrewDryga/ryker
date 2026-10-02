defmodule Ryker.WorkExamplesTest do
  @moduledoc """
  Work turns kept for training a model that can do Ryker's work later.

  Andrew, 2026-10-02, of the local routing model: the self-hosted model
  should be "trained not just from routing records but actual work records
  too", to "replace everything we want to replace with self hosting IN LONG
  TERM". On the live install a work turn's briefing averaged 33 KB and its
  turns were half of all input tokens, and everything they produced was
  pruned 30 days after their request finished, so the examples such a model
  needs were being deleted every day. These hold the copy that outlives them,
  and the ways a person removing a message must still win over it.

  Every request here is routed by the real admission executor over a fake
  Coop session and worked through the real Work custody: the briefing frozen,
  a result refused and another accepted, the answer delivered.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1]

  # The executor reads routing's context under the isolation it runs with.
  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission.Executor
  alias Ryker.Feedback
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Observations
  alias Ryker.Retention.Data
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfigurations
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Ryker.Work.{Activity, Custody, DeliveryReceipt, Result, Submission}
  alias Ryker.WorkExamples
  alias Ryker.WorkExamples.{Example, Export}
  alias Ryker.WorkExamples.Feedback, as: KeptFeedback

  @actor "control-plane:local"
  @day 86_400
  @now ~U[2026-10-02 08:00:00.000000Z]
  @workspace "TE5D7C8842D32"
  @channel "C456"
  @conversation "slack:TE5D7C8842D32:C456"
  # A credential Ryker stores, as the assembly hands every one to the copy.
  @stored_secret "stored-credential-value-0123456789"
  @options %{batch_size: 5, redaction_secrets: [@stored_secret], window_seconds: 365 * @day}

  @start_episode ~s({"action":"start_episode","episode_ref":null,"messages":null,"reactions":null,"relation":"unrelated","reason":"The person asks Ryker to find why the staging api is down.","repository":null,"repository_source":null,"work_class":"standard"})
  @target "codex:gpt-5.6-luna/low@default"

  @prompt "Find why the staging api is down. Report what you checked and what you found."
  @schema %{
    "additionalProperties" => false,
    "properties" => %{"message" => %{"type" => "string"}},
    "required" => ["message"],
    "type" => "object"
  }
  @question "The api pod is crash-looping on a missing DATABASE_URL. Should I roll back the last deploy?"

  setup do
    assert {:ok, _settings} = Settings.initialize(@actor)
    :ok
  end

  describe "the copy" do
    # A request is only a useful example once its outcome is known, and a
    # trajectory is only useful whole: a copy taken while the answer waited to
    # be sent would have labelled it as still running.
    test "a settled turn is kept with its briefing, what the worker did, the results refused and accepted, and its outcome" do
      keep_work_examples!()

      work =
        work!("Ev-work-copy", "@ryker why is the staging api down?",
          refused: [
            {Jason.encode!(%{"delivery" => "reply", "message" => "Looking into it."}),
             ["The final result must answer the current request."]}
          ],
          deliver: false
        )

      # The answer waits to be sent: nothing is copied yet.
      assert {:ok, %{copied: 0, forgotten: 0}} = WorkExamples.capture(@options)

      deliver!(work.accepted)
      assert {:ok, %{copied: 1, forgotten: 0}} = WorkExamples.capture(@options)
      example = Repo.one!(Example)

      # The exact briefing, and what was sent beside it.
      assert example.briefing == @prompt
      assert example.output_schema == @schema
      assert example.context["episode_id"] == work.episode_id

      # What the worker did, in order: the tool call with its input and its
      # output (the stored credential it printed redacted), then its note.
      # Starting a call and the provider's liveness say nothing more.
      assert [tool, thought] = example.trajectory
      assert tool["kind"] == "tool.completed"
      assert tool["payload"]["input"] == %{"command" => "kubectl get pods -n staging"}
      assert tool["payload"]["output"] =~ "api-7f9 CrashLoopBackOff"
      refute inspect(example.trajectory) =~ @stored_secret

      assert {thought["kind"], thought["at"], thought["payload"]["text"]} ==
               {"model.thought", "2026-10-02T08:00:03.000000Z",
                "The api pod is crash-looping; reading its events."}

      # The result accepted, and the one refused before it with why.
      assert Jason.decode!(example.result) == %{"delivery" => "reply", "message" => @question}

      assert example.rejected_results == [
               %{
                 "result" => ~s({"delivery":"reply","message":"Looking into it."}),
                 "violations" => ["The final result must answer the current request."]
               }
             ]

      assert example.outcome == %{
               "publication" => nil,
               "request" => "waiting_for_input",
               "turn" => "settled"
             }

      # Where it happened, and the request it belongs to.
      assert example.turn_id == work.turn_id
      assert example.episode_id == work.episode_id
      assert example.conversation_ref == @conversation
      assert example.transport == "slack"
      assert example.execution_mode == :live

      assert example.source_identities == [Observations.source_identity(work.entry)]

      assert @conversation in example.conversation_refs

      # Copied once, however often a pass runs.
      assert {:ok, %{copied: 0, forgotten: 0}} = WorkExamples.capture(@options)
      assert Repo.aggregate(Example, :count) == 1
    end

    test "nothing is copied while keeping work examples is off, even with routing examples on" do
      settings = Settings.fetch!()

      assert {:ok, _saved} =
               Settings.save_retention(
                 %{routing_examples_enabled: true},
                 settings.installation.revision,
                 @actor
               )

      work!("Ev-work-off", "@ryker why is the staging api down?")
      assert {:ok, %{copied: 0, forgotten: 0}} = WorkExamples.capture(@options)
      refute Repo.exists?(Example)
    end

    test "a stored credential in the briefing never reaches the copy" do
      keep_work_examples!()

      work!("Ev-work-secret", "@ryker why is the staging api down?",
        prompt: "Use the bot token #{@stored_secret} to read the channel. " <> @prompt
      )

      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)
      example = Repo.one!(Example)
      refute example.briefing =~ @stored_secret
      assert example.briefing =~ "Find why the staging api is down."
    end
  end

  describe "feedback" do
    # Feedback is kept for the operational horizon and a work example for its
    # own window; an export that joined the feedback table would label every
    # example older than a month as having none.
    test "feedback on the request stays with its example after the feedback itself expires" do
      keep_work_examples!()
      work = work!("Ev-work-feedback", "@ryker why is the staging api down?")
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)

      assert {:ok, %{status: :recorded}} =
               Feedback.record(%{
                 kind: :reaction_added,
                 value: "+1",
                 note: nil,
                 actor_ref: "U0FEEDBACK1",
                 source: "slack",
                 source_ref: "reaction:Ev-work-feedback",
                 occurred_at: DateTime.add(@now, 120, :second),
                 request: {:episode, work.episode_id}
               })

      assert {:ok, 1} = WorkExamples.copy_feedback()
      assert {:ok, 0} = WorkExamples.copy_feedback()
      Repo.delete_all(Signal)

      assert [line] = lines()

      assert [%{"kind" => "reaction_added", "value" => "+1", "category" => "satisfied"}] =
               Jason.decode!(line)["labels"]["feedback"]
    end
  end

  describe "a person forgetting wins" do
    # A work example carries what a person asked; deleting that message must
    # take it back from the copy as it does from routing's.
    test "deleting the message a request was asked in erases its example, before or after the copy" do
      keep_work_examples!()
      copied = work!("Ev-work-delete", "@ryker the staging password is hunter2, check db-1")
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)
      later = work!("Ev-work-delete-2", "@ryker and check db-2 too", message: 2)

      delete_message!("Ev-work-delete-gone", 1)
      assert_erased(copied.turn_id)

      # Deleted before its turn was copied: kept as identity only.
      delete_message!("Ev-work-delete-2-gone", 2)
      assert {:ok, %{copied: 0, forgotten: 1}} = WorkExamples.capture(@options)
      assert_erased(later.turn_id)
    end

    test "deleting a Slack channel erases the work examples from it" do
      keep_work_examples!()
      first = work!("Ev-work-channel", "@ryker why is the staging api down?")
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)

      elsewhere =
        work!("Ev-work-channel-2", "@ryker why is prod slow?", message: 2, channel: "C999")

      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)

      assert {:ok, _deleted} =
               ChannelConfigurations.observe_membership(
                 %{
                   actor_ref: nil,
                   channel_ref: @channel,
                   event_ref: "event:delete-work-examples",
                   kind: :deleted,
                   occurred_at: Repo.now!(),
                   workspace_ref: @workspace
                 },
                 %{default_environment: nil, environments: []}
               )

      assert_erased(first.turn_id)
      assert Repo.get_by!(Example, turn_id: elsewhere.turn_id).briefing == @prompt
    end
  end

  describe "retention" do
    test "an example leaves at its own window, and every one leaves when keeping them is turned off" do
      keep_work_examples!()
      old = work!("Ev-work-old", "@ryker why is the staging api down?")
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)
      recent = work!("Ev-work-recent", "@ryker and prod?", message: 2)
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)

      Repo.update_all(from(e in Example, where: e.turn_id == ^old.turn_id),
        set: [settled_at: DateTime.add(Repo.now!(), -400, :day)]
      )

      assert {:ok, %{work_examples: 1}} = Data.prune(retention(true))
      assert Repo.all(from(e in Example, select: e.turn_id)) == [recent.turn_id]

      assert {:ok, %{work_examples: 1}} = Data.prune(retention(false))
      refute Repo.exists?(Example)
    end
  end

  describe "the setting" do
    test "keeping work examples starts off for a year, and turning it off asks first" do
      settings = Settings.fetch!()
      assert settings.retention.work_examples_enabled == false
      assert settings.retention.work_examples_seconds == 365 * @day

      assert {:ok, kept} =
               Settings.save_retention(
                 %{work_examples_enabled: true, work_examples_seconds: 200 * @day},
                 settings.installation.revision,
                 @actor
               )

      assert {kept.retention.work_examples_enabled, kept.retention.work_examples_seconds} ==
               {true, 200 * @day}

      # Turning it off deletes every one kept, so it asks first.
      assert Settings.save_retention(
               %{work_examples_enabled: false},
               kept.installation.revision,
               @actor
             ) == {:error, :retention_impact_confirmation_required}
    end
  end

  describe "the export" do
    test "each example is one chat line with what the worker did beside it" do
      keep_work_examples!()
      work = work!("Ev-work-export", "@ryker why is the staging api down?")
      assert {:ok, %{copied: 1}} = WorkExamples.capture(@options)

      assert [line] = lines()
      document = Jason.decode!(line)

      assert document["messages"] == [
               %{"role" => "user", "content" => @prompt},
               %{
                 "role" => "assistant",
                 "content" => Jason.encode!(%{"delivery" => "reply", "message" => @question})
               }
             ]

      assert Enum.map(document["trajectory"], & &1["kind"]) == ["tool.completed", "model.thought"]
      assert document["rejected_results"] == []
      assert document["output_schema"] == @schema
      assert document["labels"]["request_id"] == work.episode_id
      assert document["labels"]["turn_id"] == work.turn_id
      assert document["labels"]["model"] == nil or is_binary(document["labels"]["model"])
      assert document["labels"]["outcome"]["request"] == "waiting_for_input"
    end
  end

  describe "the worker" do
    # Nothing settles by the clock, so an idle worker sleeps ten seconds; the
    # request coming to rest has to wake it.
    test "a turn that settles while the worker is idle is copied at once" do
      keep_work_examples!()

      worker =
        start_supervised!(
          {WorkExamples.Worker,
           batch_size: 5, poll_interval_ms: 10_000, redaction_secrets: [], window_seconds: 60}
        )

      # Its first poll found nothing to copy.
      _state = :sys.get_state(worker)
      work = work!("Ev-work-woken", "@ryker why is the staging api down?")

      assert eventually(fn -> Repo.get_by(Example, turn_id: work.turn_id) end)
    end
  end

  # -- Helpers ----------------------------------------------------------------------

  defp eventually(check, attempts \\ 40) do
    case check.() do
      result when result in [nil, false] and attempts > 0 ->
        Process.sleep(25)
        eventually(check, attempts - 1)

      result ->
        result
    end
  end

  defp lines do
    assert {:ok, lines} =
             Export.reduce([], fn line, read -> {:cont, [IO.iodata_to_binary(line) | read]} end)

    Enum.reverse(lines)
  end

  defp keep_work_examples! do
    settings = Settings.fetch!()

    assert {:ok, _saved} =
             Settings.save_retention(
               %{work_examples_enabled: true},
               settings.installation.revision,
               @actor
             )
  end

  defp retention(enabled) do
    %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60,
      routing_examples_enabled: false,
      routing_examples_seconds: 365 * @day,
      work_examples_enabled: enabled,
      work_examples_seconds: 365 * @day
    }
  end

  defp assert_erased(turn_id) do
    example = Repo.get_by!(Example, turn_id: turn_id)
    assert example.forgotten_at

    assert {example.briefing, example.context, example.output_schema, example.trajectory,
            example.result, example.rejected_results, example.outcome, example.usage} ==
             {nil, nil, nil, nil, nil, nil, nil, nil}

    refute Repo.exists?(from(f in KeptFeedback, where: f.example_id == ^example.id))
  end

  # One Slack message routed to a new request, and that request worked to an
  # answer that asks the person a question: the briefing frozen, the worker's
  # activity recorded, each of `refused` refused in turn, the answer accepted
  # and, unless `deliver: false`, sent.
  defp work!(event_ref, text, options \\ []) do
    entry = route!(event_ref, text, options)

    assert {:ok, %{episode: %{id: episode_id}} = claim} =
             Custody.claim_next("work:#{entry.id}", 120, :work)

    assert episode_id == entry.episode_id

    {session, turn} = brief!(claim, Keyword.get(options, :prompt, @prompt))
    activity!(session, turn)
    accepted = answer!(claim, turn, Keyword.get(options, :refused, []))
    if Keyword.get(options, :deliver, true), do: deliver!(accepted)

    %{entry: entry, episode_id: episode_id, turn_id: turn.id, accepted: accepted}
  end

  defp brief!(%{episode: episode, lease_ref: lease, turn: turn} = claim, prompt) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id, "turn_ref" => turn.turn_ref},
               prompt,
               @schema,
               "work-final-live-v3"
             )

    assert {:ok, _frozen} =
             Custody.freeze_submission(episode.id, turn.turn_ref, lease, submission)

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               turn.turn_ref,
               lease,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{episode.id}"
             )

    assert {:ok, bound} =
             Custody.bind_turn(
               episode.id,
               turn.turn_ref,
               lease,
               session.generation,
               turn.submit_generation,
               "coop-turn:#{episode.id}"
             )

    {session, bound}
  end

  # What the worker did, as Coop reports it: a tool call started and
  # completed, its output printing a stored credential, the provider's
  # liveness, and a progress note.
  defp activity!(session, turn) do
    event = fn sequence, type, payload ->
      %{
        "id" => "activity:#{turn.id}:#{sequence}",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(@now, sequence, :second)),
        "payload" => payload,
        "sequence" => sequence,
        "session_id" => session.coop_session_id,
        "turn_id" => turn.coop_turn_id,
        "type" => type,
        "version" => 1
      }
    end

    assert {:ok, %{inserted: 4}} =
             Activity.ingest(session.id, [
               event.(1, "tool.started", %{"tool_call_id" => "call-1", "status" => "running"}),
               event.(2, "tool.completed", %{
                 "tool_call_id" => "call-1",
                 "status" => "completed",
                 "kind" => "execute",
                 "title" => "kubectl get pods",
                 "input" => %{"command" => "kubectl get pods -n staging"},
                 "output" => "api-7f9 CrashLoopBackOff (token #{@stored_secret})"
               }),
               event.(3, "model.thought", %{
                 "text" => "The api pod is crash-looping; reading its events."
               }),
               event.(4, "provider.alive", %{"bytes" => 128, "frames" => 2})
             ])
  end

  defp answer!(%{episode: episode, lease_ref: lease}, turn, refused) do
    {previous_sha, previous_attempt} =
      refused
      |> Enum.with_index(1)
      |> Enum.reduce({nil, nil}, fn {{candidate, violations}, attempt}, {before_sha, before} ->
        sha = digest(candidate)

        assert {:ok, staged} =
                 Custody.stage_candidate(
                   episode.id,
                   turn.turn_ref,
                   lease,
                   before_sha,
                   before,
                   candidate,
                   sha,
                   attempt
                 )

        assert {:ok, _prepared} =
                 Custody.prepare_validation(
                   episode.id,
                   turn.turn_ref,
                   lease,
                   sha,
                   attempt,
                   {:reject, violations},
                   nil
                 )

        assert {:ok, _advanced} =
                 Custody.advance_validation(
                   episode.id,
                   turn.turn_ref,
                   lease,
                   sha,
                   attempt,
                   staged.validation_generation
                 )

        {sha, attempt}
      end)

    attempt = (previous_attempt || 0) + 1
    candidate = Jason.encode!(%{"delivery" => "reply", "message" => @question})
    sha = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               episode.id,
               turn.turn_ref,
               lease,
               previous_sha,
               previous_attempt,
               candidate,
               sha,
               attempt
             )

    wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "question:#{turn.id}"
    }

    assert {:ok, result} = Result.new(:reply, %{"message" => @question}, nil, wait)

    assert {:ok, _prepared} =
             Custody.prepare_validation(
               episode.id,
               turn.turn_ref,
               lease,
               sha,
               attempt,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               lease,
               sha,
               attempt,
               "validation:#{episode.id}"
             )

    accepted
  end

  # The question reaches Slack, and the request waits for the person.
  defp deliver!(%{episode: episode, turn: turn}) do
    assert {:ok, claim} = Custody.claim_next("delivery:#{episode.id}", 60, :delivery)
    target = turn.delivery_target

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               turn.delivery_ref,
               target["transport"],
               target["conversation_ref"],
               target["thread_ref"],
               "1788629000.000100"
             )

    assert {:ok, %{episode: %{state: :waiting_for_input}}} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               claim.lease_ref,
               receipt
             )
  end

  # One Slack message in the channel, routed by the real executor to start a
  # request. `message` numbers messages in time order.
  defp route!(event_ref, text, options) do
    number = Keyword.get(options, :message, 1)

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: Keyword.get(options, :channel, @channel),
               content: %{"text" => text},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: message_ref(number),
               occurred_at: DateTime.add(@now, number, :second),
               revision: 1,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("work-examples:test", @now, 300)

    assert claimed.id == entry.id

    {:ok, fake} = FakeAPI.start_link([@start_episode], turn_id_override: "turn_#{event_ref}")
    Agent.update(fake, &put_in(&1, [:session, "target"], @target))

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry),
               api: FakeAPI,
               client: fake,
               lease_ref: lease_ref,
               max_polls: 10,
               now: fn -> @now end,
               policy: "admission-read-only",
               policy_digest: String.duplicate("a", 64),
               poll_interval_ms: 0,
               renew_lease: fn -> :ok end,
               sleep: fn _milliseconds -> :ok end
             )

    execution.result.entry
  end

  defp message_ref(number), do: "1787832001.00010#{number}"

  defp delete_message!(event_ref, number) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: @channel,
               content: %{"text" => ""},
               event_kind: :delete,
               event_ref: event_ref,
               message_ref: message_ref(number),
               occurred_at: DateTime.add(@now, 60, :second),
               revision: 2,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    assert {:ok, %{status: :recorded}} = Inbox.record(input)
  end
end
