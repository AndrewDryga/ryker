defmodule Ryker.Improvement.ExportTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Evals.WorldCase
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{Candidate, Export}
  alias Ryker.Ingress.Inbox.Entry
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
  test "an accepted case exports as a world scenario the eval runner loads" do
    {candidate, first} = harvested_request!()
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert accepted.status == :accepted
    assert accepted.decided_by == "control-plane:local"

    root = tmp_dir!()
    assert {:ok, 1} = Export.write(Path.join(root, "cases"))
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
      Ryker.Ingress.WorkProfile.new(%{
        policy: "export-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    conversation = Ecto.UUID.generate()

    {:ok, %{entry: question}} =
      Ryker.ControlPlane.ConversationLab.send_message(
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

    candidate = Improvement.for_request({:episode, reply.episode.id})
    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")

    root = tmp_dir!()
    assert {:ok, 1} = Export.write(Path.join(root, "cases"))
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

    candidate = Improvement.for_request({:episode, reply.episode.id})
    assert candidate.reasons == ["edited"]

    assert Improvement.accept(candidate.id, "control-plane:local") ==
             {:error, :improvement_evidence_unavailable}

    assert Repo.get!(Candidate, candidate.id).status == :open
    assert {:ok, _dismissed} = Improvement.dismiss(candidate.id, "control-plane:local")
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

    candidate = Improvement.for_request({:episode, reply.episode.id})

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: Keyword.merge(@diagnosis, analysis: :done, analyzed_at: DateTime.utc_now())
    )

    {Repo.get!(Candidate, candidate.id), first}
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "improvement-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
