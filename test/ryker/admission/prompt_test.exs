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
             "input" => Input.model_document(input)
           }

    assert Map.keys(request) |> Enum.sort() == ["context", "instructions"]
    assert request["instructions"] =~ "Interpret the event itself"
    assert request["instructions"] =~ "notification controls, confirmation dialogs"
    assert request["instructions"] =~ "Preserve explicit human requests and trusted assignments"
    assert request["instructions"] =~ "Never ignore a request"
    assert request["instructions"] =~ "directed\n  at Ryker."
    assert request["instructions"] =~ "history_only"
    # The candidate's own name is a quick read of the work, not evidence.
    assert request["instructions"] =~ "title, when present, is the one-line name Ryker gave"
    assert request["instructions"] =~ "not source evidence"
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
    assert snapshot["first_input"]["text"] == "plain legacy payload"
    assert snapshot["latest_input"] == nil
    assert {:ok, restored} = Candidate.restore(snapshot, episode)
    assert Candidate.for_model(restored) == Candidate.for_model(candidate)

    for invalid <- [
          nil,
          %{snapshot | "allowed_relations" => "same_work"},
          %{snapshot | "allowed_relations" => ["unknown"]},
          %{snapshot | "allowed_relations" => ["same_work", "same_work"]},
          %{snapshot | "first_input" => "invalid"},
          %{snapshot | "first_input" => %{"text" => "incomplete"}}
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

    preview = Candidate.for_model(candidate)["first_message"]

    assert byte_size(preview["text"]) > 256
    assert preview["text"] == String.byte_slice(String.duplicate("🙂", 2_000), 0, 4_096)
    assert String.valid?(preview["text"])
    assert preview["truncated"]
    # The same message is not sent twice as the latest one.
    refute Map.has_key?(Candidate.for_model(candidate), "latest_message")
  end

  # Measured on 23 routing prompts: the static instructions were 47% of every
  # prompt and landed last, so they could never be a cached prefix; each message
  # and note carried a re-read receipt; 40 of 70 notes repeated a supplied
  # message; and candidates carried retrieval scores with no defined scale.
  describe "the lean routing prompt" do
    test "reads the instructions first, then the event, the conversation and the earlier work" do
      text = Prompt.render(Prompt.build(lean_context!()))
      decoded = Jason.decode!(text)
      assert String.starts_with?(text, ~s({"instructions":))

      positions =
        Enum.map(
          ~w("custom_instructions": "input": "conversation_context": "candidates": "allowed_actions":),
          &(text |> :binary.match(&1) |> elem(0))
        )

      assert positions == Enum.sort(positions)
      assert decoded["context"] == Prompt.build(lean_context!())["context"]
    end

    test "carries each paragraph only with the data it explains" do
      bare = Prompt.build(%{lean_context!() | custom_instructions: nil, observations: []})

      for absent <- [
            "slack_addressing records",
            "repository_source is null",
            "conversation_observations are bounded notes",
            "Custom instructions are explicit operator settings"
          ] do
        refute bare["instructions"] =~ absent
      end

      full = Prompt.build(lean_context!())
      assert full["instructions"] =~ "conversation_observations are bounded notes"
      assert full["instructions"] =~ "Custom instructions are explicit operator settings"
      # This Slack source can react, and nothing else said that null emoji
      # names mean any emoji.
      assert "react" in full["context"]["allowed_actions"]
      assert full["instructions"] =~ "otherwise use any standard emoji short name"
      refute Map.has_key?(bare["context"], "custom_instructions")
    end

    test "reads who said what and when, and keeps the provenance only in the snapshot" do
      context = lean_context!()
      document = Context.for_model(context)
      bundle = document["conversation_context"]

      assert bundle["messages"] == [
               %{
                 "actor" => "UALICE",
                 "at" => "2026-08-27T11:59:00Z",
                 "text" => "Is checkout up?"
               },
               %{"actor" => "ryker", "at" => "2026-08-27T11:59:30Z", "text" => "Checking now."}
             ]

      refute Map.has_key?(bundle, "current")
      refute Map.has_key?(bundle, "channel_summary")
      assert document["context_manifest"] == %{"included" => 2, "requested" => 20}

      # The frozen snapshot still has where each message can be re-read.
      snapshot = Context.snapshot(context)
      assert hd(snapshot["conversation_context"]["messages"])["source_read"]
      assert snapshot["context_manifest"]["bytes"] == 512
    end

    test "a message outside a thread is not told about a thread root" do
      # Every channel message carried root: "not_applicable", which named a
      # thread root that could not exist and told the router nothing.
      context = lean_context!()
      refute Map.has_key?(Context.for_model(context)["context_manifest"], "root")

      # A root that exists but could not be read is still worth saying.
      unreadable = %{
        context
        | context_manifest: Map.put(context.context_manifest, "root", "unavailable")
      }

      assert Context.for_model(unreadable)["context_manifest"]["root"] == "unavailable"
    end

    test "calls wording similar only when more than a word or two is shared" do
      # Postgres scores each occurrence of a shared search word 0.1, so the 0.2
      # that was labelled "similar wording" was one word seen twice. The router
      # was invited to weigh noise the instructions tell it to discount.
      candidate = candidate!(%{"kind" => "user", "ref" => "UALICE"}, "Investigate checkout 502s")

      labelled = fn fit ->
        evidence = Candidate.for_model(%{candidate | match: %{"topic_fit" => fit}})["evidence"]
        "similar wording" in List.wrap(evidence)
      end

      refute labelled.(0.2)
      refute labelled.(0.4)
      assert labelled.(0.5)
      assert labelled.(1.1)
    end

    test "leaves out notes about messages it already reads and keeps only who, when and what" do
      document = Context.for_model(lean_context!())

      assert document["conversation_observations"] == [
               %{
                 "actor" => "UBOB",
                 "at" => "2026-08-27T10:00:00Z",
                 "summary" => "Deploy froze",
                 "topics" => ["deploys"]
               }
             ]
    end

    test "reads a named candidate by its name, last exchange and evidence, under a short ref" do
      # "1" and "5" were a chat episode's opening and latest messages; they told
      # the router nothing its name and last reply did not.
      [candidate] = Context.for_model(lean_context!())["candidates"]

      assert candidate == %{
               "allowed_relations" => ["history_only"],
               "episode_ref" => candidate["episode_ref"],
               "evidence" => ["shares 2 identifiers", "same thread", "similar wording"],
               "idle_minutes" => 90,
               "message_count" => 3,
               "outcome" => "Replied: Checkout is back.",
               "state" => "complete",
               "title" => "Investigate checkout 502s"
             }

      assert candidate["episode_ref"] =~ ~r/\Acandidate:[0-9a-f]{12}\z/
    end

    test "keeps the opening message when it carries an identity or the work has no name" do
      [named] = Context.for_model(lean_context!())["candidates"]
      refute Map.has_key?(named, "first_message")

      alert = candidate!(%{"kind" => "app", "ref" => "B08"}, "Investigate the VA1 firing")

      assert %{"first_message" => %{"text" => "Checkout returns 502"}} =
               Candidate.for_model(alert)

      unnamed = candidate!(%{"kind" => "user", "ref" => "UALICE"}, nil)

      assert %{"first_message" => %{"actor" => "UALICE", "text" => "Checkout returns 502"}} =
               Candidate.for_model(unnamed)
    end
  end

  defp candidate!(actor, title) do
    opening = %{
      occurred_at: ~U[2026-08-27 10:00:00.000000Z],
      payload: %{
        "payload" => %{"actor" => actor, "content" => %{"text" => "Checkout returns 502"}}
      }
    }

    Candidate.new(%{
      allowed_relations: [:history_only],
      digest: %{"conversations" => 1, "message_count" => 1, "title" => title},
      endpoints: %{first: opening, latest: opening},
      episode: %Episode{
        id: Ecto.UUID.generate(),
        state: :complete,
        updated_at: ~U[2026-08-27 10:30:00.000000Z]
      },
      match: %{},
      same_thread: false,
      source_owner: false
    })
  end

  defp lean_context! do
    episode = %Episode{
      destination_thread_ref: "thread",
      id: "0f7d2b8e-3c1a-4c55-9a52-7a1c1e3e2b10",
      state: :complete,
      updated_at: ~U[2026-08-27 10:30:00.000000Z]
    }

    opening = %{
      occurred_at: ~U[2026-08-27 10:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "user", "ref" => "UALICE"},
          "content" => %{"text" => "Checkout returns 502\r\n"}
        }
      }
    }

    candidate =
      Candidate.new(%{
        allowed_relations: [:history_only],
        digest: %{
          "conversations" => 1,
          "message_count" => 3,
          "title" => "Investigate checkout 502s"
        },
        endpoints: %{first: opening, latest: opening},
        episode: episode,
        idle_minutes: 90,
        match: %{
          "active" => false,
          "direct_references" => 2,
          "lanes" => ["thread", "text"],
          "occurrence_identity" => false,
          "same_conversation" => true,
          "same_thread" => true,
          "score" => 580,
          "source_owner" => false,
          "topic_fit" => 1.1
        },
        outcome: "Replied: Checkout is back.",
        same_thread: true,
        source_owner: false
      })

    message = fn actor, at, text, ref ->
      %{
        "actor_ref" => actor,
        "content" => %{"text" => text},
        "occurred_at" => at,
        "retained" => true,
        "revision" => 1,
        "source_message_ref" => ref,
        "source_read" => %{"tool" => "read_slack_source", "arguments" => %{"view" => "thread"}}
      }
    end

    %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [candidate],
      conversation_episode_count: 1,
      input: input!(),
      input_entry: %Entry{id: Ecto.UUID.generate()},
      conversation_context: %{
        "channel_summary" => nil,
        "current" => message.("UALICE", "2026-08-27T12:00:00Z", "Still down?", "m3"),
        "messages" => [
          message.("UALICE", "2026-08-27T11:59:00Z", "Is checkout up?\r\n", "m1"),
          message.("ryker", "2026-08-27T11:59:30Z", "Checking now.", "m2")
        ],
        "root" => nil,
        "thread_summary" => nil
      },
      context_manifest: %{
        "bytes" => 512,
        "channel_summary" => %{"reason" => "absent", "status" => "unavailable"},
        "included" => 2,
        "kind" => "conversation",
        "requested" => 20,
        "root" => "not_applicable",
        "source_read" => "retained_only"
      },
      custom_instructions: %{
        "global" => %{"scope" => "global", "revision" => 1, "text" => "Answer briefly."},
        "channel" => nil
      },
      observations: [
        %{
          "actor_ref" => "UALICE",
          "kind" => "conversation_observation",
          "occurred_at" => "2026-08-27T11:59:00Z",
          "source_message_ref" => "m1",
          "source_ref" => "observation:1",
          "summary" => "Asked whether checkout is up",
          "topics" => []
        },
        %{
          "actor_ref" => "UBOB",
          "kind" => "conversation_observation",
          "occurred_at" => "2026-08-27T10:00:00Z",
          "source_message_ref" => "m0",
          "source_ref" => "observation:0",
          "summary" => "Deploy froze\r\n",
          "thread_ref" => "thread",
          "topics" => ["deploys"]
        }
      ]
    }
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
