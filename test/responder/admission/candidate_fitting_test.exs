defmodule Responder.Admission.CandidateFittingTest do
  use ExUnit.Case, async: true

  alias Responder.Admission.{Candidate, Context, Prompt}
  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.LearningSources

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "twenty escaped candidates and source receipts fit both frozen and submitted bounds" do
    # Explicit generated serialization-boundary data, not a claimed source or model
    # answer. Prompt-only fitting previously left the larger frozen snapshot unchecked.
    context = context!(current: String.duplicate("\\", 24_570), sources: receipts())
    fitted = Prompt.fit(context)
    request = Prompt.build(context)

    assert length(fitted.candidates) == 20

    assert Enum.map(fitted.candidates, &{&1.ref, &1.allowed_relations, &1.same_thread}) ==
             Enum.map(context.candidates, &{&1.ref, &1.allowed_relations, &1.same_thread})

    assert fitted.source_dependencies == context.source_dependencies
    assert fitted.slack_addressing == context.slack_addressing
    assert byte_size(CanonicalJSON.encode!(Context.snapshot(fitted))) <= 98_304
    assert byte_size(CanonicalJSON.encode!(request)) <= 65_536
    assert request["context"] == Context.for_model(fitted)
    assert request == Prompt.build(fitted)
    assert Prompt.fit(fitted) == fitted
    assert fitted.knowledge != []

    for candidate <- fitted.candidates,
        preview <- [candidate.first_input_preview, candidate.latest_input_preview] do
      assert byte_size(preview["content_preview"]) in 256..4_096
      assert String.valid?(preview["content_preview"])
      assert preview["truncated"]
    end
  end

  test "useful ranked memory is retained before optional candidate expansion" do
    context = context!(memory_size: 250)
    fitted = Prompt.fit(context)

    assert fitted.observations == context.observations
    assert fitted.knowledge == context.knowledge

    assert Enum.all?(
             fitted.candidates,
             &(byte_size(&1.first_input_preview["content_preview"]) < 4_096)
           )

    assert Enum.all?(
             fitted.candidates,
             &(byte_size(&1.first_input_preview["content_preview"]) >= 256)
           )

    assert Prompt.build(fitted)["context"] == Context.for_model(fitted)
  end

  test "source receipt bytes can bind the snapshot before the prompt reaches its own limit" do
    context = context!(sources: receipts(), memory_size: 0)
    fitted = Prompt.fit(context)
    snapshot_bytes = byte_size(CanonicalJSON.encode!(Context.snapshot(fitted)))
    prompt_bytes = byte_size(CanonicalJSON.encode!(Prompt.build(fitted)))
    assert snapshot_bytes in 98_000..98_304
    assert prompt_bytes < 60_000

    ceiling = byte_size(hd(fitted.candidates).first_input_preview["content_preview"])

    wider = %{
      fitted
      | candidates: Enum.map(context.candidates, &Candidate.with_preview_limit(&1, ceiling + 1))
    }

    assert byte_size(CanonicalJSON.encode!(Context.snapshot(wider))) > 98_304
    assert fitted.source_dependencies == context.source_dependencies
  end

  test "restoring a fitted context preserves preview strings after episode and entry changes" do
    fitted = context!() |> Prompt.fit()
    snapshot = Context.snapshot(fitted)
    request = Prompt.build(fitted)

    episodes =
      Map.new(
        fitted.candidates,
        &{&1.episode.id, %{&1.episode | state: :cancelled, updated_at: DateTime.add(@now, 3_600)}}
      )

    changed_entry = %{fitted.input_entry | slack_audience: :mention, slack_bot_user_ref: "UNEW"}
    assert {:ok, restored} = Context.restore(snapshot, fitted.input, changed_entry, episodes)

    assert restored.fitted?
    assert Enum.all?(restored.candidates, &(&1.source_documents == []))
    assert Context.snapshot(restored) == snapshot
    assert Prompt.fit(restored) == restored
    assert Prompt.build(restored) == request
    refute Map.has_key?(snapshot, "fitted?")
  end

  test "saved short previews never expand and existing outgoing memory trimming stays reproducible" do
    context = context!(current: String.duplicate("\\", 24_570))

    context = %{
      context
      | candidates: Enum.map(context.candidates, &Candidate.with_preview_limit(&1, 256))
    }

    snapshot = Context.snapshot(context)
    episodes = Map.new(context.candidates, &{&1.episode.id, &1.episode})

    assert {:ok, restored} =
             Context.restore(snapshot, context.input, context.input_entry, episodes)

    request = Prompt.build(restored)

    assert request["context"]["candidates"] ==
             Enum.map(context.candidates, &Candidate.for_model/1)

    assert request["context"]["conversation_observations"] == []
    assert length(request["context"]["conversation_knowledge"]) < length(context.knowledge)
    assert Context.snapshot(restored) == snapshot
    assert Prompt.build(restored) == request
  end

  test "a restored request over the prompt limit fails instead of narrowing its saved previews" do
    context = context!(current: String.duplicate("\\", 24_570), memory_size: 0)

    context = %{
      context
      | candidates: Enum.map(context.candidates, &Candidate.with_preview_limit(&1, 900))
    }

    snapshot = Context.snapshot(context)
    assert byte_size(CanonicalJSON.encode!(snapshot)) <= 98_304
    episodes = Map.new(context.candidates, &{&1.episode.id, &1.episode})

    assert {:ok, restored} =
             Context.restore(snapshot, context.input, context.input_entry, episodes)

    assert_raise ArgumentError, ~r/admission prompt exceeds its bound/, fn ->
      Prompt.build(restored)
    end

    assert Context.snapshot(restored) == snapshot
  end

  test "required context that cannot fit is rejected without dropping candidates or receipts" do
    context = context!(memory_size: 0)
    too_many = %{context | candidates: context.candidates ++ [hd(context.candidates)]}
    assert_raise ArgumentError, ~r/more than 20 candidates/, fn -> Prompt.fit(too_many) end

    oversized = %{
      context
      | source_dependencies: [%{"invalid_host_receipt" => String.duplicate("x", 98_304)}]
    }

    assert_raise ArgumentError, ~r/required context or source receipts do not fit/, fn ->
      Prompt.fit(oversized)
    end
  end

  test "complete short endpoint text and absent endpoints keep truthful truncation flags" do
    context = context!(candidate_count: 1, source: "Complete source", memory_size: 0)
    [candidate] = context.candidates
    context = %{context | candidates: [%{candidate | latest_input_preview: nil}]}
    [fitted] = Prompt.fit(context).candidates
    assert fitted.first_input_preview == candidate.first_input_preview
    refute fitted.first_input_preview["truncated"]
    assert fitted.latest_input_preview == nil
  end

  defp context!(options \\ []) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: %{"text" => Keyword.get(options, :current, "Current message")},
               event_kind: :message,
               event_ref: "Ev-size-boundary",
               message_ref: "1787832000.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    endpoint = %{
      occurred_at: @now,
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => Keyword.get(options, :source, String.duplicate("\\", 20_000))},
          "event_kind" => "message"
        }
      }
    }

    candidates =
      for _ <- 1..Keyword.get(options, :candidate_count, 20) do
        episode = %Episode{
          id: Ecto.UUID.generate(),
          destination_thread_ref: "older-thread",
          state: :working,
          updated_at: @now
        }

        Candidate.new(%{
          allowed_relations:
            Candidate.allowed_relations(episode, %{
              continuation_window: 1_800,
              input_repository: nil,
              now: @now,
              pinned_repository: nil,
              source_owner: false
            }),
          digest: nil,
          endpoints: %{first: endpoint, latest: endpoint},
          episode: episode,
          match: %{},
          same_thread: episode.destination_thread_ref == "current-thread",
          source_owner: false
        })
      end

    size = Keyword.get(options, :memory_size, 1_200)

    note = %{
      "summary" => String.duplicate("\\", size),
      "topics" => Enum.map(1..8, &("topic-" <> Integer.to_string(&1)))
    }

    %Context{
      active_episode_fingerprint: CanonicalJSON.digest([]),
      built_at: @now,
      candidates: candidates,
      conversation_episode_count: length(candidates),
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()},
      slack_addressing: %{
        "audience" => "ambient",
        "responder_user_ref" => String.duplicate("U", 256)
      },
      observations: if(size == 0, do: [], else: List.duplicate(note, 5)),
      knowledge:
        if(size == 0, do: [], else: List.duplicate(Map.put(note, "title", "Known subject"), 8)),
      source_dependencies: Keyword.get(options, :sources, [])
    }
  end

  defp receipts do
    # Host-metadata size fixtures only; IDs are not asserted to authorize real data.
    sources =
      for _ <- 1..128 do
        %{
          "observation_id" => Ecto.UUID.generate(),
          "source_input_id" => Ecto.UUID.generate(),
          "revision" => 1,
          "fingerprint" => String.duplicate("a", 64),
          "transport" => "slack",
          "workspace_ref" => "slack:T123",
          "conversation_ref" => "slack:T123:C456",
          "repository_ref" => String.duplicate("r", 120),
          "visibility" => "public",
          "retained_at" => DateTime.to_iso8601(@now)
        }
      end

    assert is_list(LearningSources.merge([sources]))
    assert byte_size(CanonicalJSON.encode!(sources)) in 64_000..65_536
    sources
  end
end
