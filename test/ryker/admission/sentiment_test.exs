defmodule Ryker.Admission.SentimentTest do
  @moduledoc """
  Routing reads how a person feels about Ryker's previous answer, and the
  host keeps it as feedback on that answer's request (Andrew, 2026-09-27:
  "sentiment-analysis during router … use that sentiment as indirect
  feedback channel").

  The model's answer is an input, not a dependency. These tests replay
  routing results recorded on the live install
  (`testdata/admission/sentiment`) and hold the host to three things: it
  asks only when a person's message follows one of Ryker's answers; a
  sentiment it can read is kept with the request that answered; and one that
  is missing or malformed is left out without a word, never corrected by
  Coop's schema check or the host's, and never changes or refuses the
  decision beside it.
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.Admission
  alias Ryker.Admission.{Context, Decision, Executor, Prompt}
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

  @moduletag isolation: "REPEATABLE READ"

  @workspace "TSENTIMENT"
  @readme "testdata/admission/sentiment/readme-publication-correction.json"
  @file_share "testdata/admission/sentiment/file-after-quick-answer.json"

  setup do
    %{channel: "CSENTIMENT#{System.unique_integer([:positive])}"}
  end

  test "a person's message after one of Ryker's answers is asked how they feel about it",
       %{channel: channel} do
    for path <- [@readme, @file_share] do
      fixture = fixture!(path)
      %{message: message, request: request} = seed!(fixture, channel)
      assert {:ok, context} = context!(message)

      assert context.previous_answer == %{
               "at" => fixture["previous_answer"]["at"],
               "message_ref" => fixture["previous_answer"]["ts"],
               "request" => request
             }

      prompt = Prompt.build(context)

      assert prompt["context"]["previous_answer"] == %{
               "at" => String.replace(fixture["previous_answer"]["at"], ~r/\.\d+Z$/, "Z")
             }

      assert prompt["instructions"] =~ "previous_answer is when Ryker last answered here"
      assert prompt["instructions"] =~ "sentiment is only noted"

      schema = schema(context)
      assert Map.has_key?(schema["properties"], "sentiment")
      refute "sentiment" in schema["required"]

      # A retried routing turn reads the same context back from what it froze.
      assert {:ok, restored} =
               Context.restore(
                 Context.snapshot(context),
                 context.input,
                 context.input_entry,
                 episodes(context)
               )

      assert restored.previous_answer == context.previous_answer
      assert Context.for_model(restored) == Context.for_model(context)
    end
  end

  test "the sender's sentiment is kept with the request that answered, and the decision is the same without it",
       %{channel: channel} do
    fixture = fixture!(@readme)
    %{message: message, request: %{"episode_id" => answered}} = seed!(fixture, channel)
    assert {:ok, context} = context!(message)
    candidate = Enum.find(context.candidates, &(&1.episode.id == answered))
    assert candidate, "the request that answered was not offered"

    recorded =
      fixture["recorded_result"]
      |> Jason.decode!()
      |> Map.merge(%{"episode_ref" => candidate.ref, "repository" => nil})

    result = Map.put(recorded, "sentiment", fixture["sentiment"])
    assert_coop_accepts(result, context)

    assert {:ok, decision} = Decision.parse(result)
    assert {:ok, without} = Decision.parse(recorded)
    assert decision.sentiment == %{feeling: :frustrated, reason: fixture["sentiment"]["reason"]}
    assert Decision.fingerprint(decision) == Decision.fingerprint(without)
    assert Decision.document(decision) == Decision.document(without)

    assert {:ok, committed} = Admission.commit(context, decision, "recorded:#{message.id}")
    assert committed.entry.decision_action == :start_episode
    refute Map.has_key?(committed.entry.decision_document, "sentiment")
    assert committed.entry.decision_fingerprint == Decision.fingerprint(without)

    assert [signal] = Feedback.for_request({:episode, answered})

    assert {signal.kind, signal.value, signal.category, signal.note} ==
             {:sentiment, "frustrated", :frustrated, fixture["sentiment"]["reason"]}

    assert {signal.actor_ref, signal.source, signal.source_ref, signal.occurred_at} ==
             {fixture["message"]["actor"], "slack", Inbox.ref(message), message.occurred_at}

    # It is about the answer before, never the request the message started.
    assert Feedback.for_request({:episode, committed.episode.id}) == []
  end

  # "a whole result discarded because confidence was 3 instead of 'high'"
  # (CLAUDE.md) is the failure this holds shut: a sentiment is optional, so a
  # mistyped one costs nothing but itself.
  test "a missing or malformed sentiment is left out and never refuses or changes the decision",
       %{channel: channel} do
    fixture = fixture!(@file_share)
    %{request: %{"input_id" => answered}} = seed!(fixture, channel)
    recorded = Jason.decode!(fixture["recorded_result"])
    {:ok, recorded_decision} = Decision.parse(recorded)

    variants = [
      {:absent, :none},
      {nil, :none},
      {"frustrated", :none},
      {3, :none},
      {[], :none},
      {%{"feeling" => "happy", "reason" => "They sound fine."}, :none},
      {%{"feeling" => "Frustrated", "reason" => "Wrong case."}, :none},
      {%{"reason" => "No feeling at all."}, :none},
      {%{"feeling" => "frustrated", "reason" => String.duplicate("a", 281)}, {:kept, nil}},
      {%{"feeling" => "satisfied", "reason" => "   "}, {:kept, nil}},
      {%{"feeling" => "neutral", "reason" => "They moved on.", "confidence" => 3},
       {:kept, "They moved on."}}
    ]

    for {{sentiment, expected}, index} <- Enum.with_index(variants, 1) do
      message = follow_up!(fixture, channel, index)
      assert {:ok, context} = context!(message)
      assert Context.sentiment_offered?(context)

      result =
        if sentiment == :absent, do: recorded, else: Map.put(recorded, "sentiment", sentiment)

      # Coop checks the same format before the host sees the result: nothing
      # about the sentiment makes it ask the model to correct its answer.
      assert_coop_accepts(result, context)

      assert {:ok, decision} = Decision.parse(result),
             "#{inspect(sentiment)} refused the routing result"

      assert Decision.fingerprint(decision) == Decision.fingerprint(recorded_decision)
      assert {:ok, selection} = Admission.validate(context, decision)
      assert selection.decision.action == :ignore
      assert {:ok, committed} = Admission.commit(context, decision, "recorded:#{message.id}")
      assert committed.entry.decision_action == :ignore

      kept =
        {:input, answered}
        |> Feedback.for_request()
        |> Enum.filter(&(&1.source_ref == Inbox.ref(message)))

      case expected do
        :none ->
          assert kept == [], "#{inspect(sentiment)} was kept"

        {:kept, note} ->
          assert [%{kind: :sentiment, note: ^note}] = kept
      end
    end
  end

  test "routing through Coop offers the sentiment, and one the model got wrong costs no correction",
       %{channel: channel} do
    fixture = fixture!(@file_share)
    %{message: first, request: %{"input_id" => answered}} = seed!(fixture, channel)
    recorded = Jason.decode!(fixture["recorded_result"])

    for {message, sentiment, kept} <- [
          {first, %{"feeling" => "annoyed", "reason" => "Not a feeling Ryker reads."}, []},
          {follow_up!(fixture, channel, 20),
           %{"feeling" => "neutral", "reason" => "They share a file after the count."},
           [{:sentiment, "neutral"}]}
        ] do
      lease_ref = claim!(message)
      candidate = recorded |> Map.put("sentiment", sentiment) |> Jason.encode!()
      {:ok, fake} = FakeAPI.start_link([candidate])

      options = executor_options(fake, lease_ref, DateTime.add(message.occurred_at, 3, :second))
      assert {:ok, execution} = Executor.run(Inbox.ref(message), options)
      assert execution.result.entry.decision_action == :ignore

      state = FakeAPI.state(fake)
      # Accepted at once: neither the host nor the format asked for another try.
      assert Enum.map(state.validations, & &1.verdict) == [:accept]
      assert Map.has_key?(state.schema["properties"], "sentiment")

      assert {:ok, _valid} =
               JSV.validate(Jason.decode!(candidate), JSV.build!(state.schema), cast: false)

      submitted = Jason.decode!(state.submitted_prompt)
      assert submitted["context"]["previous_answer"]["at"]
      assert submitted["instructions"] =~ "previous_answer is when Ryker last answered here"

      assert {:input, answered}
             |> Feedback.for_request()
             |> Enum.filter(&(&1.source_ref == Inbox.ref(message)))
             |> Enum.map(&{&1.kind, &1.value}) == kept

      # The routing card says what routing read, as the host kept it.
      assert {:ok, view} = ModelRequests.project_input(message.id, %{})
      html = render_component(&EpisodePage.message_page/1, view: view)

      if kept == [] do
        refute html =~ "Felt about the last answer"
      else
        assert html =~ "Felt about the last answer"
        assert html =~ "Neutral"
        assert html =~ "They share a file after the count."
      end
    end
  end

  test "an app, an edit, a first message or one after only an update is not asked how it feels",
       %{channel: channel} do
    fixture = fixture!(@readme)
    %{question: question, answer: answer} = seed!(fixture, channel)
    thread = question.destination_thread_ref

    first = message!(channel, "A new question with no answer before it", "1790512500.000100")

    app =
      message!(channel, "Deploy 42 finished", "1790512010.000100",
        thread: thread,
        actor: "B0APP",
        actor_kind: :app
      )

    edit =
      message!(channel, fixture["question"]["text"] <> " Please.", fixture["question"]["ts"],
        kind: :edit,
        revision: 2,
        at: Answers.slack_time("1790512020.000100")
      )

    Answers.post!(
      answer,
      "Still checking the replicas.",
      "1790512600.000100",
      Answers.slack_time("1790512600.000100"),
      thread: "1790512590.000100"
    )

    after_update =
      message!(channel, "Which replicas?", "1790512610.000100", thread: "1790512590.000100")

    for entry <- [first, app, edit, after_update] do
      assert {:ok, context} = context!(entry)
      refute Context.sentiment_offered?(context), "#{entry.content["text"]} was asked"
      prompt = Prompt.build(context)
      refute Map.has_key?(prompt["context"], "previous_answer")
      refute prompt["instructions"] =~ "previous_answer"
      refute Map.has_key?(schema(context)["properties"], "sentiment")
    end
  end

  # -- Scenario ------------------------------------------------------------------

  defp fixture!(path), do: path |> File.read!() |> Jason.decode!()

  # The question, the answer Ryker gave to it, and the person's next message.
  defp seed!(fixture, channel) do
    question =
      message!(channel, fixture["question"]["text"], fixture["question"]["ts"],
        thread: fixture["question"]["thread"],
        actor: fixture["question"]["actor"]
      )

    previous = fixture["previous_answer"]
    {:ok, at, 0} = DateTime.from_iso8601(previous["at"])

    {answer, request} =
      case previous["kind"] do
        "work_reply" ->
          answer = Answers.work_reply!(question, previous["text"], previous["ts"], at)
          {answer, %{"episode_id" => answer.episode.id}}

        "quick_reply" ->
          answer = Answers.quick_reply!(question, previous["text"], previous["ts"], at)
          {answer, %{"input_id" => question.id}}
      end

    %{
      question: question,
      answer: answer,
      request: request,
      message: follow_up!(fixture, channel, 0)
    }
  end

  # The person's next message; each index is a message of its own in the same
  # place, a second apart.
  defp follow_up!(fixture, channel, index) do
    {seconds, fraction} = Integer.parse(fixture["message"]["ts"])
    ts = "#{seconds + index}#{fraction}"

    options =
      [
        thread: fixture["message"]["thread"] || fixture["question"]["ts"],
        actor: fixture["message"]["actor"]
      ] ++
        if(fixture["message"]["content"],
          do: [content: fixture["message"]["content"]],
          else: [text: fixture["message"]["text"]]
        )

    message!(channel, Keyword.get(options, :text, ""), ts, options)
  end

  defp message!(channel, text, ts, options \\ []) do
    Answers.slack_message!(
      Keyword.merge([workspace: @workspace, channel: channel, text: text, ts: ts], options)
    )
  end

  defp context!(entry) do
    Admission.context(Inbox.ref(entry),
      now: DateTime.add(entry.occurred_at, 4, :second),
      continuation_window: 30 * 60,
      history_window: 30 * 24 * 60 * 60,
      candidate_limit: 20
    )
  end

  defp episodes(%{candidates: candidates}),
    do: candidates |> Enum.map(& &1.episode) |> Map.new(&{&1.id, &1})

  defp schema(context) do
    Decision.json_schema(
      Input.allowed_actions(context.input),
      Input.reaction_names(context.input),
      is_binary(context.input_entry.repository_ref),
      Enum.map(context.repository_choices, & &1["ref"]),
      Context.sentiment_offered?(context)
    )
  end

  # Coop validates the result against the attached format before the host
  # reads it; a result it refused would go back to the model for correction.
  defp assert_coop_accepts(result, context) do
    assert {:ok, _valid} = JSV.validate(result, JSV.build!(schema(context)), cast: false),
           "Coop would ask the model to correct #{inspect(result["sentiment"])}"
  end

  defp claim!(entry) do
    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("sentiment:test", DateTime.add(entry.occurred_at, 2, :second), 300)

    assert claimed.id == entry.id
    lease_ref
  end

  defp executor_options(fake, lease_ref, now) do
    [
      api: FakeAPI,
      client: fake,
      lease_ref: lease_ref,
      max_polls: 10,
      now: fn -> now end,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end
