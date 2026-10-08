defmodule Ryker.Improvement.ExportTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.ControlPlane.{ActionRefusal, ConversationLab}
  alias Ryker.Evals.WorldCase
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{Candidate, Export}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Inspectors
  alias Ryker.RoutingExamples.Example

  @workspace "TIMPROVEEXPORT"
  @fixture "test/ryker/improvement/fixtures/emisar_access_correction.json"
  @catalog "testdata/scenarios/va1-health-review-repairs-and-finishes/tool-catalog.json"

  @diagnosis [
    category: :host_bug,
    step: :work,
    confidence: :medium,
    what_went_wrong:
      "They asked for an infrastructure health check; Ryker asked for Google Cloud access although Emisar was connected, because no Emisar tool reached the Work turn.",
    expected:
      "Checks infrastructure health through the connected Emisar runners and does not ask for access it already has."
  ]

  # Andrew, 2026-09-27: "we need evals building based on sentiment and
  # self-analysis". An accepted case is only worth accepting if a developer
  # can drop it into testdata/scenarios and run it: the files must load as a
  # world case, with the person's words, the renamed people and the model's
  # expectation, and without the correction that followed the bad answer.

  # A case's directory took its id's first eight hex digits; with UUIDv7 ids
  # those are a timestamp, so two cases decided within a minute wrote into
  # one directory and the second overwrote the first (2026-10-08, caught by
  # the gate before it shipped).
  test "two cases decided in the same minute export to two directories" do
    decided_at = ~U[2026-10-08 12:00:00.000000Z]
    first = %Candidate{id: Repo.generate_id(), decided_at: decided_at}
    second = %Candidate{id: Repo.generate_id(), decided_at: decided_at}

    assert binary_part(first.id, 0, 8) == binary_part(second.id, 0, 8)
    refute Export.case_id(first) == Export.case_id(second)
  end

  test "an accepted case exports as a world scenario the eval runner loads" do
    {candidate, first} = harvested_request!()
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert accepted.status == :accepted
    assert accepted.decided_by == "control-plane:local"

    root = tmp_dir!()
    assert Export.write(Path.join(root, "cases")) == {:ok, 1}
    File.mkdir_p!(Path.join([root, "cases", "va1-health-review-repairs-and-finishes"]))

    File.cp!(
      @catalog,
      Path.join([root, "cases", "va1-health-review-repairs-and-finishes", "tool-catalog.json"])
    )

    id = Export.case_id(accepted)
    assert {:ok, scenario} = WorldCase.load(Path.join([root, "cases", id]))
    assert scenario.id == id
    assert scenario.provenance["kind"] == "production"
    assert scenario.provenance["episode_refs"] == [accepted.request_ref]

    # The person's words up to their first negative feedback: the complaint
    # that followed the bad answer is left out, so the eval asks the same
    # question the person asked, not the correction.
    assert [event] = scenario.events
    assert event["payload"]["text"] == "<@U-ryker> check health of our infra"
    assert event["occurred_at"] == DateTime.to_iso8601(first.occurred_at)
    assert scenario.clock["start"] == event["occurred_at"]
    assert event["destination"]["conversation_ref"] == "slack:TEVAL:CEVAL"
    assert event["destination"]["thread_ref"] == first.destination_thread_ref
    assert [%{"actor_ref" => "slack:user:U-person-1"}] = scenario.actors

    assert scenario.expect["quality_rubric"] == [
             %{"criterion" => @diagnosis[:expected], "weight" => 3}
           ]

    assert scenario.tags == ["model-world", "feedback-harvested", "work", "host_bug"]
    assert scenario.host_replay == %{"model_events" => []}

    # Nothing real about the people or the workspace leaves in the files.
    for path <- Path.wildcard(Path.join([root, "cases", id, "*"])) do
      contents = File.read!(path)
      refute contents =~ "UEXPORTPERSON", path
      refute contents =~ @workspace, path
      refute contents =~ "UEXPORTBOT", path
    end

    # The exact routing prompt and answer travel beside the scenario.
    fixture = @fixture |> File.read!() |> Jason.decode!()

    routing =
      [id, "routing.json"]
      |> then(&Path.join([root, "cases" | &1]))
      |> File.read!()
      |> Jason.decode!()

    assert [%{"prompt" => prompt, "answer" => answer}] = routing
    assert prompt == hd(fixture["routing"])["prompt"]
    assert answer == hd(fixture["routing"])["answer"]

    provenance = File.read!(Path.join([root, "cases", id, "PROVENANCE.md"]))
    assert provenance =~ @diagnosis[:what_went_wrong]
    assert provenance =~ "Category: host bug. Step: work."
    assert provenance =~ "world.repositories"
    assert provenance =~ "I found Emisar’s recent alerts"

    # The download holds the same files.
    assert {:ok, archive} = Export.zip()
    assert {:ok, entries} = :zip.unzip(archive, [:memory])

    assert Enum.sort(Enum.map(entries, &to_string(elem(&1, 0)))) ==
             Enum.sort(
               for name <- ~w(PROVENANCE.md routing.json scenario.json tool-catalog.json),
                   do: "#{id}/#{name}"
             )
  end

  # Chat is the other place people talk to Ryker; its case replays as the
  # local operator in the same conversation, the way the world runner feeds
  # Chat inputs.
  test "a Chat request exports as a world scenario the eval runner loads" do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "export-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    conversation = Ecto.UUID.generate()

    {:ok, %{entry: question}} =
      ConversationLab.send_message(
        conversation,
        "Summarize the deploy",
        profile
      )

    reply =
      Answers.work_reply!(
        question,
        "Nothing was deployed.",
        "control-plane-reply:#{conversation}",
        DateTime.add(question.occurred_at, 30, :second)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "local-operator",
               source: "control_plane",
               source_ref: "control-plane-reaction:#{conversation}",
               occurred_at: DateTime.add(question.occurred_at, 60, :second),
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    root = tmp_dir!()
    assert Export.write(Path.join(root, "cases")) == {:ok, 1}
    File.mkdir_p!(Path.join([root, "cases", "va1-health-review-repairs-and-finishes"]))

    File.cp!(
      @catalog,
      Path.join([root, "cases", "va1-health-review-repairs-and-finishes", "tool-catalog.json"])
    )

    assert {:ok, scenario} = WorldCase.load(Path.join([root, "cases", Export.case_id(accepted)]))
    assert [%{"actor_ref" => "control_plane:user:local-operator"} = event] = scenario.events
    assert event["payload"]["text"] == "Summarize the deploy"
    assert event["destination"]["transport"] == "control_plane"
    assert event["destination"]["conversation_ref"] == question.destination_conversation_ref
  end

  # The case files are meant for the public repository, and only Slack ids
  # found in the person's messages and routing were renamed. Ryker's answers,
  # feedback notes, the diagnosis and the expectation went out as written, and
  # a Chat person kept their sign-in name (2026-10-04 review).
  test "no real person, workspace or channel leaves in any file of a case" do
    {candidate, _first} = harvested_request!()

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: [
        what_went_wrong:
          "Ryker answered <@UEXPORTOTHER1> in CEXPORTPRIV9 instead of UEXPORTPERSON.",
        expected: "Answers UEXPORTPERSON in the thread, not <#CEXPORTPRIV9|private>."
      ]
    )

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert {:ok, _scenario} = exported!(accepted)

    chat = chat_case!("tailscale:alice@example.com")
    assert {:ok, chat_scenario} = exported!(chat)
    assert [%{"actor_ref" => "control_plane:user:" <> person}] = chat_scenario.events
    refute person =~ "alice"

    files = for case <- [accepted, chat], {_path, contents} <- Export.files(case), do: contents
    contents = IO.iodata_to_binary(files)

    for real <-
          ~w(UEXPORTPERSON UEXPORTOTHER1 CEXPORTPRIV9 CEXPORTOPS alice@example.com) ++
            [@workspace],
        do: refute(contents =~ real, "#{real} left in the files")
  end

  # A request's messages expire at the operational horizon; a case accepted
  # before then keeps the words it was accepted on.
  test "accepting keeps the evidence, so the case outlives the request's messages" do
    {candidate, _first} = harvested_request!()
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    Repo.update_all(from(entry in Entry, where: entry.episode_id == ^candidate.episode_id),
      set: [content: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    [{_path, scenario} | _rest] = Export.files(Repo.get!(Candidate, accepted.id))
    assert IO.iodata_to_binary(scenario) =~ "check health of our infra"
  end

  test "a dismissed candidate keeps its record, is never exported, and can still be accepted" do
    {candidate, _first} = harvested_request!()

    assert {:ok, dismissed} = Improvement.dismiss(candidate.id, "control-plane:local")
    assert dismissed.status == :dismissed
    assert Repo.get(Candidate, candidate.id)
    assert Export.accepted() == []

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert accepted.status == :accepted
    assert [%Candidate{id: id}] = Export.accepted()
    assert id == candidate.id

    # Dismissing an accepted case gives up the evidence it kept.
    assert {:ok, again} = Improvement.dismiss(candidate.id, "control-plane:local")
    assert again.case_evidence == nil
    assert Export.accepted() == []

    assert Improvement.accept(Ecto.UUID.generate(), "control-plane:local") ==
             {:error, :improvement_candidate_not_found}
  end

  # A case replays the person's words; once they deleted every one of them
  # there is nothing to replay, and accepting says so rather than keeping an
  # empty case that the download would silently leave out.
  test "a request whose words were all deleted cannot become an eval case" do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Why is checkout slow?",
        ts: "1790200950.000100"
      )

    reply =
      Answers.work_reply!(
        question,
        "Checkout is fine.",
        "1790200950.000200",
        DateTime.add(question.occurred_at, 60, :second)
      )

    Answers.slack_message!(
      workspace: @workspace,
      channel: "CEXPORTOPS",
      actor: "UEXPORTPERSON",
      text: "",
      ts: "1790200950.000100",
      kind: :delete,
      revision: 2,
      at: DateTime.add(question.occurred_at, 120, :second)
    )

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})
    assert candidate.reasons == ["edited"]

    assert Improvement.accept(candidate.id, "control-plane:local") ==
             {:error, :improvement_evidence_unavailable}

    assert Repo.get!(Candidate, candidate.id).status == :open
    assert {:ok, _dismissed} = Improvement.dismiss(candidate.id, "control-plane:local")
  end

  # Routing answers an edited message with a turn of its own, so a quick
  # reply to an edit is a request whose only message is that edit. Its case
  # exported no events, which the world runner refuses, and one refused
  # directory stops every world scenario from loading (found in review,
  # 2026-09-27).
  test "a request whose only message is an edit exports as that message, and loads" do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Count to 10",
        ts: "1790200960.000100"
      )

    Answers.quick_reply!(
      question,
      "1, 2, 3, 4, 5, 6, 7, 8, 9, 10.",
      "1790200960.000200",
      DateTime.add(question.occurred_at, 5, :second)
    )

    edit =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Count to 20",
        ts: "1790200960.000100",
        kind: :edit,
        revision: 2,
        at: DateTime.add(question.occurred_at, 30, :second)
      )

    Answers.quick_reply!(
      edit,
      "1, 2, 3, 4, 5, 6, 7, 8, 9, 10.",
      "1790200960.000300",
      DateTime.add(question.occurred_at, 35, :second)
    )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UEXPORTPERSON",
               source: "slack",
               source_ref: "slack-event:export-edit-thumbs-down",
               occurred_at: DateTime.add(question.occurred_at, 60, :second),
               request: {:input, edit.id}
             })

    candidate = Inspectors.improvement_candidate({:input, edit.id})
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    assert {:ok, scenario} = exported!(accepted)
    assert [event] = scenario.events
    assert event["payload"]["text"] == "Count to 20"
    assert event["occurred_at"] == DateTime.to_iso8601(edit.occurred_at)
  end

  # A person who fixes their question before Ryker answers sent one message,
  # not two: the case replays it once, as it read when Ryker answered, at
  # the time it was first sent.
  test "a message edited before the feedback exports once, as it then read" do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Is the staging databse healthy?",
        ts: "1790200970.000100"
      )

    edit =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Is the staging database healthy?",
        ts: "1790200970.000100",
        kind: :edit,
        revision: 2,
        at: DateTime.add(question.occurred_at, 10, :second)
      )

    reply =
      Answers.work_reply!(
        question,
        "The production database is healthy.",
        "1790200970.000200",
        DateTime.add(question.occurred_at, 60, :second)
      )

    Answers.join!(edit, reply.episode.id)

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :sentiment,
               value: "angry",
               note: "They are upset that Ryker checked production.",
               actor_ref: "UEXPORTPERSON",
               source: "slack",
               source_ref: "slack-event:export-edit-angry",
               occurred_at: DateTime.add(question.occurred_at, 180, :second),
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    assert {:ok, scenario} = exported!(accepted)
    assert [event] = scenario.events
    assert event["payload"]["text"] == "Is the staging database healthy?"
    assert event["occurred_at"] == DateTime.to_iso8601(question.occurred_at)
  end

  # A person who edits their question after a wrong answer takes its first
  # words back, and the edit is what makes the request a candidate. The case
  # replayed those words for as long as training data is kept; it now sends
  # the message when it was first sent, in the words the person left.
  test "a message edited after the answer replays when first sent, in the words the person left" do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Is the payroll box healthy?",
        ts: "1790200980.000100"
      )

    reply =
      Answers.work_reply!(
        question,
        "The payroll box is healthy.",
        "1790200980.000200",
        DateTime.add(question.occurred_at, 60, :second)
      )

    edit =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: "Is the billing box healthy?",
        ts: "1790200980.000100",
        kind: :edit,
        revision: 2,
        at: DateTime.add(question.occurred_at, 120, :second)
      )

    Answers.join!(edit, reply.episode.id)

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})
    assert candidate.reasons == ["edited"]
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    assert {:ok, scenario} = exported!(accepted)
    assert [event] = scenario.events
    assert event["payload"]["text"] == "Is the billing box healthy?"
    assert event["occurred_at"] == DateTime.to_iso8601(question.occurred_at)

    files = accepted |> Export.files() |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    refute files =~ "Is the payroll box healthy?"
  end

  # A world scenario replays Slack and Chat messages; a GitHub comment has
  # other fields the export does not write yet. Accepting one would keep a
  # case whose scenario the world runner refuses, and one refused directory
  # stops every world scenario from loading, so accepting says why instead.
  test "a GitHub request cannot be kept as an eval case yet, and accepting says why" do
    entry = Answers.github_message!(body: "@ryker why did the payments export fail on PR 42?")

    reply =
      Answers.work_reply!(
        entry,
        "It timed out.",
        "github:issue_comment:#{System.unique_integer([:positive])}",
        DateTime.add(entry.occurred_at, 60, :second)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reviewed,
               value: "needs_work",
               actor_ref: "control-plane:local",
               source: "control_plane",
               source_ref: "episode-review:#{Ecto.UUID.generate()}",
               occurred_at: DateTime.add(entry.occurred_at, 120, :second),
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})

    assert Improvement.accept(candidate.id, "control-plane:local") ==
             {:error, :improvement_case_unsupported}

    assert ActionRefusal.explain(:improvement_case_unsupported) =~
             "GitHub requests cannot be kept as eval cases yet"

    assert Repo.get!(Candidate, candidate.id).status == :open
    assert Export.accepted() == []
  end

  # The harvested correction: a person asks Ryker to check their
  # infrastructure, Ryker asks for access it already has, and the person
  # says so. Their first message's routing example is kept.
  defp harvested_request! do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [ask, correction | _rest] = fixture["messages"]
    [first_reply | _replies] = fixture["replies"]
    ts = "1790200#{System.unique_integer([:positive]) |> rem(900) |> Kernel.+(100)}.000100"

    first =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: String.replace(ask["text"], "URYKER", "UEXPORTBOT"),
        ts: ts
      )

    Repo.update_all(from(entry in Entry, where: entry.id == ^first.id),
      set: [slack_audience: :mention, slack_bot_user_ref: "UEXPORTBOT"]
    )

    reply =
      Answers.work_reply!(
        first,
        first_reply["text"],
        String.replace(ts, ".000100", ".000200"),
        DateTime.add(first.occurred_at, 60, :second)
      )

    later =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CEXPORTOPS",
        actor: "UEXPORTPERSON",
        text: correction["text"],
        ts: String.replace(ts, ".000100", ".000300"),
        thread: first.destination_thread_ref,
        at: DateTime.add(first.occurred_at, 120, :second)
      )

    Answers.join!(later, reply.episode.id)

    [routing | _rest] = fixture["routing"]

    Repo.insert!(%Example{
      id: Ecto.UUID.generate(),
      input_id: first.id,
      episode_id: reply.episode.id,
      episode_ref: reply.episode.key,
      source_identity: String.duplicate("c", 64),
      message_keys: [],
      conversation_refs: [first.destination_conversation_ref],
      transport: "slack",
      conversation_ref: first.destination_conversation_ref,
      execution_mode: :live,
      policy: "ryker-admission",
      policy_digest: String.duplicate("d", 64),
      execution_target: routing["model"],
      prompt: routing["prompt"],
      output_schema: %{"type" => "object"},
      answer: routing["answer"],
      rejected_answers: [],
      decision: %{"action" => "start_episode"},
      outcome: %{"request" => "complete"},
      usage: %{},
      decided_at: DateTime.add(first.occurred_at, 20, :second)
    })

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :sentiment,
               value: "frustrated",
               note: "They say Ryker already has the access it asked for.",
               actor_ref: "UEXPORTPERSON",
               source: "slack",
               source_ref: "ingress-input:" <> later.id,
               occurred_at: later.occurred_at,
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: Keyword.merge(@diagnosis, analysis: :done, analyzed_at: DateTime.utc_now())
    )

    {Repo.get!(Candidate, candidate.id), first}
  end

  # A Chat request from `actor`, answered and disliked, then accepted.
  defp chat_case!(actor) do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "export-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    conversation = Ecto.UUID.generate()

    {:ok, %{entry: question}} =
      ConversationLab.send_message(conversation, "Summarize the deploy", profile, actor: actor)

    reply =
      Answers.work_reply!(
        question,
        "Nothing was deployed.",
        "control-plane-reply:#{conversation}",
        DateTime.add(question.occurred_at, 30, :second)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: actor,
               source: "control_plane",
               source_ref: "control-plane-reaction:#{conversation}",
               occurred_at: DateTime.add(question.occurred_at, 60, :second),
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    accepted
  end

  # Every accepted case written where the world runner reads them, beside the
  # catalog they refer to, and `accepted`'s loaded as the runner loads it.
  defp exported!(accepted) do
    root = tmp_dir!()
    assert {:ok, _count} = Export.write(Path.join(root, "cases"))
    File.mkdir_p!(Path.join([root, "cases", "va1-health-review-repairs-and-finishes"]))

    File.cp!(
      @catalog,
      Path.join([root, "cases", "va1-health-review-repairs-and-finishes", "tool-catalog.json"])
    )

    for directory <- Path.wildcard(Path.join([root, "cases", "feedback-*"])),
        do: assert({:ok, _scenario} = WorldCase.load(directory), directory)

    WorldCase.load(Path.join([root, "cases", Export.case_id(accepted)]))
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "improvement-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
