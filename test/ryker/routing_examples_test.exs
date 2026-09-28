defmodule Ryker.RoutingExamplesTest do
  @moduledoc """
  Routing examples kept for training a smaller routing model.

  Andrew, 2026-09-27: "is our current retention policy defeats the purpose
  deleting data that will be used for learning too quickly?" It did: the
  exact prompt and answer of every routing decision were pruned with the
  message's bodies after 30 days, and nothing joined them to what happened
  next. These hold the copy that outlives them, and the three ways a person
  removing a message must still win over it.

  Every decision here is made by the real admission executor over a fake
  Coop session. The answers are ones routing's model gave on the live
  install, harvested from `admission_attempts` on 2026-09-27; the start and
  the reply keep the live wording with the candidate and repository they
  named taken out, since this test offers neither.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Ryker.TestHelpers, only: [digest: 1]

  # The executor reads routing's context under the isolation it runs with.
  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission.{Attempt, Executor}
  alias Ryker.Delivery.{RoutingResponse, RoutingResponseCustody}
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.Forgetting
  alias Ryker.Retention.Data
  alias Ryker.RoutingExamples
  alias Ryker.RoutingExamples.Example
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfigurations
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission}

  @actor "control-plane:local"
  @day 86_400
  # The day of the harvest, after the saved gpt-5.6-luna price took effect.
  @now ~U[2026-09-27 12:00:00.000000Z]
  @workspace "TE5D7C8842D32"
  @channel "C456"
  @conversation "slack:TE5D7C8842D32:C456"
  @options %{batch_size: 25, redaction_secrets: [], window_seconds: 365 * @day}

  @quick_reply ~s({"action":"quick_reply","episode_ref":null,"messages":["Hi!"],"reactions":null,"relation":"unrelated","reason":"The person greeted Ryker and requested a one-word reply.","repository":null,"repository_source":null,"work_class":null})
  @ignore ~s({"action":"ignore","episode_ref":null,"messages":null,"reactions":null,"relation":"unrelated","reason":"The message shares an unavailable file with no text, request to Ryker, or identifiable operational event. The earlier reply and reaction request was already handled.","repository":null,"repository_source":null,"work_class":null})
  @start_episode ~s({"action":"start_episode","episode_ref":null,"messages":null,"reactions":null,"relation":"unrelated","reason":"This explicitly requests a new end-to-end test. It requires an isolated README-only commit and checks, with branch push and draft PR handled through Ryker’s publication flow and main left unchanged.","repository":null,"repository_source":null,"work_class":"standard"})

  # The live quick reply's recorded usage and timing, from the same harvest.
  @target "codex:gpt-5.6-luna/low@default"
  @turn_report %{
    "usage" => %{
      "input_tokens" => 7_026,
      "cached_input_tokens" => 12_160,
      "output_tokens" => 59,
      "reasoning_tokens" => 0
    },
    "queued_at" => "2026-09-27T14:53:30.438376Z",
    "started_at" => "2026-09-27T14:53:30.451646Z",
    "finished_at" => "2026-09-27T14:53:38.712281Z"
  }

  setup do
    assert {:ok, _settings} = Settings.initialize(@actor)
    :ok
  end

  describe "the copy" do
    # A request is only a useful example once its outcome is known. Andrew's
    # "@Ryker check health of our infra" asked him a question two hours after
    # routing chose to start it (2026-09-27); a copy taken at the decision
    # would have labelled it as still running.
    test "a routing decision is kept once the Work it started has come to rest" do
      keep_examples!()
      entry = route!("Ev-examples-start", "Please run a new end-to-end test", @start_episode)
      attempt = attempt!(entry)

      # Its Work is about to start, then runs: nothing is copied.
      assert {:ok, %{copied: 0}} = RoutingExamples.capture(@options)
      work = run_work!(entry)
      assert {:ok, %{copied: 0}} = RoutingExamples.capture(@options)

      # Its answer, a question, is accepted and waits to be sent: still running.
      accepted = ask_question!(work)
      assert {:ok, %{copied: 0}} = RoutingExamples.capture(@options)

      # Sent: the request waits for the person, and the decision is kept.
      deliver!(accepted)
      assert {:ok, %{copied: 1, forgotten: 0}} = RoutingExamples.capture(@options)
      example = Repo.one!(Example)

      # The exact prompt routing sent and the model's exact answer.
      assert example.prompt == attempt.submission["prompt"]
      assert example.output_schema == attempt.submission["output_schema"]
      assert example.answer == @start_episode
      assert example.execution_target == @target
      assert {example.policy, example.policy_digest} == {attempt.policy, attempt.policy_digest}

      assert example.decision == %{
               "action" => "start_episode",
               "messages" => 0,
               "reactions" => [],
               "relation" => "unrelated",
               "repository" => nil,
               "work_class" => "standard"
             }

      assert example.outcome == %{
               "request" => "waiting_for_input",
               "sent" => nil,
               "turn" => "settled"
             }

      assert example.usage["input_tokens"] == 7_026
      assert example.usage["cached_input_tokens"] == 12_160
      assert example.usage["output_tokens"] == 59
      assert example.usage["cost_usd"] == nil
      # No provider cost, so the saved gpt-5.6-luna price estimates it:
      # (7,026 × 0.20 + 12,160 × 0.02 + 59 × 1.20) / 1,000,000 dollars.
      assert example.usage["estimated_cost_usd"] == "0.0017192"
      assert example.usage["provider_ms"] > 0

      # The request it started, for the feedback kept per request, and where
      # it happened.
      assert example.input_id == entry.id
      assert example.episode_id == entry.episode_id
      assert example.episode_ref == Repo.get!(Ryker.Episodes.Episode, entry.episode_id).key
      assert example.conversation_ref == @conversation
      assert example.transport == "slack"
      assert example.execution_mode == :live

      # Its age counts from when routing committed the decision.
      assert DateTime.to_iso8601(example.decided_at) == attempt.milestones["committed"]

      # Copied once.
      assert {:ok, %{copied: 0}} = RoutingExamples.capture(@options)
      assert Repo.aggregate(Example, :count) == 1
    end

    test "a quick reply is kept once what routing sent itself has been delivered" do
      keep_examples!()
      entry = route!("Ev-examples-quick", "hi, reply with one word", @quick_reply)

      assert [%RoutingResponse{status: :pending}] = Repo.all(RoutingResponse)
      assert {:ok, %{copied: 0}} = RoutingExamples.capture(@options)

      deliver_routing_responses!()
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)

      example = Repo.get_by!(Example, input_id: entry.id)
      assert example.answer == @quick_reply
      assert example.decision["action"] == "quick_reply"
      assert example.decision["messages"] == 1
      assert example.outcome == %{"request" => nil, "sent" => %{"delivered" => 1}, "turn" => nil}
    end

    # Consent: nothing is copied while keeping routing examples is off.
    test "nothing is copied while keeping routing examples is off" do
      entry = route!("Ev-examples-off", "hello there", @ignore)

      assert {:ok, %{copied: 0, forgotten: 0}} = RoutingExamples.capture(@options)
      assert Repo.aggregate(Example, :count) == 0

      keep_examples!()
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)
      assert Repo.get_by!(Example, input_id: entry.id).answer == @ignore
    end

    # The copy outlives the prompt by a year, so a credential somebody pasted
    # must not outlive it with it: a stored integration secret, a Slack token
    # and a link's signed query are gone, and nothing else in the prompt moved.
    test "a credential a routed message quoted never reaches the kept example" do
      keep_examples!()
      stored = "s3cr3t-stored-integration-value"
      token = "xoxb-2718281828-3141592653-abcdefghijklmnop"
      link = "https://grafana.example.com/d/abc?orgId=1&token=signed"

      entry =
        route!(
          "Ev-examples-secret",
          "deploy failed, the bot uses #{token} and #{stored}, see #{link}",
          @ignore
        )

      prompt = attempt!(entry).submission["prompt"]
      assert prompt =~ token and prompt =~ stored

      assert {:ok, %{copied: 1}} =
               RoutingExamples.capture(%{@options | redaction_secrets: [stored]})

      example = Repo.one!(Example)
      refute example.prompt =~ token
      refute example.prompt =~ stored
      refute example.prompt =~ "orgId"

      assert example.prompt ==
               prompt
               |> String.replace(token, "[redacted]")
               |> String.replace(stored, "[redacted]")
               |> String.replace(link, "https://grafana.example.com/d/abc")

      # The operational copy is untouched; only the kept one is redacted.
      assert attempt!(entry).submission["prompt"] == prompt
    end

    # A pass copies every settled decision, oldest first. One that cannot be
    # copied must be left for a later pass rather than stop every decision
    # after it, and the log may name only which one and the kind of error:
    # an error can quote the prompt it failed on.
    test "a decision that cannot be copied is skipped, and logged without its words" do
      keep_examples!()
      broken = route!("Ev-examples-uncopyable", "the staging account is acme-staging", @ignore)
      after_it = route!("Ev-examples-uncopyable-2", "hello there", @ignore, message: 2)

      # Its frozen submission lost the contract routing held the answer to:
      # the example's own check refuses a kept example without one.
      Repo.update_all(from(attempt in Attempt, where: attempt.input_id == ^broken.id),
        set: [submission: Map.put(attempt!(broken).submission, "output_schema", nil)]
      )

      log =
        capture_log(fn ->
          assert {:ok, %{copied: 1, forgotten: 0}} = RoutingExamples.capture(@options)
        end)

      assert kept(after_it)
      refute Repo.get_by(Example, input_id: broken.id)

      assert [line] = log |> String.trim() |> String.split("\n")

      assert line =~
               ~r/\[error\] routing example copy failed input=#{broken.id} category=Ecto.ConstraintError$/
    end
  end

  describe "a person forgetting wins" do
    # The prompt of a later message quotes the earlier ones of its channel, so
    # forgetting a message must reach every example that quoted it, not only
    # its own.
    test "forgetting what was learned from a message erases every example that quoted it" do
      keep_examples!()
      first = route!("Ev-examples-first", "the staging account is acme-staging", @ignore)
      second = route!("Ev-examples-second", "thanks", @ignore, message: 2)
      unrelated = route!("Ev-examples-other", "hello", @ignore, message: 3, channel: "C999")

      assert {:ok, %{copied: 3}} = RoutingExamples.capture(@options)
      assert Repo.get_by!(Example, input_id: second.id).prompt =~ "acme-staging"

      topic = topic!(first, "staging-account", "Staging account")
      assert {:ok, %{forgotten: [_]}} = Forgetting.forget_topic(topic.id)

      assert_erased(first)
      assert_erased(second)
      assert kept(unrelated)

      # And it is never copied again.
      assert {:ok, %{copied: 0, forgotten: 0}} = RoutingExamples.capture(@options)
      assert Repo.aggregate(Example, :count) == 3
    end

    # A learned topic reaches later prompts on its own, its summary quoted
    # where the message it came from may no longer be.
    test "forgetting a learned topic erases the examples whose prompt quoted it" do
      keep_examples!()
      first = route!("Ev-examples-topic", "the staging account is acme-staging", @ignore)
      topic = topic!(first, "staging-account", "Staging account")
      second = route!("Ev-examples-topic-2", "which account is staging?", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 RoutingExamples.forget_topics_in_transaction([topic.id])
               end)

      assert_erased(second)
      # Routed before the topic was learned, it never quoted it.
      assert kept(first)
    end

    test "a message forgotten before its example is taken is never copied" do
      keep_examples!()
      first = route!("Ev-examples-early", "the staging account is acme-staging", @ignore)
      second = route!("Ev-examples-early-2", "thanks", @ignore, message: 2)

      topic = topic!(first, "staging-account", "Staging account")
      assert {:ok, _outcome} = Forgetting.forget_topic(topic.id)

      assert {:ok, %{copied: 0, forgotten: 2}} = RoutingExamples.capture(@options)
      assert_erased(first)
      assert_erased(second)
    end

    test "deleting a message in Slack erases the examples that quote it" do
      keep_examples!()
      first = route!("Ev-examples-deleted", "the staging account is acme-staging", @ignore)
      second = route!("Ev-examples-deleted-2", "thanks", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)

      delete_message!("Ev-examples-deleted-gone", 1)

      assert_erased(first)
      assert_erased(second)
    end

    test "a message deleted before its example is taken is never copied" do
      keep_examples!()
      first = route!("Ev-examples-deleted-early", "the staging account is acme-staging", @ignore)

      delete_message!("Ev-examples-deleted-early-gone", 1)

      assert {:ok, %{copied: 0, forgotten: 1}} = RoutingExamples.capture(@options)
      assert_erased(first)
    end

    # An edit replaces the words a person no longer wants said. Only deleting
    # reached the copies, so the year-long example kept the words the person
    # had replaced, in its own prompt and in every later prompt of the channel
    # that quoted it.
    test "editing a message in Slack erases the examples that quoted its old words" do
      keep_examples!()
      first = route!("Ev-examples-edited", "the staging account is acme-staging", @ignore)
      second = route!("Ev-examples-edited-2", "thanks", @ignore, message: 2)
      unrelated = route!("Ev-examples-edited-3", "hello", @ignore, message: 3, channel: "C999")
      assert {:ok, %{copied: 3}} = RoutingExamples.capture(@options)

      edit_message!("Ev-examples-edited-changed", 1, "the staging account is acme-stg")

      assert_erased(first)
      assert_erased(second)
      assert kept(unrelated)
    end

    # Work can run for hours before its decision settles, and a person often
    # fixes their message meanwhile: the copy taken afterwards quoted the
    # words the edit had replaced.
    test "a message edited before its example is taken is never copied" do
      keep_examples!()
      first = route!("Ev-examples-edited-early", "the staging account is acme-staging", @ignore)
      second = route!("Ev-examples-edited-early-2", "thanks", @ignore, message: 2)

      edit_message!("Ev-examples-edited-early-changed", 1, "the staging account is acme-stg")

      assert {:ok, %{copied: 0, forgotten: 2}} = RoutingExamples.capture(@options)
      assert_erased(first)
      assert_erased(second)
    end

    # Slack reports a link's preview arriving as an edit of the message, with
    # the words untouched. Most messages quote a channel's last twenty, so
    # counting those as edits would take nearly every example with them.
    test "an edit that leaves the words as they were, such as a link preview, erases nothing" do
      keep_examples!()
      text = "the dashboard is https://grafana.example.com/d/abc"
      first = route!("Ev-examples-preview", text, @ignore)
      second = route!("Ev-examples-preview-2", "thanks", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)
      third = route!("Ev-examples-preview-3", "anything else?", @ignore, message: 3)

      preview = %{"title" => "Grafana", "from_url" => "https://grafana.example.com/d/abc"}
      edit_message!("Ev-examples-preview-unfurled", 1, text, attachments: [preview])

      assert kept(first)
      assert kept(second)
      assert {:ok, %{copied: 1, forgotten: 0}} = RoutingExamples.capture(@options)
      assert kept(third)
    end

    # Routing offers earlier work beside a message, each by a short preview of
    # its opening and latest message, and nothing recorded which messages
    # those were. Deleting the message a preview quoted left its words in
    # every example that had offered that work: the one quotation forgetting
    # could not trace (2026-09-27).
    test "deleting a message a candidate's preview quoted erases the examples that offered it" do
      keep_examples!()
      route!("Ev-examples-offered", "the staging account is acme-staging", @start_episode)

      # The channel's five later messages are the notes routing recalls beside
      # the next one, so of the first only the work's preview is left.
      for number <- 2..6,
          do: route!("Ev-examples-offered-#{number}", "noted #{number}", @ignore, message: number)

      # Asked in another thread, it sees that work only as a candidate.
      asked =
        route!("Ev-examples-offered-asked", "is the billing export done?", @ignore,
          message: 7,
          thread: "1787832000.000900"
        )

      notes = Repo.get!(Entry, asked.id).admission_context["conversation_observations"]
      refute Enum.any?(List.wrap(notes), &(&1["source_message_ref"] == message_ref(1)))
      assert attempt!(asked).submission["prompt"] =~ "acme-staging"
      assert {:ok, %{copied: 6}} = RoutingExamples.capture(@options)

      delete_message!("Ev-examples-offered-gone", 1)

      assert_erased(asked)
    end

    # An alerting app updates its own message as the alert moves on. That is
    # not a person taking back their words, and erasing on it would lose the
    # examples of how routing handled the alert, which most routing is.
    test "an app updating its own message erases nothing" do
      keep_examples!()
      alerting = %{kind: :app, ref: "AALERTS"}
      first = route!("Ev-examples-alert", "FIRING: disk full on db-1", @ignore, actor: alerting)
      second = route!("Ev-examples-alert-2", "looking into it", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)
      third = route!("Ev-examples-alert-3", "anything new?", @ignore, message: 3)

      edit_message!("Ev-examples-alert-resolved", 1, "RESOLVED: disk full on db-1",
        actor: alerting
      )

      assert kept(first)
      assert kept(second)
      assert {:ok, %{copied: 1, forgotten: 0}} = RoutingExamples.capture(@options)
      assert kept(third)
    end

    test "deleting a Slack channel erases the examples from it" do
      keep_examples!()
      first = route!("Ev-examples-channel", "the staging account is acme-staging", @ignore)
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)
      later = route!("Ev-examples-channel-2", "thanks", @ignore, message: 2)
      unrelated = route!("Ev-examples-channel-3", "hello", @ignore, message: 3, channel: "C999")

      assert {:ok, _deleted} =
               ChannelConfigurations.observe_membership(
                 %{
                   actor_ref: nil,
                   channel_ref: @channel,
                   event_ref: "event:delete-routing-examples",
                   kind: :deleted,
                   occurred_at: Repo.now!(),
                   workspace_ref: @workspace
                 },
                 %{default_environment: nil, environments: []}
               )

      assert_erased(first)

      # One routed there but not yet copied is never copied.
      assert {:ok, %{copied: 1, forgotten: 1}} = RoutingExamples.capture(@options)
      assert_erased(later)
      assert kept(unrelated)
    end
  end

  describe "retention" do
    # The copy is the point: a prompt pruned at 30 days must not take its
    # training example with it, however the source rows go.
    test "an example outlives the pruning of every row it was copied from" do
      keep_examples!()
      entry = route!("Ev-examples-outlives", "hello there", @ignore)
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)
      kept_prompt = Repo.one!(Example).prompt

      old = ~U[2020-01-01 00:00:00.000000Z]
      Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [updated_at: old])

      # One pass redacts the message's bodies and, the audit horizon passed
      # too, removes the message and its routing attempt.
      assert {:ok, pass} = Data.prune(retention(60))
      assert pass.operational_inputs == 1
      assert pass.audit_rows >= 1

      refute Repo.get(Entry, entry.id)
      refute Repo.get_by(Attempt, input_id: entry.id)
      assert %Example{prompt: ^kept_prompt, forgotten_at: nil} = Repo.one!(Example)
    end

    test "an example expires at its own window, counted from the decision" do
      keep_examples!()
      old = route!("Ev-examples-old", "hello there", @ignore)
      fresh = route!("Ev-examples-fresh", "good morning", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)

      Repo.update_all(from(x in Example, where: x.input_id == ^old.id),
        set: [decided_at: DateTime.add(Repo.now!(), -400, :day)]
      )

      assert {:ok, %{routing_examples: 1}} = Data.prune(retention(365 * @day))
      refute Repo.get_by(Example, input_id: old.id)
      assert kept(fresh)
    end

    test "turning keeping routing examples off deletes every kept one" do
      keep_examples!()
      route!("Ev-examples-withdrawn", "hello there", @ignore)
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)

      assert {:ok, %{routing_examples: 1}} =
               Data.prune(%{retention(365 * @day) | routing_examples_enabled: false})

      assert Repo.aggregate(Example, :count) == 0
    end
  end

  describe "the setting" do
    test "keeping routing examples is off until a person turns it on, then keeps a year" do
      retention = Settings.fetch!().retention
      assert retention.routing_examples_enabled == false
      assert retention.routing_examples_seconds == 365 * @day
    end

    # Turning it off deletes what was kept, so it asks first, like a shorter
    # limit, and says how many would go.
    test "turning keeping routing examples off asks first and names what it deletes" do
      keep_examples!()
      route!("Ev-examples-confirm", "hello there", @ignore)
      assert {:ok, %{copied: 1}} = RoutingExamples.capture(@options)
      revision = Settings.fetch!().installation.revision
      off = %{routing_examples_enabled: false}

      assert {:ok, preview} = Settings.preview_retention(off, revision)
      assert preview.shortened_fields == [:routing_examples_enabled]

      assert preview.impact == %{
               routing_examples_enabled: [%{label: "routing examples", count: 1}]
             }

      assert Settings.save_retention(off, revision, @actor) ==
               {:error, :retention_impact_confirmation_required}

      assert {:ok, saved} = Settings.save_retention(off, revision, @actor, preview.confirmation)
      refute saved.retention.routing_examples_enabled
    end

    test "a routing example window outside one day to ten years is refused" do
      revision = Settings.fetch!().installation.revision

      assert {:error, {:invalid_settings, [routing_examples_seconds: :bounds]}} =
               Settings.save_retention(%{routing_examples_seconds: 30}, revision, @actor)

      assert {:ok, saved} =
               Settings.save_retention(
                 %{routing_examples_enabled: true, routing_examples_seconds: 730 * @day},
                 revision,
                 @actor
               )

      assert {saved.retention.routing_examples_enabled, saved.retention.routing_examples_seconds} ==
               {true, 730 * @day}
    end

    # While none are kept a shorter limit deletes nothing, so turning keeping
    # them on with one is saved at once; once some are kept, it asks.
    test "a shorter routing example window asks first only while examples are kept" do
      revision = Settings.fetch!().installation.revision
      on = %{routing_examples_enabled: true, routing_examples_seconds: 180 * @day}
      assert {:ok, saved} = Settings.save_retention(on, revision, @actor)

      assert Settings.save_retention(
               %{routing_examples_seconds: 90 * @day},
               saved.installation.revision,
               @actor
             ) == {:error, :retention_impact_confirmation_required}
    end
  end

  describe "the export" do
    test "the export writes one fine-tuning line per kept example and none for a forgotten one" do
      keep_examples!()
      kept = route!("Ev-examples-export", "hi, reply with one word", @quick_reply)
      deliver_routing_responses!()

      forgotten =
        route!("Ev-examples-export-2", "the staging account is acme-staging", @ignore,
          message: 2,
          channel: "C999"
        )

      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)
      topic = topic!(forgotten, "staging-account", "Staging account")
      assert {:ok, _outcome} = Forgetting.forget_topic(topic.id)

      assert [line] = lines()
      assert String.ends_with?(line, "\n")
      # The fine-tuning messages come first, as trainers read them.
      assert String.starts_with?(line, ~s({"messages":[{"role":"user","content":))

      example = Repo.get_by!(Example, input_id: kept.id)
      document = Jason.decode!(line)

      assert document["messages"] == [
               %{"role" => "user", "content" => example.prompt},
               %{"role" => "assistant", "content" => @quick_reply}
             ]

      assert document["output_schema"] == example.output_schema
      labels = document["labels"]
      assert labels["example_id"] == example.id
      assert labels["input_id"] == kept.id
      # Routing answered by itself, so there is no request for feedback to name.
      assert labels["request_id"] == nil
      assert labels["model"] == @target
      assert labels["conversation_ref"] == @conversation
      assert labels["decision"]["action"] == "quick_reply"
      assert labels["outcome"]["sent"] == %{"delivered" => 1}
      assert labels["usage"]["input_tokens"] == 7_026
      assert labels["decided_at"] == DateTime.to_iso8601(example.decided_at)
    end

    test "the export goes oldest decision first and stops when its reader does" do
      keep_examples!()
      older = route!("Ev-examples-order", "hello there", @ignore)
      newer = route!("Ev-examples-order-2", "good morning", @ignore, message: 2)
      assert {:ok, %{copied: 2}} = RoutingExamples.capture(@options)

      Repo.update_all(from(x in Example, where: x.input_id == ^newer.id),
        set: [decided_at: DateTime.add(Repo.now!(), -1, :day)]
      )

      assert Enum.map(lines(), &Jason.decode!(&1)["labels"]["input_id"]) == [newer.id, older.id]

      assert {:ok, [first]} =
               RoutingExamples.Export.reduce([], fn line, read ->
                 {:halt, [IO.iodata_to_binary(line) | read]}
               end)

      assert Jason.decode!(first)["labels"]["input_id"] == newer.id
    end
  end

  describe "the worker" do
    # Nothing settles by the clock, so an idle worker sleeps ten seconds; a
    # routed message has to wake it.
    test "a decision that settles while the worker is idle is copied at once" do
      keep_examples!()

      worker =
        start_supervised!(
          {RoutingExamples.Worker,
           batch_size: 25, poll_interval_ms: 10_000, redaction_secrets: [], window_seconds: 60}
        )

      # Its first poll found nothing to copy.
      _state = :sys.get_state(worker)
      entry = route!("Ev-examples-woken", "hello there", @ignore)

      assert eventually(fn -> Repo.get_by(Example, input_id: entry.id) end)
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp lines do
    assert {:ok, lines} =
             RoutingExamples.Export.reduce([], fn line, read ->
               {:cont, [IO.iodata_to_binary(line) | read]}
             end)

    Enum.reverse(lines)
  end

  defp eventually(check, attempts \\ 40) do
    case check.() do
      result when result in [nil, false] and attempts > 0 ->
        Process.sleep(25)
        eventually(check, attempts - 1)

      result ->
        result
    end
  end

  defp keep_examples! do
    settings = Settings.fetch!()

    assert {:ok, _saved} =
             Settings.save_retention(
               %{routing_examples_enabled: true},
               settings.installation.revision,
               @actor
             )
  end

  # One Slack message in the channel, routed by the real executor to the
  # harvested answer. `message` numbers messages in time order; `thread` is
  # the thread it replies in, and `actor` who sent it.
  defp route!(event_ref, text, answer, options \\ []) do
    number = Keyword.get(options, :message, 1)

    assert {:ok, input} =
             SlackInput.new(%{
               actor: Keyword.get(options, :actor, %{kind: :user, ref: "U123"}),
               channel_ref: Keyword.get(options, :channel, @channel),
               content: %{"text" => text},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: message_ref(number),
               occurred_at: DateTime.add(@now, number, :second),
               revision: 1,
               thread_ref: Keyword.get(options, :thread),
               workspace_ref: @workspace
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("routing-examples:test", @now, 300)

    assert claimed.id == entry.id
    # Each message is its own routing turn, as it is on Coop.
    {:ok, fake} =
      FakeAPI.start_link([answer],
        turn_report: @turn_report,
        turn_id_override: "turn_#{event_ref}"
      )

    Agent.update(fake, &put_in(&1, [:session, "target"], @target))

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))
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

  # The person, or the `actor` given, edits message `number` to say `text`;
  # `attachments` are what Slack added to it, such as a link's preview.
  defp edit_message!(event_ref, number, text, options \\ []) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: Keyword.get(options, :actor, %{kind: :user, ref: "U123"}),
               channel_ref: @channel,
               content: %{
                 "text" => text,
                 "attachments" => Keyword.get(options, :attachments, [])
               },
               event_kind: :edit,
               event_ref: event_ref,
               message_ref: message_ref(number),
               occurred_at: DateTime.add(@now, 60, :second),
               revision: 2,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    assert {:ok, %{status: :recorded}} = Inbox.record(input)
  end

  defp executor_options(fake, lease_ref) do
    [
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
    ]
  end

  defp attempt!(entry), do: Repo.get_by!(Attempt, input_id: entry.id)

  defp topic!(entry, key, title) do
    proposal = %{
      "topic_key" => key,
      "title" => title,
      "summary" => "#{title}, as the message reported it.",
      "topics" => [key],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(entry, proposal, []) end)

    Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == ^key))
  end

  defp assert_erased(entry) do
    example = Repo.get_by!(Example, input_id: entry.id)
    assert example.forgotten_at

    assert {example.prompt, example.answer, example.output_schema, example.decision,
            example.outcome, example.usage} == {nil, nil, nil, nil, nil, nil}
  end

  defp kept(entry) do
    example = Repo.get_by!(Example, input_id: entry.id)
    is_nil(example.forgotten_at) and is_binary(example.prompt)
  end

  defp retention(routing_examples_seconds) do
    %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60,
      routing_examples_enabled: true,
      routing_examples_seconds: routing_examples_seconds
    }
  end

  # Routing's own replies and reactions reach Slack.
  defp deliver_routing_responses! do
    Enum.each(Repo.all(RoutingResponse), fn _response ->
      assert {:ok, %{response: pending} = claim} =
               RoutingResponseCustody.claim_next("delivery:routing-examples", 60)

      assert {:ok, receipt} =
               DeliveryReceipt.new(
                 pending.delivery_ref,
                 pending.transport,
                 pending.conversation_ref,
                 pending.thread_ref,
                 "1788629000.000200"
               )

      assert {:ok, %{status: :delivered}} =
               RoutingResponseCustody.confirm_delivery(
                 pending.delivery_ref,
                 claim.lease_ref,
                 receipt
               )
    end)
  end

  # The Work pool runs the request's turn.
  defp run_work!(entry) do
    assert {:ok, %{episode: %{id: episode_id}} = work} =
             Custody.claim_next("work:#{entry.id}", 120, :work)

    assert episode_id == entry.episode_id
    work
  end

  # The Work settles its request by asking a person, as it settled Andrew's:
  # the answer is accepted as a reply that then waits for input.
  defp ask_question!(%{episode: episode, lease_ref: lease, turn: turn} = work) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id, "turn_ref" => turn.turn_ref},
               "Continue from the frozen episode state.",
               %{
                 "additionalProperties" => false,
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"],
                 "type" => "object"
               },
               "work-final-live-v3"
             )

    assert {:ok, _frozen} =
             Custody.freeze_submission(episode.id, turn.turn_ref, lease, submission)

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               turn.turn_ref,
               lease,
               work.session.generation,
               work.session.create_generation,
               "coop-session:#{episode.id}"
             )

    assert {:ok, _bound} =
             Custody.bind_turn(
               episode.id,
               turn.turn_ref,
               lease,
               session.generation,
               turn.submit_generation,
               "coop-turn:#{episode.id}"
             )

    question = "Which cluster should I check first?"
    candidate = Jason.encode!(%{"delivery" => "reply", "message" => question})
    sha = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               episode.id,
               turn.turn_ref,
               lease,
               nil,
               nil,
               candidate,
               sha,
               1
             )

    wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "question:#{turn.id}"
    }

    assert {:ok, result} = Result.new(:reply, %{"message" => question}, nil, wait)

    assert {:ok, _prepared} =
             Custody.prepare_validation(episode.id, turn.turn_ref, lease, sha, 1, :accept, result)

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               lease,
               sha,
               1,
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
end
