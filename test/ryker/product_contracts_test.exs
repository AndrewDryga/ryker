defmodule Ryker.ProductContractsTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.CSRF
  alias Ryker.Ingress.{Projections, WorkProfile}
  alias Ryker.Publication.{LifecycleStatus, Receipt}

  alias Ryker.Slack.{
    ChannelSettingChangeset,
    ChannelSettingOverride,
    IncidentRoomChangeset,
    Supervisor
  }

  alias Ryker.Work.{RepositoryContext, SessionChangeset}

  @digest String.duplicate("a", 64)
  @standard_digest String.duplicate("b", 64)
  @deep_digest String.duplicate("c", 64)
  @authority_digest String.duplicate("d", 64)

  test "trusted work placement has one exact bounded representation" do
    attributes = [
      policy: "work-repository-write",
      policy_digest: @digest,
      repository_ref: "acme/ryker"
    ]

    assert {:ok, profile} = WorkProfile.new(attributes)
    assert profile.policy == "work-repository-write"
    assert profile.policy_digest == @digest
    assert profile.repository_ref == "acme/ryker"
    assert WorkProfile.prepare(profile) == {:ok, profile}
    assert WorkProfile.prepare(nil) == {:ok, nil}

    assert WorkProfile.new(policy: "one", policy: "two") ==
             {:error, {:invalid_work_profile, :fields}}

    assert WorkProfile.new(%{}) == {:error, {:invalid_work_profile, :fields}}
    assert WorkProfile.new(:invalid) == {:error, {:invalid_work_profile, :fields}}

    assert WorkProfile.new(%{
             policy: "",
             policy_digest: @digest,
             repository_ref: nil
           }) == {:error, {:invalid_work_profile, :policy}}

    assert WorkProfile.new(%{
             policy: "work-read",
             policy_digest: String.upcase(@digest),
             repository_ref: nil
           }) == {:error, {:invalid_work_profile, :policy_digest}}

    assert WorkProfile.new(%{
             policy: "work-read",
             policy_digest: @digest,
             repository_ref: "\0crossed"
           }) == {:error, {:invalid_work_profile, :repository_ref}}
  end

  test "trusted work placement selects an abstract class without exposing model authority" do
    attributes = %{
      authority_digest: @authority_digest,
      policy: "work-conversational",
      policy_digest: @digest,
      repository_ref: "acme/ryker",
      class_policies: %{
        conversational: %{
          authority_digest: @authority_digest,
          policy: "work-conversational",
          policy_digest: @digest
        },
        standard: %{
          authority_digest: @authority_digest,
          policy: "work-standard",
          policy_digest: @standard_digest
        },
        deep: %{
          authority_digest: @authority_digest,
          policy: "work-deep",
          policy_digest: @deep_digest
        }
      }
    }

    assert {:ok, profile} = WorkProfile.new(attributes)

    assert {:ok,
            %{
              name: "work-conversational",
              digest: @digest,
              repository_ref: "acme/ryker"
            }} = WorkProfile.policy_for(profile, :conversational)

    assert {:ok, %{name: "work-standard", digest: @standard_digest, repository_ref: "acme/ryker"}} =
             WorkProfile.policy_for(profile, :standard)

    assert {:ok, %{name: "work-deep", digest: @deep_digest, repository_ref: "acme/ryker"}} =
             WorkProfile.policy_for(profile, :deep)

    document = WorkProfile.document(profile)
    assert {:ok, ^profile} = WorkProfile.restore(document)

    assert WorkProfile.restore(%{}) == {:error, {:invalid_work_profile, :fields}}

    assert {:error, {:invalid_work_profile, :class_policies}} =
             WorkProfile.new(%{
               attributes
               | class_policies: Map.delete(attributes.class_policies, :deep)
             })

    for malformed <- [
          [],
          %{attributes.class_policies | deep: nil},
          %{attributes.class_policies | deep: %{policy: "", policy_digest: @deep_digest}}
        ] do
      assert {:error, {:invalid_work_profile, :class_policies}} =
               WorkProfile.new(%{attributes | class_policies: malformed})
    end

    assert {:error, {:invalid_work_profile, :class_policies}} =
             document
             |> put_in(["class_policies", "deep"], nil)
             |> WorkProfile.restore()

    assert {:error, {:invalid_work_profile, :class_policies}} =
             document
             |> Map.put("class_policies", [])
             |> WorkProfile.restore()

    assert {:error, {:invalid_work_profile, :work_class}} =
             WorkProfile.policy_for(profile, :provider_named_by_model)
  end

  # Work in an environment changes its first repository and only reads the
  # others. The frozen profile carries exactly that split, and the session
  # pinned from it derives the workspace Coop must mount from these fields, so
  # a profile that lost the order or smuggled the writable repository in among
  # the read-only ones would widen what the work can change.
  test "work in an environment changes its first repository and reads the others" do
    attributes = %{
      authority_digest: nil,
      class_policies: nil,
      emisar_connection_ref: "production",
      environment_ref: "platform",
      parallel_goal_limit: 2,
      policy: "platform-read",
      policy_digest: @digest,
      read_only_repository_refs: ["application", "runbooks"],
      repository_ref: "infrastructure"
    }

    assert {:ok, profile} = WorkProfile.new(attributes)
    assert profile.repository_ref == "infrastructure"
    assert profile.read_only_repository_refs == ["application", "runbooks"]

    assert {:ok, policy} = WorkProfile.policy_for(profile, :conversational)
    assert policy.environment_ref == "platform"
    assert policy.repository_ref == "infrastructure"

    assert policy.repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "infrastructure",
             "read_only_repositories" => ["application", "runbooks"]
           }

    assert {:ok, ^profile} = profile |> WorkProfile.document() |> WorkProfile.restore()

    # An environment without repositories still names itself and its Emisar
    # account, and mounts nothing.
    assert {:ok, ops} =
             WorkProfile.new(%{attributes | read_only_repository_refs: [], repository_ref: nil})

    assert {:ok, ops_policy} = WorkProfile.policy_for(ops, :conversational)
    assert %{environment_ref: "platform", repository_ref: nil} = ops_policy
    refute Map.has_key?(ops_policy, :repository_context)
    assert {:ok, ^ops} = ops |> WorkProfile.document() |> WorkProfile.restore()

    # Work outside any environment carries no placement at all.
    assert {:ok, outside} =
             WorkProfile.new(%{
               policy: "chat",
               policy_digest: @digest,
               repository_ref: nil
             })

    assert outside.environment_ref == nil
    assert outside.read_only_repository_refs == []

    refute Enum.any?(
             ~w(environment_ref parallel_goal_limit read_only_repository_refs emisar_connection_ref),
             &Map.has_key?(WorkProfile.document(outside), &1)
           )

    for {invalid, field} <- [
          {%{attributes | read_only_repository_refs: ["infrastructure"]},
           :read_only_repository_refs},
          {%{attributes | read_only_repository_refs: ["application", "application"]},
           :read_only_repository_refs},
          {%{attributes | repository_ref: nil}, :read_only_repository_refs},
          {%{attributes | parallel_goal_limit: 4}, :parallel_goal_limit},
          {%{attributes | parallel_goal_limit: nil}, :parallel_goal_limit},
          {%{attributes | environment_ref: "Platform"}, :environment_ref},
          {%{attributes | environment_ref: nil}, :read_only_repository_refs},
          {%{attributes | environment_ref: nil, read_only_repository_refs: []},
           :parallel_goal_limit},
          {%{
             attributes
             | environment_ref: nil,
               read_only_repository_refs: [],
               parallel_goal_limit: nil
           }, :emisar_connection_ref}
        ] do
      assert WorkProfile.new(invalid) == {:error, {:invalid_work_profile, field}},
             inspect(invalid)
    end

    tampered =
      profile
      |> WorkProfile.document()
      |> Map.put("read_only_repository_refs", ["infrastructure"])

    assert WorkProfile.restore(tampered) ==
             {:error, {:invalid_work_profile, :read_only_repository_refs}}

    assert WorkProfile.restore(Map.put(WorkProfile.document(profile), "repository_context", %{})) ==
             {:error, {:invalid_work_profile, :fields}}

    assert WorkProfile.restore(:invalid) == {:error, {:invalid_work_profile, :fields}}
  end

  test "repository contexts reject values outside their typed document contract" do
    assert RepositoryContext.prepare(:invalid, "ryker") == {:error, :invalid}
    assert RepositoryContext.restore(:invalid, "ryker") == {:error, :invalid}
    assert RepositoryContext.document(nil) == nil
  end

  test "persistence changesets reject malformed repository contexts" do
    session_changeset =
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        1,
        "work-read-only",
        @digest,
        "ryker",
        "session:repository-context",
        %{authority_digest: nil, repository_context: %{}, workspace_task: nil}
      )

    assert Keyword.has_key?(session_changeset.errors, :repository_context)

    room_changeset =
      IncidentRoomChangeset.insert(%{repository_context: %{}, repository_ref: "ryker"})

    assert Keyword.has_key?(room_changeset.errors, :repository_context)
  end

  test "model classes cannot widen the trusted execution authority" do
    attributes = %{
      authority_digest: @authority_digest,
      policy: "work-conversational",
      policy_digest: @digest,
      repository_ref: "acme/ryker",
      class_policies: %{
        conversational: %{
          authority_digest: @authority_digest,
          policy: "work-conversational",
          policy_digest: @digest
        },
        standard: %{
          authority_digest: @authority_digest,
          policy: "work-standard",
          policy_digest: @standard_digest
        },
        deep: %{
          authority_digest: @authority_digest,
          policy: "work-deep",
          policy_digest: @deep_digest
        }
      }
    }

    assert {:ok, profile} = WorkProfile.new(attributes)

    for work_class <- [:conversational, :standard, :deep] do
      assert {:ok, %{authority_digest: @authority_digest}} =
               WorkProfile.policy_for(profile, work_class)
    end

    assert {:error, {:invalid_work_profile, :authority_equivalence}} =
             attributes
             |> put_in([:class_policies, :deep, :authority_digest], String.duplicate("e", 64))
             |> WorkProfile.new()
  end

  test "publication receipts bind the exact reviewed GitHub identity" do
    review = %{"candidate_tree" => String.duplicate("b", 40)}

    receipt = %{
      "branch_ref" => "refs/heads/ryker/fix",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => String.duplicate("c", 40),
      "pull_request_number" => 91,
      "pull_request_url" => "https://github.com/acme/ryker/pull/91",
      "repository" => "acme/ryker"
    }

    assert Receipt.prepare(receipt, review, "acme/ryker") == {:ok, receipt}
    assert Receipt.fingerprint(receipt) =~ ~r/^[a-f0-9]{64}$/

    for crossed <- [
          Map.put(receipt, "repository", "other/repository"),
          Map.put(receipt, "candidate_tree", String.duplicate("d", 40)),
          Map.put(receipt, "branch_ref", "main"),
          Map.put(receipt, "commit_sha", "not-a-commit"),
          Map.put(receipt, "pull_request_number", 0),
          Map.put(receipt, "pull_request_url", "http://github.com/acme/ryker/pull/91"),
          Map.put(receipt, "pull_request_url", "https://example.com/acme/ryker/pull/91"),
          Map.put(receipt, "pull_request_url", "https://github.com/acme/ryker/issues/91"),
          Map.put(receipt, "pull_request_url", 91)
        ] do
      assert Receipt.prepare(crossed, review, "acme/ryker") ==
               {:error, {:invalid_publication_receipt, :identity}}
    end

    invalid_utf8 = Map.put(receipt, "repository", <<255>>)

    assert Receipt.prepare(invalid_utf8, review, <<255>>) ==
             {:error, {:invalid_publication_receipt, :document}}

    assert Receipt.prepare(:invalid, review, "acme/ryker") ==
             {:error, {:invalid_publication_receipt, :document}}
  end

  test "channel setting audit and override changesets expose all durable forms" do
    override = %{
      actor_ref: "slack:user:U123",
      event_ref: "event:1",
      id: Ecto.UUID.generate(),
      revision: 1,
      scope_kind: :channel,
      scope_ref: "slack:T123:C456",
      setting: :proactive,
      value: true,
      workspace_ref: "slack:T123"
    }

    assert ChannelSettingChangeset.insert_override(override).valid?

    assert %ChannelSettingOverride{}
           |> ChannelSettingChangeset.update_override(%{
             actor_ref: "slack:user:U456",
             event_ref: "event:2",
             revision: 2,
             value: false
           })
           |> Map.fetch!(:valid?)

    assert ChannelSettingChangeset.insert_audit(%{
             actor_ref: "slack:user:U123",
             conversation_ref: "slack:T123:C456",
             detail: %{"setting" => "watch_mode"},
             event_ref: "event:audit:1",
             id: Ecto.UUID.generate(),
             occurred_at: ~U[2026-08-29 00:00:00.000000Z],
             outcome: :updated,
             request_fingerprint: @digest,
             workspace_ref: "slack:T123"
           }).valid?
  end

  test "invalid generic inputs fail before projection side effects" do
    assert Projections.observe(%{}, "input:1") ==
             {:error, {:invalid_ingress_projection, :input}}
  end

  test "the Slack supervision tree keeps each reconciler independently restartable" do
    assert {:ok, {flags, children}} =
             Supervisor.init(%{
               action_tokens: [name: nil],
               gateway: %{name: :gateway},
               incident_worker: %{name: :incident_worker},
               interaction_feedback_worker: %{name: :interaction_feedback_worker},
               reconciler: %{name: :reconciler},
               task_card_worker: %{name: :task_card_worker},
               thread_status_worker: %{name: :thread_status_worker}
             })

    assert flags.strategy == :one_for_one

    assert Enum.map(children, & &1.id) == [
             Ryker.Slack.ActionTokens,
             Ryker.Slack.Gateway,
             Ryker.Slack.MembershipReconciler,
             Ryker.Slack.IncidentRoomWorker,
             Ryker.Slack.InteractionFeedbackWorker,
             Ryker.Slack.TaskCardWorker,
             Ryker.Slack.ThreadStatusWorker
           ]
  end

  test "local mutation and GitHub lifecycle contracts reject untyped boundaries" do
    refute CSRF.valid?("secret", "forget", "memory:1", nil)

    assert LifecycleStatus.prepare(:invalid) ==
             {:error, {:invalid_publication_lifecycle_status, :document}}

    status = %{
      "base_ref" => "main",
      "checks_failed" => 0,
      "checks_passed" => 0,
      "checks_state" => "none",
      "checks_total" => 0,
      "checks_url" => "https://github.com/acme/ryker/pull/91/checks",
      "draft" => true,
      "head_ref" => "ryker/fix",
      "head_sha" => String.duplicate("b", 40),
      "merge_sha" => nil,
      "merged" => false,
      "merged_at" => nil,
      "number" => 91,
      "state" => "open",
      "url" => "https://github.com/acme/ryker/pull/91"
    }

    assert LifecycleStatus.prepare(%{status | "merge_sha" => String.duplicate("c", 40)}) ==
             {:error, {:invalid_publication_lifecycle_status, :merge}}

    assert LifecycleStatus.prepare(%{status | "checks_url" => 91}) ==
             {:error, {:invalid_publication_lifecycle_status, :document}}
  end
end
