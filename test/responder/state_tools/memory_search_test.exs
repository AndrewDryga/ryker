defmodule Responder.StateTools.MemorySearchTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.{Knowledge, Learning}
  alias Responder.Slack.CapabilityTools, as: SlackCapabilityTools
  alias Responder.Slack.SourceRef

  alias Responder.State.{
    Behavior,
    ConversationObservation,
    KnowledgeSnapshot,
    MemoryEntry,
    MemorySearch,
    Observations,
    Record,
    Records,
    SourceExposure
  }

  alias Responder.StateTools.{LookupContext, Router, Tools}
  alias Responder.Work.Custody

  @args %{
    "query" => "",
    "scope" => "workspace",
    "kinds" => ["fact"],
    "limit" => 7,
    "cursor" => nil,
    "after" => nil,
    "before" => nil,
    "time_basis" => "changed"
  }
  @source_at ~U[2026-09-05 17:19:24.248029Z]
  # Captured in testdata/eval/scenarios.jsonl. The confirmed rows below are
  # structural fixtures for retrieval/scope, not purported model judgments.
  @captured "Host and runtime checks passed; Cloud SQL latency remains unverified."

  setup do
    [first | _] = entries = Learning.inputs!()

    assert {:ok, _} =
             Custody.pin_episode(
               first.episode_id,
               "read-only",
               String.duplicate("a", 64),
               first.repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("memory-search-test", 300)
    binding = Map.put(claim, :state_token, Records.token(claim.turn))
    options = Router.init(token: "host-only-search-test-secret", binding: binding)
    %{claim: claim, options: options, entries: entries}
  end

  test "an empty platform lookup still rejects a caller whose lease was lost", %{claim: claim} do
    expired = put_in(claim.turn.lease_ref, Ecto.UUID.generate())

    for name <- ~w(search_slack read_github_conversation search_github) do
      assert {:error, "state_tools_binding_not_authorized"} =
               LookupContext.enrich(
                 name,
                 %{},
                 expired,
                 %{"results" => %{"messages" => []}},
                 []
               )
    end
  end

  test "raw Slack matches and neighbors cannot reveal an input queued for the next turn", %{
    claim: claim,
    entries: [entry | _]
  } do
    # Captured completion text, newly queued on the real kernel ledger. The
    # provider can already see it while this Work turn must not consume it.
    [_root, _card, later] =
      Path.join(__DIR__, "../slack/fixtures/readiness_thread.json")
      |> File.read!()
      |> Jason.decode!()

    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: claim.episode.id,
        episode_key: claim.episode.key,
        native_input_id: "queued-source-lookup",
        turn_ref: claim.turn.turn_ref,
        occurred_at: DateTime.utc_now(),
        destination: %{
          transport: "slack",
          conversation_ref: entry.destination_conversation_ref,
          thread_ref: entry.destination_thread_ref
        },
        payload: %{
          "source_item_ref" => later["ts"],
          "content" => %{"text" => later["text"]},
          "destination" => %{
            "transport" => "slack",
            "conversation_ref" => entry.destination_conversation_ref
          }
        }
      })

    assert {:ok, transition} = Episodes.apply(command)
    assert Command.dedupe_key(command) in transition.episode.queued_input_refs
    future = Map.put(later, "source_ref", SourceRef.message(workspace, channel, later["ts"]))

    current = %{
      "source_ref" => SourceRef.message(workspace, channel, entry.source_item_ref),
      "thread_root" => future,
      "context_messages" => %{"before" => [], "after" => [future]}
    }

    descriptor = %{
      "tool" => "read_slack_source",
      "arguments" => %{
        "source_ref" => SourceRef.thread(workspace, channel, entry.destination_thread_ref),
        "view" => "thread",
        "anchor_ref" => future["source_ref"]
      }
    }

    raw = %{
      "complete" => true,
      "results" => %{"messages" => [current, future]},
      "source_reads" => [descriptor]
    }

    assert {:ok, result} = LookupContext.enrich("search_slack", %{}, claim, raw, [])
    assert [hit] = result["results"]["messages"]
    assert hit["context_messages"]["after"] == []
    assert is_nil(hit["thread_root"])
    assert result["source_reads"] == []
    refute result["complete"]
    refute CanonicalJSON.encode!(result) =~ later["text"]

    assert {:error, "source_not_available"} =
             LookupContext.enrich(
               "read_slack_source",
               %{},
               claim,
               %{"anchor" => future, "messages" => []},
               []
             )
  end

  test "source-linked lookup memory is exposed under the original caller and stops after source deletion",
       %{claim: claim, entries: [entry | _]} do
    {learned, _offer} = Knowledge.learn!(claim.episode, claim.session.repository_ref)

    targets = [
      %{
        "conversation_ref" => entry.destination_conversation_ref,
        "thread_ref" => entry.destination_thread_ref,
        "message_ref" => entry.source_item_ref
      }
    ]

    assert {:ok, result} = MemorySearch.related(claim, targets, nil)
    assert Enum.any?(result["memories"], &(&1["kind"] == "conversation_knowledge"))
    assert Repo.aggregate(SourceExposure, :count) > 0

    Knowledge.revoke!(learned)
    assert {:error, _} = MemorySearch.related(claim, targets, nil)
  end

  test "a platform source read returns related knowledge without a separate memory search", %{
    claim: claim,
    entries: [entry | _]
  } do
    Knowledge.learn!(claim.episode, claim.session.repository_ref)
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")
    source = SourceRef.message(workspace, channel, entry.source_item_ref)

    response = %{
      "source_ref" => source,
      "anchor" => %{"source_ref" => source, "thread_ts" => entry.destination_thread_ref},
      "messages" => []
    }

    tool =
      Enum.find(
        SlackCapabilityTools.definitions(),
        &(&1["name"] == "read_slack_source")
      )

    options =
      Router.init(
        token: "host-only-search-test-secret",
        binding: claim,
        additional_tools: [tool],
        additional_call: fn _, _, _ -> {:ok, response} end
      )

    request = %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "name" => "read_slack_source",
        "arguments" => %{"source_ref" => source, "view" => "surrounding"}
      }
    }

    connection =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("authorization", "Bearer host-only-search-test-secret")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(options)

    result = Jason.decode!(connection.resp_body)["result"]
    refute result["isError"]

    assert [%{"kind" => "conversation_knowledge"} | _] =
             result["structuredContent"]["related_memory"]

    assert Repo.aggregate(SourceExposure, :count) > 0
  end

  test "related knowledge uses the verified source root even when the reply omits thread_ts", %{
    claim: claim,
    entries: [entry | _]
  } do
    Knowledge.learn!(claim.episode, claim.session.repository_ref)
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")

    result = %{
      "source_ref" => SourceRef.thread(workspace, channel, entry.destination_thread_ref),
      "anchor" => %{"source_ref" => SourceRef.message(workspace, channel, "1789058455.189229")},
      "messages" => []
    }

    assert {:ok, enriched} =
             LookupContext.enrich("read_slack_source", %{}, claim, result, ["read_slack_source"])

    assert Enum.any?(enriched["related_memory"], &(&1["kind"] == "conversation_knowledge"))
  end

  test "large optional lookup context is trimmed before any primary hit or exact root", %{
    claim: claim,
    entries: [entry | _]
  } do
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")

    anchor = %{
      "source_ref" => SourceRef.message(workspace, channel, entry.source_item_ref),
      "text" => @captured
    }

    root = %{
      "source_ref" => SourceRef.message(workspace, channel, "1789000000.000100"),
      "text" => "The original question"
    }

    neighbors =
      Enum.map(1..20, fn index ->
        %{
          "source_ref" => SourceRef.message(workspace, channel, "17890000#{10 + index}.000100"),
          "text" => String.duplicate(@captured, 120),
          "ts" => "17890000#{10 + index}.000100"
        }
      end)

    raw = %{
      "anchor" => anchor,
      "thread_root" => root,
      "messages" => neighbors,
      "coverage" => %{"status" => "complete"},
      "complete" => true,
      "channel_context" => %{"messages" => neighbors, "coverage" => %{"status" => "complete"}}
    }

    assert {:ok, result} = LookupContext.enrich("read_slack_source", %{}, claim, raw, [])
    assert result["anchor"] == anchor
    assert result["thread_root"] == root
    assert byte_size(CanonicalJSON.encode!(result)) <= 131_072
    refute result["complete"]
    assert result["coverage"]["status"] == "partial"
    assert result["coverage"]["reason"] == "response_byte_limit"
  end

  test "overlapping lookup originals are shared without removing their primary hits", %{
    claim: claim,
    entries: [entry | _]
  } do
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")

    first = %{
      "source_ref" => SourceRef.message(workspace, channel, entry.source_item_ref),
      "content" => @captured
    }

    second = %{
      "source_ref" => SourceRef.message(workspace, channel, "1789000000.000200"),
      "content" => "The later correction"
    }

    neighbor = %{
      "source_ref" => SourceRef.message(workspace, channel, "1789000000.000300"),
      "text" => "Shared surrounding original"
    }

    raw = %{
      "results" => %{
        "messages" => [
          Map.put(first, "context_messages", %{"before" => [neighbor], "after" => [second]}),
          Map.put(second, "context_messages", %{"before" => [first, neighbor], "after" => []})
        ]
      }
    }

    assert {:ok, result} = LookupContext.enrich("search_slack", %{}, claim, raw, [])
    [first_hit, second_hit] = result["results"]["messages"]
    assert first_hit["content"] == @captured
    assert second_hit["content"] == "The later correction"
    assert first_hit["context_messages"]["before"] == [neighbor]

    assert [%{"source_ref" => ref, "context_reference" => true}] =
             first_hit["context_messages"]["after"]

    assert ref == second["source_ref"]
    assert Enum.all?(second_hit["context_messages"]["before"], & &1["context_reference"])
    assert length(String.split(CanonicalJSON.encode!(result), "Shared surrounding original")) == 2
  end

  test "the platform response byte cap includes attachment coverage even with no optional memory",
       %{
         claim: claim,
         entries: [entry | _]
       } do
    # Structural size boundary: the old attachment wrapper could exceed the
    # advertised cap even after every optional document had been removed.
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")

    result = %{
      "anchor" => %{"source_ref" => SourceRef.message(workspace, channel, entry.source_item_ref)},
      "body" => ""
    }

    result =
      Map.put(
        result,
        "body",
        String.duplicate("x", 131_072 - byte_size(CanonicalJSON.encode!(result)) - 20)
      )

    assert {:error, "source_result_too_large"} =
             LookupContext.enrich("read_slack_source", %{}, claim, result, ["read_slack_source"])
  end

  test "a lookup cannot impersonate another thread or disclose memory after its lease is lost", %{
    claim: claim,
    entries: [entry | _]
  } do
    Knowledge.learn!(claim.episode, claim.session.repository_ref)

    targets = [
      %{
        "conversation_ref" => entry.destination_conversation_ref,
        "thread_ref" => "1789000999.000001",
        "message_ref" => "1789000999.000002"
      }
    ]

    assert {:ok, %{"memories" => []}} = MemorySearch.related(claim, targets, nil)
    expired = put_in(claim.turn.lease_ref, Ecto.UUID.generate())

    assert {:error, :state_tools_binding_not_authorized} =
             MemorySearch.related(expired, targets, nil)
  end

  test "source-related recall includes confirmed facts and guidance without unrelated workspace memory",
       %{claim: claim} do
    fact = fact!(claim, 1)
    guidance!(claim, 2)
    unrelated = fact!(claim, 3)
    unrelated |> Ecto.Changeset.change(source_message_ref: "1789000999.000001") |> Repo.update!()

    targets = [
      %{
        "conversation_ref" => fact.source_conversation_ref,
        "message_ref" => fact.source_message_ref,
        "thread_ref" => nil
      }
    ]

    assert {:ok, result} = MemorySearch.related(claim, targets, nil)
    assert Enum.map(result["memories"], & &1["kind"]) == ["entity_relationship", "guidance"]
    refute Enum.any?(result["memories"], &(&1["memory_ref"] == unrelated.ref))
  end

  test "a searched source excerpt carries later retained thread knowledge without repeating the primary",
       %{claim: claim, options: options, entries: entries} do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Enum.each(entries, &Observations.record_excerpt_in_transaction/1)
             end)

    Knowledge.learn!(claim.episode, claim.session.repository_ref)
    # The captured FIRING and RESOLVED sources are different threads. Select
    # the FIRING source whose exact thread owns the related knowledge above.
    args = %{@args | "query" => "FIRING", "kinds" => ["continuity"], "limit" => 1}
    assert {:ok, result} = Tools.call("search_memory", args, options)
    assert [primary] = result["memories"]
    assert primary["kind"] == "conversation_observation"

    assert Enum.any?(result["related_memory"] || [], &(&1["kind"] == "conversation_knowledge")),
           inspect(%{
             primary: Map.take(primary, ["thread_ref", "source_message_ref"]),
             target_thread: claim.episode.destination_thread_ref,
             coverage: result["related_memory_coverage"]
           })

    refute Enum.any?(result["related_memory"], &(&1["source_ref"] == primary["source_ref"]))

    assert byte_size(CanonicalJSON.encode!(result["memories"] ++ result["related_memory"])) <=
             65_536
  end

  test "every later page is reachable without retrieval counters moving the cursor", %{
    claim: claim,
    options: options
  } do
    records = for index <- 1..27, do: fact!(claim, index)
    {found, pages} = pages(options, @args, [], 0)
    assert pages >= 4
    assert length(found) == 27
    assert length(Enum.uniq_by(found, & &1["memory_ref"])) == 27

    assert MapSet.new(Enum.map(found, & &1["memory_ref"])) ==
             MapSet.new(Enum.map(records, & &1.ref))

    assert Repo.aggregate(MemoryEntry, :sum, :recall_count) == Decimal.new(27)
  end

  test "memory search does not advertise a platform reader that this turn cannot call", %{
    claim: claim,
    options: options
  } do
    fact!(claim, 1)
    assert {:ok, %{"memories" => [memory]}} = Tools.call("search_memory", @args, options)
    assert is_nil(memory["source_read"])
    assert memory["source"]["message_ref"] == "1788628764.248029"
  end

  test "facts cannot consume the whole page and hide guidance or topic knowledge", %{
    claim: claim,
    options: options
  } do
    for index <- 1..20, do: fact!(claim, index)
    guidance!(claim, 1)
    Knowledge.learn!(claim.episode, claim.session.repository_ref)
    args = %{@args | "kinds" => ["fact", "guidance", "continuity"], "limit" => 3}

    assert {:ok, %{"memories" => [fact, guidance, knowledge]}} =
             Tools.call("search_memory", args, options)

    assert fact["kind"] == "entity_relationship"
    assert guidance["kind"] == "guidance"
    assert knowledge["kind"] == "conversation_knowledge"
  end

  test "an unknown source reference cannot be disclosed as dependency-free text", %{claim: claim} do
    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.expose(claim, [
               %{"source_ref" => "unsupported:#{Ecto.UUID.generate()}", "summary" => @captured}
             ])

    assert Repo.aggregate(SourceExposure, :count) == 0
  end

  test "confirmed-memory content ordering has a scoped index independent of usage counters", %{
    claim: claim
  } do
    fact = fact!(claim, 1)
    guidance!(claim, 1)
    # Structural plan check, not a benchmark: the tiny fixture would normally
    # prefer a sequential scan, so ask whether the required index path exists.
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_sort = off")

    for {table, expected_index, extra} <- [
          {"operational_memory_entries", "operational_memory_search_page", ""},
          {"operator_behaviors", "guidance_search_page", " AND kind = 'guidance'"}
        ] do
      %{rows: rows} =
        Repo.query!(
          """
          EXPLAIN SELECT id FROM #{table}
          WHERE workspace_ref = $1 AND scope_kind = 'workspace' AND scope_ref = $1
            AND status = 'active' #{extra}
            AND COALESCE(edited_at, confirmed_at) <= $2
          ORDER BY COALESCE(edited_at, confirmed_at) DESC, id DESC LIMIT 1
          """,
          [fact.workspace_ref, DateTime.utc_now()]
        )

      assert Enum.map_join(rows, "\n", &hd/1) =~ expected_index
    end

    Repo.query!("SET LOCAL enable_seqscan = on")
    Repo.query!("SET LOCAL enable_sort = on")
  end

  test "cursor identity cannot be altered or reused for another query scope or turn", %{
    claim: claim,
    options: options
  } do
    for index <- 1..3, do: fact!(claim, index)
    args = %{@args | "limit" => 1}
    assert {:ok, %{"cursor" => cursor}} = Tools.call("search_memory", args, options)
    assert is_binary(cursor)

    for changed <- [
          %{args | "query" => "changed"},
          %{args | "scope" => "repository"},
          %{args | "kinds" => ["guidance"]},
          %{args | "time_basis" => "source"}
        ] do
      assert {:error, "invalid_memory_cursor"} =
               Tools.call("search_memory", %{changed | "cursor" => cursor}, options)
    end

    assert {:error, "invalid_memory_cursor"} =
             Tools.call("search_memory", %{args | "cursor" => "x" <> cursor}, options)

    other = put_in(options.binding.turn.lease_ref, Ecto.UUID.generate())

    assert {:error, "invalid_memory_cursor"} =
             Tools.call("search_memory", %{args | "cursor" => cursor}, other)

    assert Repo.aggregate(MemoryEntry, :sum, :recall_count) == Decimal.new(1)
  end

  test "a broad guidance candidate cap cannot hide an older literal or token-order match", %{
    claim: claim,
    options: options
  } do
    guidance!(claim, 1)
    for index <- 2..105, do: guidance!(claim, index, "Unrelated structural cardinality padding.")
    args = %{@args | "kinds" => ["guidance"], "query" => "latency Cloud SQL"}
    assert {:ok, %{"memories" => [match]}} = Tools.call("search_memory", args, options)
    assert match["text"] == @captured
  end

  test "backfilled rows and later content edits do not enter an existing traversal", %{
    claim: claim,
    options: options
  } do
    older = fact!(claim, 1)
    newest = fact!(claim, 3)
    args = %{@args | "limit" => 1}

    assert {:ok, %{"memories" => [%{"memory_ref" => ref}], "cursor" => cursor}} =
             Tools.call("search_memory", args, options)

    assert ref == newest.ref

    # Explicit structural timestamps on either side of the captured cutoff;
    # application/database clock skew is not the boundary under test.
    [body, _] = String.split(cursor, ".")

    {:ok, cutoff, 0} =
      body
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.fetch!("cutoff")
      |> DateTime.from_iso8601()

    after_cutoff = DateTime.add(cutoff, 1, :second)
    backfill = fact!(claim, 2)

    Repo.update_all(from(e in MemoryEntry, where: e.id == ^backfill.id),
      set: [inserted_at: after_cutoff]
    )

    Repo.update_all(from(e in MemoryEntry, where: e.id == ^older.id),
      set: [edited_at: after_cutoff]
    )

    assert {:ok, %{"memories" => [], "exhausted" => true}} =
             Tools.call("search_memory", %{args | "cursor" => cursor}, options)

    # Move the structural edits behind the present before starting a new search.
    Repo.update_all(from(e in MemoryEntry, where: e.id == ^backfill.id),
      set: [inserted_at: cutoff]
    )

    Repo.update_all(from(e in MemoryEntry, where: e.id == ^older.id), set: [edited_at: cutoff])

    assert {:ok, %{"memories" => fresh}} =
             Tools.call("search_memory", %{@args | "limit" => 10}, options)

    assert length(fresh) == 3
  end

  test "a cursor expires and cannot cross a destination or execution mode", %{
    claim: claim,
    options: options
  } do
    for index <- 1..2, do: fact!(claim, index)
    args = %{@args | "limit" => 1}
    assert {:ok, %{"cursor" => cursor}} = Tools.call("search_memory", args, options)
    other_mode = if claim.episode.execution_mode == :live, do: :shadow, else: :live

    for changed <- [
          put_in(
            options.binding.episode.destination_conversation_ref,
            "slack:another:conversation"
          ),
          put_in(options.binding.episode.execution_mode, other_mode)
        ] do
      assert {:error, "invalid_memory_cursor"} =
               Tools.call("search_memory", %{args | "cursor" => cursor}, changed)
    end

    # Host-signed expired state, not a model fixture or a test-only clock in production.
    [body, _signature] = String.split(cursor, ".")

    expired =
      body
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.update!("cutoff", fn issued_at ->
        {:ok, issued_at, 0} = DateTime.from_iso8601(issued_at)
        issued_at |> DateTime.add(-3601) |> DateTime.to_iso8601()
      end)
      |> CanonicalJSON.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, "host-only-search-test-secret", "memory-search:" <> expired)
      |> Base.url_encode64(padding: false)

    assert {:error, "invalid_memory_cursor"} =
             Tools.call(
               "search_memory",
               %{args | "cursor" => expired <> "." <> signature},
               options
             )

    for {after_at, before_at} <- [
          {"2026-09-06T00:00:00Z", "2026-09-05T00:00:00Z"},
          {"2026-09-05T00:00:00Z", "2026-09-05T00:00:00Z"}
        ] do
      assert {:error, "invalid_memory_time_filter"} =
               Tools.call(
                 "search_memory",
                 %{args | "after" => after_at, "before" => before_at},
                 options
               )
    end
  end

  test "source dates do not become processing dates and revoked later results disappear", %{
    entries: entries,
    options: options
  } do
    # This assertion promises a callable expansion, so expose its real schema.
    options = Map.put(options, :additional_tools, SlackCapabilityTools.definitions())

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Enum.each(entries, &Observations.record_excerpt_in_transaction/1)
             end)

    args = %{
      @args
      | "kinds" => ["continuity"],
        "time_basis" => "source",
        "query" => "OOM",
        "limit" => 1,
        "after" => "2026-09-05T00:00:00Z",
        "before" => "2026-09-06T00:00:00Z"
    }

    assert {:ok, %{"memories" => [newer], "cursor" => cursor}} =
             Tools.call("search_memory", args, options)

    assert newer["occurred_at"] =~ "2026-09-05"

    assert %{
             "tool" => "read_slack_source",
             "arguments" => %{
               "source_ref" => source_ref,
               "anchor_ref" => anchor_ref,
               "view" => "thread"
             }
           } = newer["source_read"]

    assert {:ok, %{kind: :thread, message_ref: root}} =
             SourceRef.parse(source_ref, hd(entries).source_ref)

    assert root == newer["thread_ref"]

    assert {:ok, %{kind: :message, message_ref: anchor}} =
             SourceRef.parse(anchor_ref, hd(entries).source_ref)

    assert anchor == newer["source_message_ref"]

    [older] = Enum.reject(entries, &(&1.id == newer["source_input_id"]))

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.receive_in_transaction(%{
                 older
                 | id: Ecto.UUID.generate(),
                   event_kind: :delete,
                   revision: older.revision + 1
               })
             end)

    assert {:ok, %{"memories" => [], "cursor" => nil, "exhausted" => true}} =
             Tools.call("search_memory", %{args | "cursor" => cursor}, options)

    assert {:ok, %{"memories" => []}} =
             Tools.call("search_memory", %{args | "time_basis" => "changed"}, options)

    assert Repo.aggregate(ConversationObservation, :count) == 2
  end

  defp pages(_options, _args, _found, 10), do: flunk("cursor did not reach exhaustion")

  defp pages(options, args, found, count) do
    assert {:ok, result} = Tools.call("search_memory", args, options)
    found = found ++ result["memories"]

    if result["cursor"],
      do: pages(options, %{args | "cursor" => result["cursor"]}, found, count + 1),
      else: {found, count + 1}
  end

  defp offer!(claim, index, kind, payload) do
    # This expands historical-store cardinality, not one model's offer quota.
    # Keep real foreign keys without pretending one turn proposed 105 changes.
    id = Ecto.UUID.generate()

    Repo.insert!(%Record{
      id: id,
      episode_id: claim.episode.id,
      turn_id: claim.turn.id,
      ref: "record:#{kind}:#{id}",
      operation_id: "search:#{kind}:#{index}",
      kind: kind,
      status: :open,
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload)
    })
  end

  defp fact!(claim, index) do
    payload = %{
      "expires_in" => "30d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => "fixture-#{index}",
      "value" => @captured,
      "visibility" => "workspace"
    }

    offer = offer!(claim, index, "memory_offer", payload)
    id = Ecto.UUID.generate()

    Repo.insert!(
      struct!(
        MemoryEntry,
        Map.merge(common(claim, id, offer.id, index), %{
          kind: :entity_relationship,
          subject: payload["subject"],
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          visibility: :workspace
        })
      )
    )
  end

  defp guidance!(claim, index, text \\ @captured) do
    payload = %{
      "expires_in" => "30d",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => "fixture-#{index}",
      "summary" => text,
      "text" => text,
      "visibility" => "workspace"
    }

    offer = offer!(claim, index, "guidance_offer", payload)
    id = Ecto.UUID.generate()

    Repo.insert!(
      struct!(
        Behavior,
        Map.merge(common(claim, id, offer.id, index), %{
          kind: :guidance,
          ref: "behavior:#{id}",
          identity_key: CanonicalJSON.digest(id),
          payload: payload
        })
      )
    )
  end

  defp common(claim, id, offer, index) do
    ["slack", workspace, _channel] = String.split(claim.episode.destination_conversation_ref, ":")
    at = DateTime.add(@source_at, index)

    %{
      id: id,
      ref: "memory:#{id}",
      offer_record_id: offer,
      status: :active,
      workspace_ref: "slack:#{workspace}",
      scope_kind: :workspace,
      scope_ref: "slack:#{workspace}",
      confirmed_by_actor_ref: "host-structural-fixture",
      confirmation_ref: "fixture:#{id}",
      confirmed_at: at,
      source_transport: "slack",
      source_conversation_ref: claim.episode.destination_conversation_ref,
      source_thread_ref: nil,
      source_message_ref: "1788628764.248029",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      inserted_at: at,
      updated_at: at
    }
  end
end
