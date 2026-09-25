defmodule Ryker.Admission.ReplayTest do
  # These harvested identities are also replayed by other modules. The sandbox
  # holds the seeded conversation lock across a later Inbox.record call, unlike
  # the separate production transactions. Two full gates hit that artificial
  # conversation/channel lock inversion; retain exact source identities serially.
  use Ryker.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Ryker.Admission
  alias Ryker.Admission.{Candidate, Context, Decision, Executor, Prompt}
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Ingress.{Inbox, Input, MessageText}
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

  @fixtures Path.wildcard(Path.expand("fixtures/*.json", __DIR__))

  for fixture_path <- @fixtures do
    @fixture_path fixture_path
    test Path.basename(fixture_path, ".json") do
      fixture = @fixture_path |> File.read!() |> Jason.decode!()
      validate_source!(fixture["source"])
      seed = seed_episode(fixture["seed"])
      input = input!(fixture["input"])

      if seed && fixture["input"]["actor"]["kind"] == "app" &&
           fixture["seed"]["input"]["actor"]["kind"] == "app" do
        assert get_in(
                 Admission.input_event_endpoints([seed.id]),
                 [seed.id, :first, :payload, "actor_ref"]
               ) == actor_ref(input)
      end

      assert {:ok, %{entry: entry}} = Inbox.record(input)
      now = datetime!(fixture["now"])

      assert {:ok, context} =
               Admission.context(Inbox.ref(entry),
                 now: now,
                 continuation_window: fixture["continuation_window_seconds"],
                 history_window: fixture["history_window_seconds"],
                 candidate_limit: 8
               )

      if Path.basename(@fixture_path) in [
           "new_cycle_links_history_only.json",
           "resolved_card_continues_active_episode.json",
           "terraform_lifecycle_continues_episode.json"
         ] do
        # The 256-byte preview hid the harvested Grafana start identity while the
        # prompt told the model to compare it. Routing success alone missed that loss.
        source = seed_text(fixture)
        assert byte_size(source) <= 4_096
        request = Prompt.build(context)
        offered = Enum.find(context.candidates, &(&1.episode.id == seed.id))

        candidate =
          Enum.find(request["context"]["candidates"], &(&1["episode_ref"] == offered.ref))

        assert candidate["first_message"]["text"] == source
        refute candidate["first_message"]["truncated"]
        assert byte_size(CanonicalJSON.encode!(request)) <= 65_536
      end

      decision = decision!(fixture["decision"], context, seed)
      decision_ref = "fixture-decision:#{entry.id}"
      assert {:ok, result} = Admission.commit(context, decision, decision_ref)
      assert actual(result, seed) == fixture["expected"]
    end

    if Path.basename(fixture_path) in [
         "new_cycle_links_history_only.json",
         "resolved_card_continues_active_episode.json",
         "terraform_lifecycle_continues_episode.json"
       ] do
      test "submitted and frozen source context agree for #{Path.basename(fixture_path, ".json")}" do
        fixture = @fixture_path |> File.read!() |> Jason.decode!()
        seed = seed_episode(fixture["seed"])
        input = input!(fixture["input"])
        now = datetime!(fixture["now"])
        assert {:ok, %{entry: entry}} = Inbox.record(input)

        assert {:ok, %{entry: claimed, lease_ref: lease}} =
                 Inbox.claim_next("candidate-source-test", now, 300)

        assert claimed.id == entry.id

        context_options = [
          now: now,
          lease_ref: lease,
          candidate_limit: 20,
          continuation_window: fixture["continuation_window_seconds"],
          history_window: fixture["history_window_seconds"]
        ]

        assert {:ok, context} = Admission.context(Inbox.ref(entry), context_options)
        decision = decision!(fixture["decision"], context, seed)
        {:ok, fake} = FakeAPI.start_link([decision |> Decision.document() |> Jason.encode!()])

        options =
          Keyword.merge(context_options,
            api: FakeAPI,
            client: fake,
            now: fn -> now end,
            policy: "admission-read-only",
            policy_digest: String.duplicate("a", 64),
            max_polls: 10,
            poll_interval_ms: 0,
            renew_lease: fn -> :ok end,
            sleep: fn _milliseconds -> :ok end
          )

        assert {:ok, execution} = Executor.run(Inbox.ref(entry), options)
        submitted = FakeAPI.state(fake).submitted_prompt
        # The instructions lead the text so they can be a cached prefix.
        assert submitted == Prompt.render(Prompt.build(context))
        assert String.starts_with?(submitted, ~s({"instructions":))
        assert execution.result.entry.admission_context == Context.snapshot(context)
        assert Jason.decode!(submitted)["context"] == Context.for_model(context)

        source = seed_text(fixture)

        assert [%{"first_message" => %{"text" => ^source} = first}] =
                 Jason.decode!(submitted)["context"]["candidates"]

        refute Map.has_key?(first, "truncated")

        assert actual(execution.result, seed) == fixture["expected"]
      end
    end
  end

  defp seed_text(fixture),
    do: fixture["seed"]["input"]["content"] |> MessageText.from() |> Candidate.model_text()

  defp seed_episode(nil), do: nil

  defp seed_episode(seed) do
    input = input!(seed["input"])

    admit = %Command.AdmitInput{
      actor_ref: actor_ref(input),
      destination: input.destination,
      episode_id: seed["episode_id"],
      episode_key: seed["episode_key"],
      linked_episode_id: nil,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: "fixture-turn:#{seed["episode_id"]}"
    }

    assert {:ok, _transition} = Episodes.apply(admit)

    if seed["state"] == "complete" do
      assert {:ok, _transition} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "Recorded fixture completed before the next Slack input.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: seed["episode_key"],
                 expected_turn_ref: admit.turn_ref,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(input.occurred_at, 1, :second),
                 result_ref: "fixture-result:#{seed["episode_id"]}"
               })
    end

    Repo.update_all(
      from(episode in Ryker.Episodes.Episode, where: episode.id == ^seed["episode_id"]),
      set: [updated_at: datetime!(seed["updated_at"])]
    )

    assert {:ok, episode} = Episodes.fetch_by_key(seed["episode_key"])
    episode
  end

  defp decision!(document, context, seed) do
    document =
      document
      |> Map.put_new("reaction", nil)
      |> then(fn document ->
        if document["episode_ref"] == "$seed" do
          candidate =
            Enum.find(context.candidates, &(&1.episode.id == seed.id)) ||
              flunk("seed episode was not offered to the model")

          Map.put(document, "episode_ref", candidate.ref)
        else
          document
        end
      end)

    assert {:ok, decision} = Decision.parse(document)
    decision
  end

  defp input!(document) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{
                 kind: parse_actor_kind(document["actor"]["kind"]),
                 ref: document["actor"]["ref"]
               },
               channel_ref: document["channel_ref"],
               content: document["content"],
               event_kind: parse_event_kind(document["event_kind"]),
               event_ref: document["event_ref"],
               message_ref: document["message_ref"],
               occurred_at: datetime!(document["occurred_at"]),
               revision: document["revision"],
               thread_ref: document["thread_ref"],
               workspace_ref: document["workspace_ref"]
             })

    input
  end

  defp actual(result, seed) do
    %{
      "active_inputs" => length(result.episode.active_input_refs),
      "decision_action" => Atom.to_string(result.entry.decision_action),
      "destination_thread_ref" => result.episode.destination_thread_ref,
      "episode_identity" => if(seed && result.episode.id == seed.id, do: "seed", else: "new"),
      "linked_to_seed" => not is_nil(seed) and result.episode.linked_episode_id == seed.id,
      "queued_inputs" => length(result.episode.queued_input_refs),
      "state" => Atom.to_string(result.episode.state)
    }
  end

  defp validate_source!(source) do
    assert source["database"] in ["blitz responder.db", "emisar responder.db"]
    assert is_binary(source["reason"]) and source["reason"] != ""
    assert is_list(source["slack_input_ids"]) and source["slack_input_ids"] != []
    assert Enum.all?(source["slack_input_ids"], &is_binary/1)
    assert is_list(source["run_ids"])
  end

  defp actor_ref(input), do: "slack:#{input.actor.kind}:#{input.actor.ref}"

  defp parse_actor_kind("user"), do: :user
  defp parse_actor_kind("app"), do: :app
  defp parse_actor_kind("bot"), do: :bot

  defp parse_event_kind("message"), do: :message
  defp parse_event_kind("edit"), do: :edit
  defp parse_event_kind("delete"), do: :delete

  defp datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end
end
