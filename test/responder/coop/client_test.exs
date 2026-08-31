defmodule Responder.Coop.ClientTest do
  use ExUnit.Case, async: true

  alias Responder.CanonicalJSON
  alias Responder.Coop.Client
  alias Responder.Work.{Session, StateBinding, Turn}

  test "creates an asynchronous session through Coop's Unix socket" do
    response = %{
      "operation" => %{
        "id" => "op_create",
        "resource_id" => "remote_123",
        "resource_type" => "session",
        "state" => "succeeded"
      }
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.create_session(
                 client,
                 "responder:admission:create:123",
                 "admission-read-only",
                 "responder-admission:123"
               )

      captured = request.()
      assert captured.method == "POST"
      assert captured.path == "/v1/sessions"
      assert captured.headers["idempotency-key"] == "responder:admission:create:123"
      assert captured.headers["prefer"] == "respond-async"

      assert Jason.decode!(captured.body) == %{
               "policy" => "admission-read-only",
               "task" => "responder-admission:123"
             }
    end)
  end

  test "creates a session with one exact private Responder binding" do
    response = %{"operation" => %{"id" => "op_create", "state" => "running"}}

    binding = %{
      "endpoint" => "https://responder.example/v1/state-tools/mcp",
      "token" => String.duplicate("t", 48)
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.create_bound_session(
                 client,
                 "responder:work:create:123",
                 "work-read-only",
                 "episode:123",
                 binding
               )

      assert request.().body |> Jason.decode!() == %{
               "policy" => "work-read-only",
               "responder_binding" => binding,
               "task" => "episode:123"
             }
    end)
  end

  test "submits the exact schema digest with semantic validation enabled" do
    response = %{
      "operation" => %{"id" => "op_turn", "state" => "succeeded"},
      "turn" => %{"id" => "turn_123", "session_id" => "remote_123", "state" => "queued"}
    }

    schema = %{
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "type" => "object"
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.submit_turn(
                 client,
                 "remote_123",
                 "responder:admission:turn:123:0",
                 4,
                 "Classify this event.",
                 schema
               )

      captured = request.()
      body = Jason.decode!(captured.body)
      contract = body["output_contract"]
      expected_schema_bytes = CanonicalJSON.encode!(schema)

      expected_digest =
        :crypto.hash(:sha256, expected_schema_bytes) |> Base.encode16(case: :lower)

      assert captured.path == "/v1/sessions/remote_123/turns"
      assert body["expected_revision"] == 4
      assert body["prompt"] == "Classify this event."
      assert contract["json_schema"] == schema
      assert contract["sha256"] == expected_digest
      assert contract["require_semantic_validation"]
      assert captured.body == CanonicalJSON.encode!(body)
    end)
  end

  test "submits and fences the derived private Responder binding on the logical turn" do
    response = %{
      "operation" => %{"id" => "op_turn", "state" => "succeeded"},
      "turn" => %{"id" => "turn_123", "session_id" => "remote_123", "state" => "queued"}
    }

    endpoint = "https://responder.example/v1/state-tools/mcp"

    assert {:ok, derived} =
             StateBinding.derive(
               %Session{id: Ecto.UUID.generate()},
               %Turn{id: Ecto.UUID.generate()},
               "local:direct-client-regression",
               endpoint,
               "controller-state-tools-secret"
             )

    binding = StateBinding.document(derived)

    submission = %{
      "context" => %{"turn_ref" => "turn:bound"},
      "input_artifact_refs" => [],
      "output_schema" => %{"type" => "object"},
      "prompt" => "Use only this logical turn's state authority."
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.submit_frozen_turn(
                 client,
                 "remote_123",
                 "responder:work:turn:bound",
                 4,
                 submission,
                 binding,
                 []
               )

      body = request.() |> Map.fetch!(:body) |> Jason.decode!()
      assert body["responder_binding"] == binding
      refute body["prompt"] =~ binding["token"]
    end)

    fenced = %{
      "error_code" => "operation_fenced",
      "id" => "op_fenced",
      "method" => "SubmitTurn",
      "state" => "failed"
    }

    with_unix_server(fenced, fn client, request ->
      assert {:ok, ^fenced} =
               Client.fence_frozen_turn(
                 client,
                 "remote_123",
                 "responder:work:turn:bound",
                 4,
                 submission,
                 binding,
                 []
               )

      document = request.() |> Map.fetch!(:body) |> Jason.decode!()
      assert document["request"]["responder_binding"] == binding
    end)
  end

  test "submits and fences the exact bounded input artifact bytes" do
    response = %{
      "operation" => %{"id" => "op_turn", "state" => "succeeded"},
      "turn" => %{"id" => "turn_123", "session_id" => "remote_123", "state" => "queued"}
    }

    schema = %{"type" => "object"}
    data = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>

    artifact = %{
      "data" => data,
      "media_type" => "image/png",
      "name" => "failure.png",
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.submit_turn_with_artifacts(
                 client,
                 "remote_123",
                 "responder:work:turn:artifact",
                 4,
                 "Inspect it.",
                 schema,
                 [artifact]
               )

      body = request.() |> Map.fetch!(:body) |> Jason.decode!()
      assert [encoded] = body["artifacts"]
      assert Base.decode64!(encoded["data"]) == data
      assert Map.drop(encoded, ["data"]) == Map.drop(artifact, ["data"])
    end)

    fenced = %{
      "error_code" => "operation_fenced",
      "id" => "op_fenced",
      "method" => "SubmitTurn",
      "state" => "failed"
    }

    with_unix_server(fenced, fn client, request ->
      assert {:ok, ^fenced} =
               Client.fence_submit_turn_with_artifacts(
                 client,
                 "remote_123",
                 "responder:work:turn:artifact",
                 4,
                 "Inspect it.",
                 schema,
                 [artifact]
               )

      document = request.() |> Map.fetch!(:body) |> Jason.decode!()
      assert document["request"]["artifacts"] |> hd() |> Map.fetch!("data") == Base.encode64(data)
    end)
  end

  test "fences the exact prepared create and submit identities without replaying them" do
    fenced = %{
      "error_code" => "operation_fenced",
      "id" => "op_fenced",
      "method" => "CreateRemoteSession",
      "state" => "failed"
    }

    with_unix_server(fenced, fn client, request ->
      assert {:ok, ^fenced} =
               Client.fence_create_session(
                 client,
                 "responder:work:create:session:g1",
                 "work-read-only",
                 "episode:123"
               )

      captured = request.()
      assert captured.path == "/v1/operations/fence"
      assert captured.headers["idempotency-key"] == "responder:work:create:session:g1"

      assert Jason.decode!(captured.body) == %{
               "method" => "CreateRemoteSession",
               "request" => %{"policy" => "work-read-only", "task" => "episode:123"}
             }
    end)

    schema = %{
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "type" => "object"
    }

    fenced_turn = %{fenced | "method" => "SubmitTurn"}

    with_unix_server(fenced_turn, fn client, request ->
      assert {:ok, ^fenced_turn} =
               Client.fence_submit_turn(
                 client,
                 "remote_123",
                 "responder:work:turn:turn:g1:sha",
                 4,
                 "Frozen prompt",
                 schema
               )

      captured = request.()
      contract = Jason.decode!(captured.body)["request"]["output_contract"]

      assert Jason.decode!(captured.body) == %{
               "method" => "SubmitTurn",
               "request" => %{
                 "expected_revision" => 4,
                 "output_contract" => contract,
                 "prompt" => "Frozen prompt",
                 "session_id" => "remote_123"
               }
             }

      assert contract["json_schema"] == schema
      assert contract["require_semantic_validation"]

      assert contract["sha256"] ==
               :crypto.hash(:sha256, CanonicalJSON.encode!(schema))
               |> Base.encode16(case: :lower)
    end)
  end

  test "keeps bounded Coop errors structured and treats missing operations as absent" do
    error = %{
      "error" => %{"code" => "operation_not_found", "detail" => "operation not found"}
    }

    with_unix_server(error, 404, fn client, request ->
      assert :not_found = Client.operation_by_key(client, "responder:key with spaces")
      assert request.().path == "/v1/operations?key=responder%3Akey+with+spaces"
    end)
  end

  test "reads sessions and turns from exact resource paths" do
    session = %{"id" => "remote_123", "revision" => 7, "state" => "open"}

    with_unix_server(session, fn client, request ->
      assert {:ok, ^session} = Client.get_session(client, "remote_123")
      assert request.().path == "/v1/sessions/remote_123"
    end)

    turn = %{"id" => "turn_123", "session_id" => "remote_123", "state" => "running"}

    with_unix_server(turn, fn client, request ->
      assert {:ok, ^turn} = Client.get_turn(client, "remote_123", "turn_123")
      assert request.().path == "/v1/sessions/remote_123/turns/turn_123"
    end)
  end

  test "plans and executes one exact Coop session discard" do
    planned = %{
      "operation" => %{
        "id" => "op_plan",
        "method" => "PlanDiscard",
        "resource_id" => "remote_123",
        "resource_type" => "discard_plan",
        "state" => "succeeded"
      },
      "plan" => %{
        "operation_id" => "op_plan",
        "plan" => %{
          "revision" => 8,
          "session_id" => "remote_123",
          "workspace" => %{
            "accepted_unmerged" => true,
            "branch" => "coop/session-123",
            "dirty" => false,
            "head" => String.duplicate("a", 40),
            "running" => false,
            "status_digest" => String.duplicate("b", 64),
            "unmerged" => true
          }
        }
      }
    }

    with_unix_server(planned, fn client, request ->
      assert {:ok, ^planned} =
               Client.plan_discard(
                 client,
                 "remote_123",
                 "responder:retention:plan:session:g1",
                 8,
                 false,
                 true
               )

      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/discard-plan"
      assert captured.headers["idempotency-key"] == "responder:retention:plan:session:g1"

      assert Jason.decode!(captured.body) == %{
               "accept_dirty" => false,
               "accept_unmerged" => true,
               "expected_revision" => 8
             }
    end)

    discarded = %{
      "operation" => %{
        "id" => "op_discard",
        "method" => "Discard",
        "resource_id" => "remote_123",
        "resource_type" => "session",
        "state" => "succeeded"
      },
      "session" => %{"id" => "remote_123", "revision" => 9, "state" => "discarded"}
    }

    with_unix_server(discarded, fn client, request ->
      assert {:ok, ^discarded} =
               Client.discard_session(
                 client,
                 "remote_123",
                 "responder:retention:discard:session:g1",
                 "op_plan"
               )

      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/discard"
      assert captured.headers["idempotency-key"] == "responder:retention:discard:session:g1"
      assert Jason.decode!(captured.body) == %{"plan_operation_id" => "op_plan"}
    end)

    assert {:ok, client} =
             Client.new(
               finch: Responder.CoopFinch,
               receive_timeout: 1_000,
               socket: "/tmp/coop.sock"
             )

    assert Client.plan_discard(client, "bad/id", "key", 1, false, false) ==
             {:error, {:invalid_coop_request, :resource_id}}
  end

  test "reads the exact bounded workspace changes for one session" do
    changes = %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/responder.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => String.duplicate("b", 40),
      "fork_tree" => String.duplicate("c", 40),
      "parent_head" => String.duplicate("d", 40),
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch" => Base.encode64("diff --git a/lib/responder.ex b/lib/responder.ex"),
      "patch_bytes" => 52,
      "patch_digest" => String.duplicate("e", 64),
      "patch_has_more" => false,
      "patch_next_offset" => 52,
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }

    with_unix_server(changes, fn client, request ->
      assert {:ok, ^changes} = Client.get_changes(client, "remote_123")
      assert request.().path == "/v1/sessions/remote_123/changes"
    end)
  end

  test "reads one explicit workspace patch page without relying on Coop defaults" do
    changes = %{
      "committed" => [],
      "conflicts" => [],
      "patch" => Base.encode64("next page"),
      "patch_bytes" => 4_800,
      "patch_digest" => String.duplicate("e", 64),
      "patch_has_more" => false,
      "patch_next_offset" => 4_800,
      "patch_offset" => 2_400,
      "staged" => [],
      "unstaged" => [],
      "untracked" => []
    }

    with_unix_server(changes, fn client, request ->
      assert {:ok, ^changes} = Client.get_changes_page(client, "remote_123", 2_400, 2_400)

      uri = URI.parse(request.().path)
      assert uri.path == "/v1/sessions/remote_123/changes"
      assert URI.decode_query(uri.query) == %{"patch_limit" => "2400", "patch_offset" => "2400"}
    end)
  end

  test "runs an exact idempotent workspace review" do
    response = %{
      "operation" => %{
        "id" => "op_review",
        "method" => "RunReview",
        "resource_id" => "remote_123",
        "resource_type" => "review",
        "state" => "succeeded"
      },
      "review" => %{
        "candidate_tree" => String.duplicate("c", 40),
        "operation_id" => "op_review",
        "patch_artifact_id" => "op_review",
        "patch_bytes" => 12,
        "patch_digest" => String.duplicate("d", 64),
        "publishable" => true,
        "session_id" => "remote_123"
      }
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.run_review(client, "remote_123", "responder:review:123", 9)

      captured = request.()
      assert captured.method == "POST"
      assert captured.path == "/v1/sessions/remote_123/review"
      assert captured.headers["idempotency-key"] == "responder:review:123"
      assert Jason.decode!(captured.body) == %{"expected_revision" => 9}
    end)
  end

  test "streams and verifies the complete reviewed patch artifact" do
    patch = "diff --git a/lib/a.ex b/lib/a.ex\n+reviewed\n"
    digest = :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower)

    with_unix_binary_server(
      patch,
      [
        {"content-type", "text/x-diff; charset=utf-8"},
        {"etag", ~s("#{digest}")},
        {"content-length", Integer.to_string(byte_size(patch))}
      ],
      fn client, request ->
        assert {:ok, ^patch} =
                 Client.get_review_patch(client, "op_review", digest, byte_size(patch))

        assert request.().path == "/v1/operations/op_review/review-patch"
      end
    )
  end

  test "streams one exact bounded output artifact from its owning turn" do
    data = <<137, 80, 78, 71, 13, 10, 26, 10, "verified-chart">>
    digest = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    with_unix_binary_server(
      data,
      [
        {"content-type", "image/png"},
        {"etag", ~s("#{digest}")},
        {"content-length", Integer.to_string(byte_size(data))}
      ],
      fn client, request ->
        assert {:ok, artifact} =
                 Client.get_output_artifact(
                   client,
                   "remote_123",
                   "turn_123",
                   "artifact_123"
                 )

        assert artifact == %{
                 "bytes" => byte_size(data),
                 "data" => data,
                 "id" => "artifact_123",
                 "media_type" => "image/png",
                 "sha256" => digest
               }

        assert request.().path ==
                 "/v1/sessions/remote_123/turns/turn_123/artifacts/artifact_123"
      end
    )
  end

  test "reads an existing operation by its exact key" do
    operation = %{
      "id" => "op_existing",
      "resource_id" => "remote_123",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    with_unix_server(operation, fn client, request ->
      assert {:ok, ^operation} = Client.operation_by_key(client, "responder:existing")
      assert request.().path == "/v1/operations?key=responder%3Aexisting"
    end)
  end

  test "closes sessions and validates exact candidates with idempotent mutations" do
    closed = %{"session" => %{"id" => "remote_123", "revision" => 9, "state" => "closed"}}

    with_unix_server(closed, fn client, request ->
      assert {:ok, ^closed} = Client.close_session(client, "remote_123", "close:key", 8)
      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/close"
      assert captured.headers["idempotency-key"] == "close:key"
      assert Jason.decode!(captured.body) == %{"expected_revision" => 8}
    end)

    digest = String.duplicate("a", 64)
    accepted = %{"turn" => %{"id" => "turn_123", "state" => "completed"}}

    with_unix_server(accepted, fn client, request ->
      assert {:ok, ^accepted} =
               Client.validate_candidate(
                 client,
                 "remote_123",
                 "turn_123",
                 "validation:accept",
                 digest,
                 :accept
               )

      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/turns/turn_123/validation"

      assert Jason.decode!(captured.body) == %{
               "candidate_sha256" => digest,
               "verdict" => "accept"
             }
    end)

    rejected = %{"turn" => %{"id" => "turn_123", "state" => "running"}}

    with_unix_server(rejected, fn client, request ->
      assert {:ok, ^rejected} =
               Client.validate_candidate(
                 client,
                 "remote_123",
                 "turn_123",
                 "validation:reject",
                 digest,
                 {:reject, ["episode_ref must use an offered candidate"]}
               )

      assert Jason.decode!(request.().body) == %{
               "candidate_sha256" => digest,
               "verdict" => "reject",
               "violations" => ["episode_ref must use an offered candidate"]
             }
    end)
  end

  test "cancels the exact Coop turn with a revision-fenced idempotent mutation" do
    cancelled = %{
      "operation" => %{"id" => "op_cancel", "state" => "succeeded"},
      "turn" => %{
        "id" => "turn_123",
        "revision" => 7,
        "session_id" => "remote_123",
        "state" => "cancelled"
      }
    }

    with_unix_server(cancelled, fn client, request ->
      assert {:ok, ^cancelled} =
               Client.cancel_turn(
                 client,
                 "remote_123",
                 "turn_123",
                 "cancel:turn:123:g1",
                 6
               )

      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/turns/turn_123/cancel"
      assert captured.headers["idempotency-key"] == "cancel:turn:123:g1"
      assert Jason.decode!(captured.body) == %{"expected_revision" => 6}
    end)
  end

  test "rejects malformed local requests before opening a socket" do
    assert {:error, {:invalid_coop_client, :socket}} =
             Client.new(finch: __MODULE__, receive_timeout: 1_000, socket: "tcp://coop")

    assert {:ok, client} =
             Client.new(finch: __MODULE__, receive_timeout: 1_000, socket: "/tmp/not-used.sock")

    assert {:error, {:invalid_coop_request, :resource_id}} =
             Client.get_session(client, "../../wrong")

    assert {:error, {:invalid_coop_request, :expected_revision}} =
             Client.close_session(client, "remote_123", "close:key", 0)

    assert {:error, {:invalid_coop_request, :expected_revision}} =
             Client.cancel_turn(client, "remote_123", "turn_123", "cancel:key", 0)

    assert {:error, {:invalid_coop_request, :candidate_sha256}} =
             Client.validate_candidate(
               client,
               "remote_123",
               "turn_123",
               "validation:key",
               "not-a-digest",
               :accept
             )

    assert {:error, {:invalid_coop_request, :violations}} =
             Client.validate_candidate(
               client,
               "remote_123",
               "turn_123",
               "validation:key",
               String.duplicate("a", 64),
               {:reject, []}
             )

    assert {:error, {:invalid_coop_request, :violations}} =
             Client.validate_candidate(
               client,
               "remote_123",
               "turn_123",
               "validation:key",
               String.duplicate("a", 64),
               {:reject, [String.duplicate("x", 4_096)]}
             )
  end

  test "rejects every oversized or malformed local submission before transport" do
    assert {:ok, client} =
             Client.new(finch: __MODULE__, receive_timeout: 1_000, socket: "/tmp/not-used.sock")

    schema = %{"type" => "object"}
    digest = String.duplicate("a", 64)

    assert Client.get_changes_page(client, "remote_123", -1, 1) ==
             {:error, {:invalid_coop_request, :patch_offset}}

    assert Client.get_changes_page(client, "remote_123", 0, 0) ==
             {:error, {:invalid_coop_request, :patch_limit}}

    assert Client.get_review_patch(client, "artifact_123", digest, 0) ==
             {:error, {:invalid_coop_request, :patch_bytes}}

    assert Client.submit_turn(client, "remote_123", "turn:key", 1, "", schema) ==
             {:error, {:invalid_coop_request, :prompt}}

    assert Client.submit_turn(
             client,
             "remote_123",
             "turn:key",
             1,
             String.duplicate("p", 256 * 1_024 + 1),
             schema
           ) == {:error, {:invalid_coop_request, :prompt}}

    assert Client.submit_turn(client, "remote_123", "turn:key", 1, "prompt", []) ==
             {:error, {:invalid_coop_request, :schema}}

    assert {:error, {:invalid_coop_request, :schema, _reason}} =
             Client.submit_turn(
               client,
               "remote_123",
               "turn:key",
               1,
               "prompt",
               %{"invalid_utf8" => <<255>>}
             )

    assert Client.submit_turn_with_artifacts(
             client,
             "remote_123",
             "turn:key",
             1,
             "prompt",
             schema,
             :not_a_list
           ) == {:error, {:invalid_coop_request, :artifacts}}

    assert Client.submit_turn_with_artifacts(
             client,
             "remote_123",
             "turn:key",
             1,
             "prompt",
             schema,
             List.duplicate(%{}, 6)
           ) == {:error, {:invalid_coop_request, :artifacts}}

    assert Client.submit_turn_with_artifacts(
             client,
             "remote_123",
             "turn:key",
             1,
             "prompt",
             schema,
             [%{"data" => "bytes"}]
           ) == {:error, {:invalid_coop_request, :artifacts}}

    assert Client.submit_turn_with_artifacts(
             client,
             "remote_123",
             "turn:key",
             1,
             "prompt",
             schema,
             [input_artifact("wrong-digest", "payload")]
           ) == {:error, {:invalid_coop_request, :artifacts}}

    first = String.duplicate("a", 5 * 1_024 * 1_024)
    second = String.duplicate("b", 4 * 1_024 * 1_024)

    assert Client.submit_turn_with_artifacts(
             client,
             "remote_123",
             "turn:key",
             1,
             "prompt",
             schema,
             [input_artifact(sha256(first), first), input_artifact(sha256(second), second)]
           ) == {:error, {:invalid_coop_request, :artifacts}}

    assert Client.validate_candidate(
             client,
             "remote_123",
             "turn_123",
             "validation:key",
             digest,
             :maybe
           ) == {:error, {:invalid_coop_request, :verdict}}

    assert Client.new(%{}) == {:error, {:invalid_coop_client, :fields}}

    assert Client.new(finch: __MODULE__, finch: __MODULE__) ==
             {:error, {:invalid_coop_client, :fields}}

    assert Client.new(:invalid) == {:error, {:invalid_coop_client, :fields}}

    assert Client.new(finch: "not-an-atom", receive_timeout: 1_000, socket: "/tmp/coop.sock") ==
             {:error, {:invalid_coop_client, :finch}}

    assert Client.new(finch: __MODULE__, receive_timeout: 99, socket: "/tmp/coop.sock") ==
             {:error, {:invalid_coop_client, :receive_timeout}}
  end

  test "fails closed on malformed artifact and review-patch transport metadata" do
    body = "verified bytes"
    digest = sha256(body)

    for headers <- [
          [
            {"content-type", "text/plain"},
            {"etag", ~s("#{digest}")},
            {"content-length", Integer.to_string(byte_size(body))}
          ],
          [
            {"content-type", "image/png"},
            {"etag", ~s("#{digest}")}
          ],
          [
            {"content-type", "image/png"},
            {"etag", "not-an-etag"},
            {"content-length", Integer.to_string(byte_size(body))}
          ]
        ] do
      with_unix_binary_server(body, headers, fn client, _request ->
        assert Client.get_output_artifact(client, "remote_123", "turn_123", "artifact_123") ==
                 {:error, {:coop_protocol_error, :output_artifact}}
      end)
    end

    with_unix_binary_server(
      body,
      [
        {"content-type", "text/x-diff"},
        {"etag", ~s("#{digest}")},
        {"content-length", Integer.to_string(byte_size(body))}
      ],
      fn client, _request ->
        assert Client.get_review_patch(client, "op_review", digest, byte_size(body) - 1) ==
                 {:error, {:coop_protocol_error, :review_patch}}
      end
    )
  end

  test "normalizes semantic violations exactly as Coop counts them" do
    digest = String.duplicate("a", 64)
    rejected = %{"turn" => %{"id" => "turn_123", "state" => "running"}}

    with_unix_server(rejected, fn client, request ->
      assert {:ok, ^rejected} =
               Client.validate_candidate(
                 client,
                 "remote_123",
                 "turn_123",
                 "validation:boundary",
                 digest,
                 {:reject, ["  " <> String.duplicate("x", 4_095) <> "  "]}
               )

      assert Jason.decode!(request.().body)["violations"] == [String.duplicate("x", 4_095)]
    end)
  end

  defp with_unix_server(response, function), do: with_unix_server(response, 200, function)

  defp with_unix_server(response, status, function) do
    parent = self()
    socket_path = "/tmp/responder-coop-#{System.unique_integer([:positive])}.sock"
    File.rm(socket_path)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, socket_path}
      ])

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        captured = receive_request(socket)
        body = Jason.encode!(response)
        reason = if status == 200, do: "OK", else: "Not Found"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        send(parent, {:captured_request, self(), captured})
      end)

    finch = String.to_atom("coop_finch_#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: finch})
    assert {:ok, client} = Client.new(finch: finch, receive_timeout: 2_000, socket: socket_path)

    request = fn ->
      assert_receive {:captured_request, ^server, captured}, 2_000
      captured
    end

    try do
      function.(client, request)
    after
      :gen_tcp.close(listener)
      File.rm(socket_path)
    end
  end

  defp with_unix_binary_server(body, headers, function) do
    parent = self()
    socket_path = "/tmp/responder-coop-#{System.unique_integer([:positive])}.sock"
    File.rm(socket_path)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, socket_path}
      ])

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        captured = receive_request(socket)

        response_headers =
          headers
          |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\n#{response_headers}connection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        send(parent, {:captured_request, self(), captured})
      end)

    finch = String.to_atom("coop_finch_#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: finch})
    assert {:ok, client} = Client.new(finch: finch, receive_timeout: 2_000, socket: socket_path)

    request = fn ->
      assert_receive {:captured_request, ^server, captured}, 2_000
      captured
    end

    try do
      function.(client, request)
    after
      :gen_tcp.close(listener)
      File.rm(socket_path)
    end
  end

  defp receive_request(socket) do
    {head, initial_body} = receive_head(socket, "")
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = if length == 0, do: "", else: recv_exact(socket, length, initial_body)

    %{body: body, headers: headers, method: method, path: path}
  end

  defp receive_head(socket, data) do
    case :binary.match(data, "\r\n\r\n") do
      {position, 4} ->
        head = binary_part(data, 0, position)
        body_start = position + 4
        body = binary_part(data, body_start, byte_size(data) - body_start)
        {head, body}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        receive_head(socket, data <> chunk)
    end
  end

  defp recv_exact(_socket, expected, data) when byte_size(data) == expected, do: data

  defp recv_exact(socket, expected, data) do
    {:ok, chunk} = :gen_tcp.recv(socket, expected - byte_size(data), 2_000)
    recv_exact(socket, expected, data <> chunk)
  end

  defp input_artifact(digest, data) do
    %{
      "data" => data,
      "media_type" => "image/png",
      "name" => "input.png",
      "sha256" => digest
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
