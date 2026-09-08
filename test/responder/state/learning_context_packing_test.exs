defmodule Responder.State.LearningContextPackingTest do
  use Responder.DataCase, async: false

  alias Responder.{CanonicalJSON, Episodes}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.RecallText

  alias Responder.State.{
    ConversationKnowledge,
    Knowledge,
    Learning,
    LearningRun,
    LearningSources,
    Observations
  }

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
  @fixture "testdata/learning/retained-auth-wal-context-packing.json"

  test "an oversized first topic does not hide an affordable later subject from learning" do
    # One actual replay batch lost all 25 selected topics because the first
    # needed 130 roots. The affordable auth subject needed only 20; hiding it
    # let the model recreate the same WAL monitor under a different topic key.
    %{entries: entries, heads: [large, affordable], selected: selected} = setup_topics!(9_998, 17)
    raw = raw_sources(entries)
    assert LearningSources.merge([raw, large.source_dependencies]) == nil
    expected_sources = LearningSources.merge([raw, affordable.source_dependencies])
    assert length(LearningSources.expand(expected_sources)) == 20

    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert Enum.map(run.knowledge, & &1["topic_key"]) == [affordable.topic_key]
    assert run.knowledge == [List.last(selected)]
    assert run.omissions == [omission(large)]
    assert run.source_dependencies == expected_sources
    assert Repo.get!(LearningRun, run.id) == run
    assert_prompt_matches!(run, entries)
    refute run.prompt =~ large.state["summary"]
    assert run.prompt =~ affordable.state["summary"]
    assert {:ok, ^run} = Learning.authorize(run.id)
    assert Repo.get!(ConversationKnowledge, large.id) == large
    assert Repo.get!(ConversationKnowledge, affordable.id) == affordable
  end

  test "topics that fit together retain their selection order and full source lineage" do
    %{entries: entries, selected: selected} = setup_topics!(10, 17)
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert run.knowledge == selected
    assert run.omissions == []
    assert length(run.source_dependencies) == 5
    assert length(LearningSources.expand(run.source_dependencies)) == 30
    assert_prompt_matches!(run, entries)
    assert {:ok, ^run} = Learning.authorize(run.id)
  end

  test "a required create-check match cannot be omitted to buy another blind judgment" do
    # Same harvested batch, with structural byte padding to fill the prompt.
    # Model output is not fabricated: this pins the host's matching correction.
    %{entries: [first | _] = entries, heads: [large, _]} = setup_topics!(10, 17)
    ids = Enum.map(entries, & &1.id)
    assert {:ok, baseline} = Learning.prepare(ids, @policy)

    raw_bytes =
      baseline.prompt
      |> Jason.decode!()
      |> Map.put("knowledge", [])
      |> CanonicalJSON.encode!()
      |> byte_size()

    Repo.update!(
      Ecto.Changeset.change(first,
        content: Map.put(first.content, "padding", String.duplicate("x", 65_536 - raw_bytes - 64))
      )
    )

    assert {:ok, run} = Learning.prepare(ids, @policy)
    assert run.knowledge == []

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :rejected,
        error_code: "learning_match_required",
        match_refs: ["knowledge:#{large.id}"]
      )
    )

    assert {:error, :learning_capacity_exceeded} = Learning.prepare(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 2
  end

  test "an affordable priority topic is not displaced when the next topic exceeds the remaining capacity" do
    %{entries: entries, heads: [priority, later], selected: selected} = setup_topics!(9_981, 17)
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert run.knowledge == [hd(selected)]
    assert run.omissions == [omission(later)]

    assert run.source_dependencies ==
             LearningSources.merge([raw_sources(entries), priority.source_dependencies])

    assert length(run.source_dependencies) == 4
    assert length(LearningSources.expand(run.source_dependencies)) == 9_984
    assert_prompt_matches!(run, entries)
    assert {:ok, ^run} = Learning.authorize(run.id)
  end

  defp setup_topics!(first_count, second_count) do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert CanonicalJSON.digest(fixture["original_prompt"]) ==
             fixture["provenance"]["prompt_sha256"]

    assert CanonicalJSON.digest(fixture["original_result"]) ==
             fixture["provenance"]["result_sha256"]

    entries = Enum.map(fixture["inputs"], &persist_input!/1)
    original_inputs = Jason.decode!(fixture["original_prompt"])["inputs"]
    assert Enum.map(original_inputs, & &1["source_input_id"]) == Enum.map(entries, & &1.id)
    assert Enum.map(original_inputs, & &1["content"]) == Enum.map(entries, & &1.content)

    # Topic prose and current messages are unchanged harvested data. Only the
    # historical identities/counts below are deterministic host capacity setup;
    # no model is called and no model result over this setup is invented.
    heads =
      fixture["topics"]
      |> Enum.zip([first_count, second_count])
      |> Enum.with_index()
      |> Enum.map(fn {{topic, count}, index} ->
        entry = Enum.at(entries, index)
        history = Enum.map(1..count, &historical_source!(entry, index * 10_001 + &1))
        seed_topic!(topic, history)
      end)

    entry = hd(entries)
    search = Enum.map(entries, &RecallText.from(&1.content))

    selected =
      Knowledge.context(entry, entry.repository_ref, {:related, search}, 32, "current_channel")

    expected_keys = fixture["prefit_order"] |> Enum.take(2) |> Enum.map(& &1["topic_key"])
    assert Enum.map(selected, & &1["topic_key"]) == expected_keys
    %{entries: entries, heads: heads, selected: selected}
  end

  defp seed_topic!(topic, history) do
    proposal =
      Map.merge(topic["state"], %{
        "topic_key" => topic["topic_key"],
        "target_ref" => nil,
        "anchors" => [],
        "expected_version" => 0
      })

    dependencies = raw_sources(history)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction([hd(history)], proposal, [], %{
                 result_ref: "host-context-packing-fixture",
                 source_dependencies: dependencies,
                 omissions: []
               })
             end)

    head = Repo.get_by!(ConversationKnowledge, topic_key: topic["topic_key"])
    assert head.state == Map.put(topic["state"], "anchors", [])
    assert LearningSources.expand(head.source_dependencies) == dependencies
    head
  end

  defp assert_prompt_matches!(run, entries) do
    prompt = Jason.decode!(run.prompt)
    assert byte_size(run.prompt) <= 65_536
    assert prompt["knowledge"] == run.knowledge
    assert Enum.map(prompt["inputs"], & &1["source_input_id"]) == Enum.map(entries, & &1.id)
    assert Enum.map(prompt["inputs"], & &1["content"]) == Enum.map(entries, & &1.content)

    assert run.source_dependencies ==
             LearningSources.merge([
               raw_sources(entries) | Enum.map(run.knowledge, &LearningSources.document_sources/1)
             ])
  end

  defp raw_sources(entries),
    do: entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

  defp persist_input!(raw) do
    at = raw["occurred_at"] |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    persist_episode!(raw, at)

    fields =
      ~w(id episode_id dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id source_item_ref actor_ref revision content source_capabilities destination_transport destination_conversation_ref destination_thread_ref repository_ref work_policy work_policy_digest decision_ref decision_fingerprint decision_document status event_kind actor_kind occurred_at_source execution_mode decision_action)a

    attrs = Map.new(fields, &{&1, raw[Atom.to_string(&1)]})

    attrs =
      Enum.reduce(
        ~w(status event_kind actor_kind occurred_at_source execution_mode decision_action)a,
        attrs,
        fn field, attrs ->
          Map.update!(attrs, field, &String.to_existing_atom/1)
        end
      )

    entry = Repo.insert!(struct!(Entry, Map.put(attrs, :occurred_at, at)))
    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end

  defp persist_episode!(%{"episode_id" => nil}, _at), do: :ok

  defp persist_episode!(raw, at) do
    assert {:ok, %{episode: _}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: raw["episode_id"],
                 episode_key: "ingress-input:#{raw["id"]}",
                 native_input_id: raw["native_input_id"],
                 revision: raw["revision"],
                 occurred_at: at,
                 turn_ref: "ingress-turn:#{raw["id"]}",
                 payload: raw["content"],
                 destination: %{
                   transport: raw["destination_transport"],
                   conversation_ref: raw["destination_conversation_ref"],
                   thread_ref: raw["destination_thread_ref"]
                 }
               })
             )
  end

  defp historical_source!(entry, n) do
    identity = "host-context-packing-#{n}"

    attrs =
      entry
      |> Map.from_struct()
      |> Map.take(Entry.__schema__(:fields))
      |> Map.merge(%{
        id: "10000000-0000-4000-8000-#{String.pad_leading(to_string(n), 12, "0")}",
        dedupe_key: identity,
        native_input_id: identity,
        source_item_ref: identity,
        event_ref: identity,
        decision_ref: "host-context-packing-decision:#{n}",
        event_fingerprint: CanonicalJSON.digest(%{"fixture_identity" => identity}),
        occurred_at: DateTime.add(entry.occurred_at, -n, :second)
      })

    historical = Repo.insert!(struct!(Entry, attrs))

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.receive_in_transaction(historical) end)

    historical
  end

  defp omission(head) do
    %{
      "source_ref" => "knowledge:#{head.id}",
      "version" => head.version,
      "topic_key" => head.topic_key,
      "conversation_ref" => head.conversation_ref,
      "repository_ref" => head.repository_ref,
      "reason" => "source_capacity"
    }
  end
end
