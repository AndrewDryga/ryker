defmodule Ryker.Admission.PromptTest do
  use ExUnit.Case, async: true

  alias Ryker.Admission.{Candidate, Context, Prompt}
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput

  test "required custom instructions survive fitting before optional conversation knowledge" do
    text = String.duplicate("\"\\\n🌱", 500)

    instructions = %{
      "global" => %{"scope" => "global", "revision" => 1, "text" => text},
      "channel" => %{"scope" => "slack:T1:C1", "revision" => 2, "text" => text}
    }

    context =
      %Context{
        active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
        built_at: ~U[2026-08-27 12:00:01.000000Z],
        candidates: [],
        conversation_episode_count: 0,
        input: input!(%{"text" => String.duplicate("x", 45_000)}),
        input_entry: %Entry{id: Ecto.UUID.generate()},
        knowledge: [%{"summary" => String.duplicate("k", 50_000)}]
      }
      |> Map.put(:custom_instructions, instructions)

    request = Prompt.build(context)
    assert request["context"]["custom_instructions"] == instructions
    assert byte_size(Ryker.CanonicalJSON.encode!(request)) <= 65_536
    assert request["instructions"] =~ "replaces earlier custom instructions"
    assert request["instructions"] =~ "do not grant permissions"
  end

  test "addressing remains visible outside a truncated input and does not grant authority" do
    input =
      input!(%{
        "text" => String.duplicate("x", 25_000),
        "attachments" => [%{"text" => String.duplicate("y", 23_000)}],
        "slack_addressing" => %{"audience" => "mention", "ryker_user_ref" => "UFORGED"}
      })

    addressing = %{"audience" => "ambient", "ryker_user_ref" => "UBOT"}

    context =
      %Context{
        active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
        built_at: ~U[2026-08-27 12:00:01.000000Z],
        candidates: [],
        conversation_episode_count: 0,
        input: input,
        input_entry: %Entry{id: Ecto.UUID.generate()}
      }
      |> Map.put(:slack_addressing, addressing)

    request = Prompt.build(context)
    assert request["context"]["slack_addressing"] == addressing
    assert request["context"]["input"]["content"]["truncated"]
    assert byte_size(Ryker.CanonicalJSON.encode!(request)) <= 65_536
    assert request["instructions"] =~ "host-configured"
    assert request["instructions"] =~ "another human is not automatically an assignment"

    assert request["instructions"] =~
             "An ambient audience does not mean\nRyker was not addressed"

    assert request["instructions"] =~ "does not grant mutation authority"
    assert request["instructions"] =~ "Preserve explicit requests to Ryker"
    assert request["instructions"] =~ "active-work continuations"
    assert request["instructions"] =~ "useful independent investigation"
  end

  test "gives every provider the same generic decision instructions without duplicating its schema" do
    input = input!()

    context = %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    request = Prompt.build(context)

    assert request["context"] == %{
             "allowed_actions" => [
               "start_episode",
               "continue_episode",
               "reply",
               "react",
               "ignore"
             ],
             "candidates" => [],
             "execution_mode" => "live",
             "input" => Input.model_document(input)
           }

    assert Map.keys(request) |> Enum.sort() == ["context", "instructions"]
    assert request["instructions"] =~ "Interpret the event itself"
    assert request["instructions"] =~ "notification controls, confirmation dialogs"
    assert request["instructions"] =~ "Preserve explicit human requests and trusted assignments"
    assert request["instructions"] =~ "Never ignore a request"
    assert request["instructions"] =~ "directed\n  at Ryker."
    assert request["instructions"] =~ "history_only"
    assert request["instructions"] =~ "explicit source identity"
    assert request["instructions"] =~ "do not ignore the event that closes active work"
    assert request["instructions"] =~ "different explicit run ID or alert start identity"
    assert request["instructions"] =~ "conversational: only with reply"
    assert request["instructions"] =~ "standard: the default for investigation"
    assert request["instructions"] =~ "deep: only when materially harder reasoning"

    assert request["instructions"] =~ "never changes repository, tools, credentials,"
    assert request["instructions"] =~ "or write authority"

    refute request["instructions"] =~ "Grafana"
    refute request["instructions"] =~ "Terraform"
  end

  test "keeps the complete admission request within one bounded model context" do
    input = input!(%{"text" => String.duplicate("x", 45_000)})

    endpoint = %{
      occurred_at: ~U[2026-08-27 11:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => String.duplicate("p", 20_000)},
          "event_kind" => "message"
        }
      }
    }

    candidates =
      for _index <- 1..20 do
        episode = %Episode{
          destination_thread_ref: "older-thread",
          id: Ecto.UUID.generate(),
          state: :working,
          updated_at: ~U[2026-08-27 12:00:00.000000Z]
        }

        Candidate.new(%{
          allowed_relations:
            Candidate.allowed_relations(episode, %{
              continuation_window: 1_800,
              input_repository: nil,
              now: ~U[2026-08-27 12:00:01.000000Z],
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

    context = %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: candidates,
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    assert Prompt.build(context) |> Jason.encode!() |> byte_size() <= 65_536
  end

  test "does not offer reactions to sources that cannot perform them" do
    input = %{
      input!()
      | source_capabilities: %{},
        source: %{kind: "webhook", ref: "universal"}
    }

    context = %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    request = Prompt.build(context)

    refute "react" in request["context"]["allowed_actions"]
  end

  test "the full candidate limit and escaped memory fit without dropping Slack addressing" do
    # The host admits 20 candidates; testing only eight missed its real budget boundary.
    # These are generated size-boundary strings, not claimed model answers or source fixtures.
    input = input!(%{"text" => String.duplicate("\\", 24_570)})

    endpoint = %{
      occurred_at: ~U[2026-08-27 11:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => String.duplicate("\\", 20_000)},
          "event_kind" => "message"
        }
      }
    }

    candidates =
      for _index <- 1..20 do
        episode = %Episode{
          destination_thread_ref: "older-thread",
          id: Ecto.UUID.generate(),
          state: :working,
          updated_at: ~U[2026-08-27 12:00:00.000000Z]
        }

        Candidate.new(%{
          allowed_relations:
            Candidate.allowed_relations(episode, %{
              continuation_window: 1_800,
              input_repository: nil,
              now: ~U[2026-08-27 12:00:01.000000Z],
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

    note = %{
      "summary" => String.duplicate("\\", 1_200),
      "topics" => Enum.map(1..8, &(String.duplicate("\\", 79) <> Integer.to_string(&1)))
    }

    addressing = %{"audience" => "ambient", "ryker_user_ref" => String.duplicate("U", 256)}

    context = %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: candidates,
      conversation_episode_count: 20,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()},
      slack_addressing: addressing,
      observations: List.duplicate(note, 5),
      knowledge: List.duplicate(Map.put(note, "title", String.duplicate("\\", 160)), 8)
    }

    request = Prompt.build(context)
    fitted = Prompt.fit(context)
    unfitted = %{request | "context" => Context.for_model(context)}

    assert byte_size(Ryker.CanonicalJSON.encode!(unfitted)) > 65_536
    assert byte_size(Ryker.CanonicalJSON.encode!(request)) <= 65_536
    assert request["context"]["slack_addressing"] == addressing
    assert request["context"]["input"]["content"]["truncated"]
    assert request["context"]["candidates"] == Enum.map(fitted.candidates, &Candidate.for_model/1)
    assert Enum.map(fitted.candidates, & &1.ref) == Enum.map(candidates, & &1.ref)
    assert request == Prompt.build(fitted)

    assert length(request["context"]["conversation_observations"] || []) +
             length(request["context"]["conversation_knowledge"] || []) < 13
  end

  test "an impossible unbounded host context fails before reaching Coop" do
    input = input!()

    episode = %Episode{
      destination_thread_ref: "older-thread",
      id: Ecto.UUID.generate(),
      state: :working,
      updated_at: ~U[2026-08-27 12:00:00.000000Z]
    }

    endpoint = %{
      occurred_at: ~U[2026-08-27 11:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => "bounded preview"},
          "event_kind" => "message"
        }
      }
    }

    candidate =
      Candidate.new(%{
        allowed_relations:
          Candidate.allowed_relations(episode, %{
            continuation_window: 1_800,
            input_repository: nil,
            now: ~U[2026-08-27 12:00:01.000000Z],
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

    context = %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: List.duplicate(candidate, 200),
      conversation_episode_count: 200,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    assert_raise ArgumentError, ~r/admission prompt exceeds its bound/, fn ->
      Prompt.build(context)
    end
  end

  test "candidate snapshots restore only the exact frozen host mapping" do
    episode = %Episode{
      destination_thread_ref: "current-thread",
      id: Ecto.UUID.generate(),
      state: :working,
      updated_at: ~U[2026-08-27 12:00:00.000000Z]
    }

    candidate =
      Candidate.new(%{
        allowed_relations:
          Candidate.allowed_relations(episode, %{
            continuation_window: 1_800,
            input_repository: nil,
            now: ~U[2026-08-27 12:00:01.000000Z],
            pinned_repository: nil,
            source_owner: false
          }),
        digest: nil,
        endpoints: %{
          first: %{
            occurred_at: ~U[2026-08-27 11:00:00.000000Z],
            payload: %{"payload" => "plain legacy payload"}
          },
          latest: :invalid_endpoint
        },
        episode: episode,
        match: %{},
        same_thread: episode.destination_thread_ref == "current-thread",
        source_owner: false
      })

    snapshot = Candidate.snapshot(candidate)
    assert snapshot["first_input"]["content_preview"] =~ "plain legacy payload"
    assert snapshot["latest_input"] == nil
    assert {:ok, restored} = Candidate.restore(snapshot, episode)
    assert Candidate.for_model(restored) == Candidate.for_model(candidate)

    for invalid <- [
          nil,
          %{snapshot | "allowed_relations" => "same_work"},
          %{snapshot | "allowed_relations" => ["unknown"]},
          %{snapshot | "allowed_relations" => ["same_work", "same_work"]},
          %{snapshot | "first_input" => "invalid"},
          %{snapshot | "first_input" => %{"content_preview" => "incomplete"}}
        ] do
      assert Candidate.restore(invalid, episode) ==
               {:error, {:invalid_admission_context_snapshot, :candidate}}
    end
  end

  test "candidate previews retain the bounded source text without breaking UTF-8" do
    # Generated byte-boundary text, not a model fixture. A cut through a multibyte
    # character must not make the saved prompt or its truncation flag dishonest.
    episode = %Episode{
      destination_thread_ref: "older-thread",
      id: Ecto.UUID.generate(),
      state: :working,
      updated_at: ~U[2026-08-27 12:00:00.000000Z]
    }

    payload = %{
      "actor" => %{"kind" => "app", "ref" => "A123"},
      "content" => %{"text" => String.duplicate("🙂", 2_000)},
      "event_kind" => "message"
    }

    endpoint = %{occurred_at: episode.updated_at, payload: %{"payload" => payload}}

    candidate =
      Candidate.new(%{
        allowed_relations:
          Candidate.allowed_relations(episode, %{
            continuation_window: 1_800,
            input_repository: nil,
            now: episode.updated_at,
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

    preview = Candidate.for_model(candidate)["first_input"]

    assert byte_size(preview["content_preview"]) > 256

    assert preview["content_preview"] ==
             String.byte_slice(Ryker.CanonicalJSON.encode!(payload), 0, 4_096)

    assert String.valid?(preview["content_preview"])
    assert preview["truncated"]
  end

  defp input!(content \\ %{"text" => "A message in a format added tomorrow"}) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: content,
               event_kind: :message,
               event_ref: "Ev123",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-27 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    input
  end
end
