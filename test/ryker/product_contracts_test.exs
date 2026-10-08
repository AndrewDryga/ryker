defmodule Ryker.ProductContractsTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.CSRF
  alias Ryker.Ingress.{Projections, WorkProfile}
  alias Ryker.Publication.{LifecycleStatus, Receipt}
  alias Ryker.Slack.{ChannelSettingAudit, IncidentRoom, Supervisor}
  alias Ryker.Work.{RepositoryContext, Session}

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

    assert WorkProfile.new(%{
             attributes
             | class_policies: Map.delete(attributes.class_policies, :deep)
           }) == {:error, {:invalid_work_profile, :class_policies}}

    for malformed <- [
          [],
          %{attributes.class_policies | deep: nil},
          %{attributes.class_policies | deep: %{policy: "", policy_digest: @deep_digest}}
        ] do
      assert WorkProfile.new(%{attributes | class_policies: malformed}) ==
               {:error, {:invalid_work_profile, :class_policies}}
    end

    assert document
           |> put_in(["class_policies", "deep"], nil)
           |> WorkProfile.restore() == {:error, {:invalid_work_profile, :class_policies}}

    assert document
           |> Map.put("class_policies", [])
           |> WorkProfile.restore() == {:error, {:invalid_work_profile, :class_policies}}

    assert WorkProfile.policy_for(profile, :provider_named_by_model) ==
             {:error, {:invalid_work_profile, :work_class}}
  end

  # An environment's repositories are a set. Every session in it mounts all of
  # them: the repository its work changes as the working copy and every other
  # one read-only. Which one a piece of work changes is chosen per task, so the
  # frozen profile keeps each repository's own policies and the first one only
  # as the default. The first pass made the first repository the only one work
  # could change, so a task about any other repository in the environment was
  # confirmed against the wrong working copy.
  test "a session mounts every repository of its environment, its own writable" do
    attributes = %{
      emisar_connection_ref: "production",
      environment_ref: "platform",
      parallel_goal_limit: 2,
      policies: %{
        "application" => class_policies("application"),
        "infrastructure" => class_policies("infrastructure"),
        "runbooks" => class_policies("runbooks")
      },
      repositories: ["infrastructure", "application", "runbooks"]
    }

    assert {:ok, profile} = WorkProfile.new(attributes)
    assert profile.repositories == ["infrastructure", "application", "runbooks"]
    assert WorkProfile.repository_choices(profile) == profile.repositories

    # The default placement is the first repository's, and it is what the
    # inbox records as the input's policy and repository.
    assert profile.repository_ref == "infrastructure"
    assert profile.policy == "infrastructure-conversational"
    assert profile.authority_digest == authority("infrastructure")

    assert {:ok, default} = WorkProfile.policy_for(profile, :conversational)
    assert default.name == "infrastructure-conversational"
    assert default.repository_ref == "infrastructure"

    assert default.repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "infrastructure",
             "read_only_repositories" => ["application", "runbooks"]
           }

    assert {:ok, chosen} = WorkProfile.policy_for(profile, :standard, "application")
    assert chosen.name == "application-standard"
    assert chosen.authority_digest == authority("application")
    assert chosen.environment_ref == "platform"
    assert chosen.repository_ref == "application"

    assert chosen.repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "application",
             "read_only_repositories" => ["infrastructure", "runbooks"]
           }

    # A repository outside the environment is no choice at all.
    assert WorkProfile.policy_for(profile, :deep, "elsewhere") ==
             {:error, {:invalid_work_profile, :repository_ref}}

    document = WorkProfile.document(profile)
    refute Map.has_key?(document, "class_policies")
    assert {:ok, ^profile} = WorkProfile.restore(document)

    # One repository is still an environment: its session mounts it alone.
    assert {:ok, single} =
             WorkProfile.new(%{
               attributes
               | policies: Map.take(attributes.policies, ["runbooks"]),
                 repositories: ["runbooks"]
             })

    assert WorkProfile.repository_choices(single) == []
    assert {:ok, %{repository_context: single_context}} = WorkProfile.policy_for(single, :deep)
    assert single_context["read_only_repositories"] == []

    # An environment without repositories still names itself and its Emisar
    # account, and mounts nothing.
    assert {:ok, ops} =
             WorkProfile.new(%{
               emisar_connection_ref: "production",
               environment_ref: "platform",
               parallel_goal_limit: 2,
               policy: "platform-chat",
               policy_digest: @digest,
               repository_ref: nil
             })

    assert ops.repositories == []
    assert {:ok, ops_policy} = WorkProfile.policy_for(ops, :conversational)
    assert %{environment_ref: "platform", repository_ref: nil} = ops_policy
    refute Map.has_key?(ops_policy, :repository_context)
    assert {:ok, ^ops} = ops |> WorkProfile.document() |> WorkProfile.restore()

    # Work outside any environment keeps its single-repository shape.
    assert {:ok, outside} =
             WorkProfile.new(%{policy: "ryker", policy_digest: @digest, repository_ref: "ryker"})

    assert outside.environment_ref == nil
    assert WorkProfile.repository_choices(outside) == []
    assert {:ok, %{repository_ref: "ryker"}} = WorkProfile.policy_for(outside, :deep, "ryker")

    assert WorkProfile.policy_for(outside, :deep, "infrastructure") ==
             {:error, {:invalid_work_profile, :repository_ref}}

    refute Enum.any?(
             ~w(environment_ref parallel_goal_limit repositories policies emisar_connection_ref),
             &Map.has_key?(WorkProfile.document(outside), &1)
           )

    for {invalid, field} <- [
          {%{attributes | repositories: ["infrastructure", "application"]}, :policies},
          {%{attributes | repositories: ["infrastructure", "infrastructure", "runbooks"]},
           :repositories},
          {%{attributes | repositories: []}, :repositories},
          {%{attributes | environment_ref: nil}, :repositories},
          {%{attributes | environment_ref: "Platform"}, :environment_ref},
          {%{attributes | parallel_goal_limit: 4}, :parallel_goal_limit},
          {put_in(attributes, [:policies, "runbooks", :deep, :authority_digest], @digest),
           :authority_equivalence},
          {Map.put(attributes, :repository_ref, "application"), :repository_ref},
          {Map.put(attributes, :class_policies, class_policies("infrastructure")),
           :class_policies}
        ] do
      assert WorkProfile.new(invalid) == {:error, {:invalid_work_profile, field}},
             inspect(invalid)
    end

    # The first pass froze the writable repository and the ones it only read;
    # that shape names no choice and is refused rather than read as one.
    assert WorkProfile.restore(Map.put(document, "read_only_repository_refs", ["runbooks"])) ==
             {:error, {:invalid_work_profile, :fields}}

    assert WorkProfile.restore(Map.put(document, "repositories", ["infrastructure"])) ==
             {:error, {:invalid_work_profile, :policies}}

    assert WorkProfile.restore(:invalid) == {:error, {:invalid_work_profile, :fields}}
  end

  # Andrew, 2026-09-27: "can we here limit read or read/write access per
  # repo?" A repository its environment only reads carries no policies of its
  # own in the frozen profile: every session mounts it read-only beside the
  # working copy, none opens it as the working copy, and routing never offers
  # it as the one new work changes. The default is always one work may change.
  test "a repository its environment only reads is mounted beside the working copy, never as it" do
    attributes = %{
      emisar_connection_ref: nil,
      environment_ref: "platform",
      parallel_goal_limit: 2,
      policies: %{
        "application" => class_policies("application"),
        "infrastructure" => class_policies("infrastructure")
      },
      repositories: ["infrastructure", "application", "runbooks"]
    }

    assert {:ok, profile} = WorkProfile.new(attributes)
    assert profile.repositories == ["infrastructure", "application", "runbooks"]
    assert WorkProfile.repository_refs(profile) == ["infrastructure", "application"]
    assert WorkProfile.read_only_refs(profile) == ["runbooks"]
    assert WorkProfile.repository_choices(profile) == ["infrastructure", "application"]

    assert {:ok, chosen} = WorkProfile.policy_for(profile, :standard, "application")

    assert chosen.repository_context["read_only_repositories"] == ["infrastructure", "runbooks"]

    assert WorkProfile.policy_for(profile, :standard, "runbooks") ==
             {:error, {:invalid_work_profile, :repository_ref}}

    assert {:ok, ^profile} = profile |> WorkProfile.document() |> WorkProfile.restore()

    # With one repository work may change there is nothing to choose between.
    assert {:ok, one} =
             WorkProfile.new(%{
               attributes
               | policies: Map.take(attributes.policies, ["infrastructure"])
             })

    assert WorkProfile.repository_choices(one) == []
    assert WorkProfile.read_only_refs(one) == ["application", "runbooks"]

    # A read-only default would leave work nothing to change by default.
    assert WorkProfile.new(%{
             attributes
             | repositories: ["runbooks", "infrastructure", "application"]
           }) == {:error, {:invalid_work_profile, :policies}}
  end

  test "repository contexts reject values outside their typed document contract" do
    assert RepositoryContext.prepare(:invalid, "ryker") == {:error, :invalid}
    assert RepositoryContext.restore(:invalid, "ryker") == {:error, :invalid}
    assert RepositoryContext.document(nil) == nil
  end

  test "persistence changesets reject malformed repository contexts" do
    session_changeset =
      Session.Changeset.insert(%{
        id: Ecto.UUID.generate(),
        episode_id: Ecto.UUID.generate(),
        generation: 1,
        policy: "work-read-only",
        policy_digest: @digest,
        repository_ref: "ryker",
        external_ref: "session:repository-context",
        authority_digest: nil,
        repository_context: %{},
        workspace_task: nil
      })

    assert Keyword.has_key?(session_changeset.errors, :repository_context)

    room_changeset =
      IncidentRoom.Changeset.insert(%{repository_context: %{}, repository_ref: "ryker"})

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

    assert attributes
           |> put_in([:class_policies, :deep, :authority_digest], String.duplicate("e", 64))
           |> WorkProfile.new() == {:error, {:invalid_work_profile, :authority_equivalence}}
  end

  test "publication receipts bind the exact reviewed GitHub identity" do
    review = %{
      "candidate_head" => String.duplicate("c", 40),
      "candidate_tree" => String.duplicate("b", 40)
    }

    receipt = %{
      "branch_ref" => "refs/heads/ryker/fix",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => review["candidate_head"],
      "pull_request_number" => 91,
      "pull_request_url" => "https://github.com/acme/ryker/pull/91",
      "repository" => "acme/ryker"
    }

    assert Receipt.prepare(receipt, review, "acme/ryker") == {:ok, receipt}
    assert Receipt.fingerprint(receipt) =~ ~r/^[a-f0-9]{64}$/

    # The link a task card and the weekly report open was checked for shape
    # only, so a receipt could name one pull request and link another
    # (2026-10-04 review).
    for crossed <- [
          Map.put(receipt, "pull_request_url", "https://github.com/acme/ryker/pull/92"),
          Map.put(receipt, "repository", "other/repository"),
          Map.put(receipt, "candidate_tree", String.duplicate("d", 40)),
          Map.put(receipt, "branch_ref", "main"),
          Map.put(receipt, "commit_sha", "not-a-commit"),
          Map.put(receipt, "commit_sha", String.duplicate("d", 40)),
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

  test "the channel setting audit changeset accepts the durable form" do
    assert ChannelSettingAudit.Changeset.insert(%{
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
               thread_status_worker: %{name: :thread_status_worker},
               transcription_worker: %{name: :transcription_worker},
               workspace_admins: [workspace: "T1", lookup: fn _user -> {:ok, false} end]
             })

    assert flags.strategy == :one_for_one

    # Who is a workspace admin is known before anything that hears Slack asks.
    assert Enum.map(children, & &1.id) == [
             Ryker.Slack.ActionTokens,
             Ryker.Slack.WorkspaceAdmins,
             Ryker.Slack.Gateway,
             # Voice messages the gateway recorded are transcribed after the ack.
             Ryker.Transcription.Worker,
             Ryker.Slack.MembershipReconciler,
             Ryker.Slack.IncidentRoomWorker,
             Ryker.Slack.InteractionFeedbackWorker,
             Ryker.Slack.TaskCardWorker,
             Ryker.Slack.ThreadStatusWorker,
             Ryker.Slack.Tasks
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

  defp class_policies(repository) do
    Map.new([:conversational, :standard, :deep], fn work_class ->
      {work_class,
       %{
         authority_digest: authority(repository),
         policy: "#{repository}-#{work_class}",
         policy_digest: sha256("#{repository}-#{work_class}")
       }}
    end)
  end

  defp authority(repository), do: sha256("authority:#{repository}")
  defp sha256(seed), do: :sha256 |> :crypto.hash(seed) |> Base.encode16(case: :lower)
end
