defmodule Ryker.CoopFleet.JobAuthorityTest do
  use Ryker.DataCase, async: true

  alias Ryker.CoopFleet.{Command, JobAuthority, JobSpec, JobTemplates, Placement, Worker}
  alias Ryker.{Episodes, Repo, Settings}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.GitHub.RepositoryFiles
  alias Ryker.TestSupport.RecordedGitHub
  alias Ryker.Work.{Custody, Session}
  alias Ryker.Work.Custody.Sessions

  @actor "control-plane:local"

  defmodule GatedReader do
    def read(_binding, _repository, ".agent/project.yaml", _ref), do: {:ok, "gate: make check\n"}
  end

  setup context do
    {:ok, _} = Settings.initialize(@actor)
    snapshot = add_repository!("app", 17)

    snapshot =
      if targets = context[:targets] do
        {:ok, snapshot} =
          Settings.put_pricing_rate(
            %{
              execution_target: "claude:claude-opus-4-6",
              input_usd_per_million: "5",
              cached_input_usd_per_million: "0.5",
              output_usd_per_million: "25",
              effective_from: ~D[2026-09-26],
              provenance: "https://www.anthropic.com/pricing"
            },
            snapshot.installation.revision,
            @actor
          )

        {:ok, snapshot} =
          Settings.save_work(
            %{model_accounts: ["codex@default", "claude@backup"], contributor_models: targets},
            snapshot.installation.revision,
            @actor
          )

        snapshot
      else
        snapshot
      end

    template =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :contributor and &1.scope_kind == :repository)
      )

    episode_id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "job:#{episode_id}",
          native_input_id: "job-input:#{episode_id}",
          occurred_at: Repo.now!(),
          turn_ref: "job-turn:#{episode_id}"
        })
      )

    {:ok, session} =
      Custody.pin_episode(
        episode_id,
        template.policy_name,
        template.policy_digest,
        template.authority_digest,
        "app"
      )

    %{session: session, snapshot: snapshot}
  end

  @tag targets: [
         "codex:gpt-5.6-sol/medium@default",
         "codex:gpt-5.6-terra/high@default",
         "claude:claude-opus-4-6/high@backup"
       ]
  test "freezes the model and provider ladder and exact source before placement", %{
    session: session,
    snapshot: snapshot,
    targets: targets
  } do
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)
    job = pinned.worker_job_document
    assert job["job_ref"] == session.external_ref
    assert job["targets"] == targets
    assert job["source"] == source()
    assert job["mode"] == "normal"
    refute job["repository_read_only"]
    assert job["version"] == 2
    refute Map.has_key?(job, "project_env")
    assert job["environment"] == %{}
    assert job["check"] == %{"argv" => [], "environment" => %{}}
    assert job["resources"] == JobTemplates.resources()
    assert job["egress"] == %{"mode" => "open", "rules" => [], "export_destinations" => false}
    assert {:ok, digest} = JobSpec.digest(job)
    assert pinned.worker_job_digest == digest
    assert Repo.get!(Session, session.id).worker_job_document == job
    assert Repo.aggregate(Placement, :count) == 0
    assert Repo.aggregate(Command, :count) == 0

    assert {:ok, _} =
             Settings.save_work(
               %{contributor_models: [hd(snapshot.work.contributor_models)]},
               snapshot.installation.revision,
               @actor
             )

    Repo.update_all(Settings.Repository, set: [github_access: :suspended])

    assert {:ok, ^pinned} =
             JobAuthority.ensure_pinned(Repo.get!(Session, session.id), nil, fn _, _, _ ->
               flunk("refetched a frozen job")
             end)
  end

  # Coop's job-setup:2 runs only the check a job names (Coop 33ea84fe): the parent's `gate:`
  # stopped applying to remote reviews, so emisar's `./run gate review` must be in the job.
  test "a working copy's job freezes its repository's gate as the check", %{session: session} do
    content =
      Base.encode64("gate: ./run gate review\nreview:\n  compose: dev/review-compose.yml\n")

    RecordedGitHub.reply([
      {:get, "/repos/example/app/contents/.agent/project.yaml?ref=#{String.duplicate("a", 40)}",
       {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64"}, headers: []}}}
    ])

    assert {:ok, pinned} =
             JobAuthority.ensure_pinned(
               session,
               "/private/source",
               &prepare/3,
               RepositoryFiles
             )

    assert pinned.worker_job_document["check"] == %{
             "argv" => ["./run", "gate", "review"],
             "environment" => %{}
           }

    assert RecordedGitHub.unanswered() == []
  end

  test "a gate GitHub cannot read now is a wait, never a job frozen without it", %{
    session: session
  } do
    RecordedGitHub.reply([
      {:get, "/repos/example/app/contents/.agent/project.yaml?ref=#{String.duplicate("a", 40)}",
       {:error, :timeout}}
    ])

    assert {:error, :coop_worker_source_unavailable} =
             JobAuthority.ensure_pinned(
               session,
               "/private/source",
               &prepare/3,
               RepositoryFiles
             )

    assert Repo.get!(Session, session.id).worker_job_document == nil
  end

  # A session pinned before the move but never created would only be refused by a version-2
  # worker. It moves with its grant intact and gets its check like a fresh pin.
  test "a version-1 job on a session never created is pinned again as version 2", %{
    session: session
  } do
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)

    v1 =
      pinned.worker_job_document
      |> Map.drop(~w(environment check resources))
      |> Map.merge(%{"version" => 1, "project_env" => false, "project_mcp" => false})

    session =
      pinned
      |> Ecto.Changeset.change(
        worker_job_document: v1,
        worker_job_digest: Ryker.CanonicalJSON.worker_digest(v1)
      )
      |> Repo.update!()

    assert {:ok, moved} = JobAuthority.ensure_pinned(session, nil, &prepare/3, GatedReader)
    job = moved.worker_job_document
    assert job["version"] == 2
    refute Map.has_key?(job, "project_env")
    assert job["check"] == %{"argv" => ["make", "check"], "environment" => %{}}
    assert job["source"] == v1["source"]
    assert {:ok, digest} = JobSpec.digest(job)
    assert Repo.get!(Session, session.id).worker_job_digest == digest
  end

  # Closing and removing a session run nothing under its grant. Checking a version-1 job as one
  # Ryker would grant today refused every cleanup of a session created before version 2: three
  # sessions on each install stopped as "the worker's answer didn't match this session" the day
  # the workers moved, and kept their folders on the worker (2026-10-04).
  test "a session created under a version-1 job can still be cleaned up, never resumed", %{
    session: session
  } do
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)

    v1 =
      pinned.worker_job_document
      |> Map.drop(~w(environment check resources))
      |> Map.merge(%{"version" => 1, "project_env" => false, "project_mcp" => false})

    created =
      pinned
      |> Ecto.Changeset.change(
        worker_job_document: v1,
        worker_job_digest: Ryker.CanonicalJSON.worker_digest(v1),
        coop_session_id: "created-under-version-1"
      )
      |> Repo.update!()

    receipt = %{
      "id" => "created-under-version-1",
      "external_ref" => Session.coop_task_ref(created),
      "job_ref" => created.external_ref,
      "job_digest" => created.worker_job_digest
    }

    assert :ok = JobAuthority.exact_cleanup_receipt(created, receipt)

    assert {:error, {:coop_protocol_error, :session_authority}} =
             JobAuthority.exact_receipt(created, receipt)

    for {field, value} <- [
          {"external_ref", "offer:other"},
          {"job_ref", "job:other"},
          {"job_digest", String.duplicate("0", 64)}
        ] do
      assert {:error, {:coop_protocol_error, :session_authority}} =
               JobAuthority.exact_cleanup_receipt(created, Map.put(receipt, field, value))
    end

    tampered = %{created | worker_job_document: Map.put(v1, "mode", "bare")}

    Repo.update!(
      Ecto.Changeset.change(created, worker_job_document: tampered.worker_job_document)
    )

    assert {:error, {:coop_protocol_error, :session_authority}} =
             JobAuthority.exact_cleanup_receipt(tampered, receipt)
  end

  test "workspace task identity does not replace the execution generation identity", %{
    session: session
  } do
    session =
      session
      |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => "offer:shared"})
      |> Repo.update!()

    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)
    assert pinned.worker_job_document["job_ref"] == session.external_ref
    assert Session.coop_task_ref(pinned) == "offer:shared"

    changed = Map.put(pinned.worker_job_document, "job_ref", "offer:shared")
    {:ok, digest} = JobSpec.digest(changed)

    assert {:error, {:coop_fleet_authority_mismatch, :worker_job}} =
             JobAuthority.validate(%{
               pinned
               | worker_job_document: changed,
                 worker_job_digest: digest
             })
  end

  test "receipts prove the frozen job and independent task, never policy aliases", %{
    session: session
  } do
    expected =
      session
      |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => "offer:shared"})
      |> Repo.update!()

    assert {:ok, pinned} = JobAuthority.ensure_pinned(expected, "/private/source", &prepare/3)
    refute pinned.worker_job_digest == expected.policy_digest

    receipt = %{
      "external_ref" => "offer:shared",
      "job_ref" => expected.external_ref,
      "job_digest" => pinned.worker_job_digest
    }

    assert :ok = JobAuthority.exact_receipt(expected, receipt)
    assert :ok = JobAuthority.exact_receipt(pinned, receipt)

    for {field, value} <- [
          {"external_ref", expected.external_ref},
          {"job_ref", "offer:shared"},
          {"job_digest", expected.policy_digest}
        ] do
      assert {:error, {:coop_protocol_error, :session_authority}} =
               JobAuthority.exact_receipt(expected, Map.put(receipt, field, value))
    end

    assert {:error, {:coop_protocol_error, :session_authority}} =
             JobAuthority.exact_receipt(expected, %{
               "external_ref" => "offer:shared",
               "policy" => expected.policy,
               "policy_digest" => expected.policy_digest
             })

    changed = %{pinned | worker_job_digest: String.duplicate("0", 64)}

    assert {:error, {:coop_protocol_error, :session_authority}} =
             JobAuthority.exact_receipt(changed, receipt)
  end

  test "jobless historical receipts authorize only cleanup of the already bound session", %{
    session: session
  } do
    session =
      session |> Ecto.Changeset.change(coop_session_id: "legacy-session") |> Repo.update!()

    receipt = %{"id" => "legacy-session", "external_ref" => session.external_ref}
    assert :ok = JobAuthority.exact_cleanup_receipt(session, receipt)
    assert {:error, _} = JobAuthority.exact_receipt(session, receipt)

    assert {:error, _} =
             JobAuthority.exact_cleanup_receipt(session, Map.put(receipt, "id", "other"))
  end

  test "a one-repository environment retains its repository-scoped execution purpose", %{
    session: session
  } do
    session = session |> Ecto.Changeset.change(environment_ref: "production") |> Repo.update!()
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)
    assert pinned.worker_job_document["source"]["repository_ref"] == "app"
  end

  test "no repository authorizes an empty private workspace without fetching code", %{
    session: session
  } do
    template =
      Enum.find(
        JobTemplates.from_settings(Settings.fetch!()),
        &(&1.purpose == :conversational and &1.scope_kind == :installation)
      )

    session =
      session
      |> Ecto.Changeset.change(
        policy: template.policy_name,
        policy_digest: template.policy_digest,
        authority_digest: template.authority_digest,
        repository_ref: nil,
        repository_source: nil,
        environment_ref: "no-repository"
      )
      |> Repo.update!()

    assert {:ok, pinned} =
             JobAuthority.ensure_pinned(session, nil, fn _, _, _ ->
               flunk("empty-workspace job fetched code")
             end)

    assert pinned.worker_job_document["mode"] == "normal"
    assert pinned.worker_job_document["source"] == nil
    assert pinned.worker_job_document["companions"] == []
    assert pinned.worker_job_document["repository_read_only"] == true
  end

  test "repository scope cannot acquire extra companions before source access", %{
    session: session
  } do
    session =
      session
      |> Ecto.Changeset.change(
        repository_context: %{
          "context_ref" => "scope:extra",
          "primary_repository" => "app",
          "read_only_repositories" => ["library"],
          "parallel_goal_limit" => 1
        }
      )
      |> Repo.update!()

    assert {:error, :coop_worker_job_settings_unavailable} =
             JobAuthority.ensure_pinned(session, nil, fn _, _, _ ->
               flunk("unauthorized source access")
             end)

    assert Repo.get!(Session, session.id).worker_job_document == nil
  end

  test "environment jobs admit exactly their ordered companion list", %{session: session} do
    add_repository!("library", 18)
    snapshot = add_repository!("tools", 19)

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["app", "library", "tools"]
        },
        snapshot.installation.revision,
        @actor
      )

    template =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :contributor and &1.scope_kind == :environment and
            &1.repository_ref == "app")
      )

    session =
      session
      |> Ecto.Changeset.change(
        environment_ref: "production",
        policy: template.policy_name,
        policy_digest: template.policy_digest,
        authority_digest: template.authority_digest
      )
      |> Repo.update!()

    context = %{
      "context_ref" => "production",
      "primary_repository" => "app",
      "read_only_repositories" => ["library", "tools"],
      "parallel_goal_limit" => 1
    }

    for refs <- [[], ["library"], ["tools", "library"]] do
      changed =
        session
        |> Ecto.Changeset.change(
          repository_context: Map.put(context, "read_only_repositories", refs)
        )
        |> Repo.update!()

      assert {:error, :coop_worker_job_settings_unavailable} =
               JobAuthority.ensure_pinned(changed, nil, fn _, _, _ ->
                 flunk("fetched an unapproved source list")
               end)
    end

    session = session |> Ecto.Changeset.change(repository_context: context) |> Repo.update!()

    assert {:ok, pinned} =
             JobAuthority.ensure_pinned(session, nil, fn _, ref, _ ->
               {:ok,
                %{
                  source:
                    source()
                    |> Map.put("repository_ref", ref)
                    |> Map.put("github_repository", "example/" <> ref)
                    |> Map.put(
                      "github_repository_id",
                      %{"app" => 17, "library" => 18, "tools" => 19}[ref]
                    )
                }}
             end)

    assert Enum.map(pinned.worker_job_document["companions"], & &1["name"]) == [
             "library",
             "tools"
           ]

    assert JobAuthority.validate(pinned) == {:ok, pinned}
  end

  # Found live 2026-09-28: review feedback on Ryker's pull request woke its
  # task a day later, and every new session for it failed eight times with
  # "job source identity or working tree does not match": the job kept each
  # companion at the commit its branch had when the task began, and the worker
  # refuses a branch that has moved since. Companions are read-only context:
  # before a session is first placed, each is resolved again.
  test "a session not yet placed follows its companions' branches, keeping its own source", %{
    session: session
  } do
    add_repository!("library", 18)
    snapshot = add_repository!("tools", 19)

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["app", "library", "tools"]
        },
        snapshot.installation.revision,
        @actor
      )

    template =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :contributor and &1.scope_kind == :environment and
            &1.repository_ref == "app")
      )

    session =
      session
      |> Ecto.Changeset.change(
        environment_ref: "production",
        policy: template.policy_name,
        policy_digest: template.policy_digest,
        authority_digest: template.authority_digest,
        repository_context: %{
          "context_ref" => "production",
          "primary_repository" => "app",
          "read_only_repositories" => ["library", "tools"],
          "parallel_goal_limit" => 1
        }
      )
      |> Repo.update!()

    at = fn commit ->
      fn _root, ref, _selector ->
        binding =
          source()["binding"]
          |> Map.merge(%{
            "default_commit" => commit,
            "selected_commit" => commit,
            "base_commit" => commit
          })

        {:ok,
         %{
           source:
             source()
             |> Map.merge(%{
               "repository_ref" => ref,
               "github_repository" => "example/" <> ref,
               "github_repository_id" => %{"app" => 17, "library" => 18, "tools" => 19}[ref],
               "binding" => binding
             })
         }}
      end
    end

    commits = fn pinned ->
      [
        pinned.worker_job_document["source"]
        | Enum.map(pinned.worker_job_document["companions"], & &1["source"])
      ]
      |> Enum.map(& &1["binding"]["default_commit"])
    end

    began = String.duplicate("1", 40)
    moved = String.duplicate("2", 40)

    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, nil, at.(began))
    assert commits.(pinned) == [began, began, began]

    # Nothing moved: the job and its digest stay as they are.
    assert {:ok, same} = JobAuthority.ensure_pinned(pinned, nil, at.(began))
    assert same.worker_job_digest == pinned.worker_job_digest

    # The companions' branches moved: they are pinned anew; the task's own
    # source stays at the commit it began from. The woken task was placed and
    # its create refused eight times; no worker holds a copy of its job.
    worker_id = "worker-refused-#{session.id}"
    now = DateTime.utc_now()
    requirements = %{"workspace_ref" => "workspace-main"}

    Repo.insert!(%Worker{
      capabilities: [],
      capacity: %{},
      certificate_sha256: :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower),
      id: worker_id,
      last_seen_at: now,
      state: :eligible,
      workspace_ref: "workspace-main"
    })

    Repo.insert!(%Placement{
      episode_id: session.episode_id,
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: now,
      lease_expires_at: DateTime.add(now, 3_600, :second),
      lease_ref: "placement-lease:#{session.id}",
      requirements: requirements,
      requirements_fingerprint: Ryker.CanonicalJSON.digest(requirements),
      session_id: session.id,
      state: :retired,
      updated_at: now,
      worker_id: worker_id
    })

    key = "ryker:work:create:#{session.id}:g1"

    Repo.insert!(%Command{
      id: Ecto.UUID.generate(),
      session_id: session.id,
      kind: "create_session",
      command_version: 2,
      payload: %{"external_ref" => session.external_ref},
      payload_fingerprint: String.duplicate("f", 64),
      idempotency_key: key,
      operation_key: key,
      status: :failed,
      error: %{"code" => "operation_not_enqueued", "detail" => "refused"},
      result_fingerprint: String.duplicate("e", 64),
      completed_at: DateTime.utc_now()
    })

    assert {:ok, refreshed} = JobAuthority.ensure_pinned(pinned, nil, at.(moved))
    assert commits.(refreshed) == [began, moved, moved]
    assert refreshed.worker_job_digest != pinned.worker_job_digest
    assert JobAuthority.validate(refreshed) == {:ok, refreshed}
    assert Repo.get!(Session, session.id).worker_job_digest == refreshed.worker_job_digest

    # The executor that prepared the create adopts the new job before it reads
    # the worker's receipt: one still holding the old job had its created
    # session closed as "session_authority".
    remote = %{
      "external_ref" => Session.coop_task_ref(refreshed),
      "job_ref" => refreshed.external_ref,
      "job_digest" => refreshed.worker_job_digest
    }

    assert {:error, {:coop_protocol_error, :session_authority}} =
             JobAuthority.exact_receipt(pinned, remote)

    assert {:ok, adopted} = JobAuthority.prepared(pinned)
    assert adopted.worker_job_digest == refreshed.worker_job_digest
    assert JobAuthority.exact_receipt(adopted, remote) == :ok

    # A session already created on a worker keeps the job it was created with.
    placed =
      refreshed |> Ecto.Changeset.change(coop_session_id: "coop-session-placed") |> Repo.update!()

    assert {:ok, kept} =
             JobAuthority.ensure_pinned(placed, nil, fn _, _, _ ->
               flunk("resolved the sources of a placed session")
             end)

    assert kept.worker_job_digest == refreshed.worker_job_digest
  end

  test "a session Coop runs directly has no worker job to adopt", %{session: session} do
    # 09118beb made the executor adopt a job preparation re-pinned before it
    # creates the session. A session Coop runs directly holds no job, and
    # validating one anyway failed its create before any turn: every eval
    # world ran no model, and the gate's world runner test said "unrun".
    assert is_nil(session.worker_job_document)
    assert JobAuthority.prepared(session) == {:ok, session}

    # The caller still has to hold the session's own identity.
    assert JobAuthority.prepared(%{session | generation: session.generation + 1}) ==
             {:error, {:coop_fleet_authority_mismatch, :worker_job}}
  end

  # Found live 2026-09-28: two repositories were removed from Ryker while a
  # #test conversation's authority still named them as companions. A
  # replacement keeps its predecessor's authority, so every new session for
  # that conversation asked the worker to fetch a repository Ryker no longer
  # grants, and Work failed "fetch job source" until its attempts ran out.
  # A replacement may narrow its authority, never widen it.
  test "a replacement's authority drops companions Ryker no longer has", %{session: session} do
    pinned = pinned_with_companions!(session)

    {:ok, snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["app", "library"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.delete_github_binding("tools", snapshot.installation.revision, @actor)

    {:ok, _snapshot} =
      Settings.delete_repository("tools", snapshot.installation.revision, @actor)

    assert {:ok, authority} =
             JobAuthority.without_removed_repositories(Sessions.session_authority(pinned))

    assert Enum.map(authority.worker_job_document["companions"], & &1["name"]) == ["library"]
    assert authority.repository_context["read_only_repositories"] == ["library"]
    assert {:ok, authority.worker_job_digest} == JobSpec.digest(authority.worker_job_document)
    assert JobAuthority.removed_repositories?(pinned)

    refute JobAuthority.removed_repositories?(%{
             pinned
             | worker_job_document: authority.worker_job_document
           })

    # The companion goes whether or not the session names a repository
    # context. A replacement that kept it would still be one to replace, so
    # Work would replace it again on every attempt.
    assert {:ok, without_context} =
             JobAuthority.without_removed_repositories(%{
               Sessions.session_authority(pinned)
               | repository_context: nil
             })

    assert without_context.worker_job_document == authority.worker_job_document
    assert without_context.repository_context == nil
  end

  # Six active sessions on 2026-10-04 still carried version-1 jobs with three to five companions
  # each. Replacing one narrowed its companions before upgrading it, and the narrowing computed the
  # new digest with `{:ok, digest} = JobSpec.digest(job)`, which only takes version 2: a removed
  # companion made the next generation raise, and every Work slot crashed on that episode.
  test "a version-1 job with a removed companion moves to version 2 without it", %{
    session: session
  } do
    pinned = pinned_with_companions!(session)

    v1 =
      pinned.worker_job_document
      |> Map.drop(~w(environment check resources))
      |> Map.merge(%{"version" => 1, "project_env" => false, "project_mcp" => false})

    pinned =
      pinned
      |> Ecto.Changeset.change(
        worker_job_document: v1,
        worker_job_digest: Ryker.CanonicalJSON.worker_digest(v1)
      )
      |> Repo.update!()

    {:ok, snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["app", "library"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.delete_github_binding("tools", snapshot.installation.revision, @actor)

    {:ok, _snapshot} = Settings.delete_repository("tools", snapshot.installation.revision, @actor)

    assert {:ok, next} =
             Sessions.insert_session(
               pinned.episode_id,
               pinned.generation + 1,
               Sessions.session_authority(pinned)
             )

    assert next.worker_job_document["version"] == 2
    assert Enum.map(next.worker_job_document["companions"], & &1["name"]) == ["library"]
    assert {:ok, next.worker_job_digest} == JobSpec.digest(next.worker_job_document)
    assert next.worker_job_document["job_ref"] == next.external_ref
  end

  test "incident work in an environment pins only its configured repository set", %{
    session: session
  } do
    snapshot = add_repository!("library", 18)

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["app", "library"],
          access: %{"library" => :read_only}
        },
        snapshot.installation.revision,
        @actor
      )

    incident =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :incident and &1.scope_kind == :installation)
      )

    context = %{
      "context_ref" => "production",
      "primary_repository" => "app",
      "read_only_repositories" => ["library"],
      "parallel_goal_limit" => 3
    }

    session =
      session
      |> Ecto.Changeset.change(
        environment_ref: "production",
        policy: incident.policy_name,
        policy_digest: incident.policy_digest,
        authority_digest: incident.authority_digest,
        repository_context: context
      )
      |> Repo.update!()

    prepare = fn _, ref, _ ->
      {:ok,
       %{
         source:
           source()
           |> Map.put("repository_ref", ref)
           |> Map.put("github_repository", "example/" <> ref)
           |> Map.put("github_repository_id", %{"app" => 17, "library" => 18}[ref])
       }}
    end

    for invalid <- [
          Map.put(context, "read_only_repositories", []),
          Map.put(context, "read_only_repositories", ["other"])
        ] do
      changed =
        session
        |> Ecto.Changeset.change(repository_context: invalid)
        |> Repo.update!()

      assert {:error, :coop_worker_job_settings_unavailable} =
               JobAuthority.ensure_pinned(changed, nil, fn _, _, _ ->
                 flunk("fetched an unapproved incident source list")
               end)
    end

    session =
      session
      |> then(&Repo.get!(Session, &1.id))
      |> Ecto.Changeset.change(repository_context: context)
      |> Repo.update!()

    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, nil, prepare)
    assert pinned.worker_job_document["repository_read_only"]
    assert Enum.map(pinned.worker_job_document["companions"], & &1["name"]) == ["library"]
  end

  test "settings changed during source resolution leave no partial job", %{session: session} do
    prepare = fn root, ref, selector ->
      snapshot = Settings.fetch!()

      assert {:ok, _} =
               Settings.save_work(
                 %{ready_routing_sessions: 2},
                 snapshot.installation.revision,
                 @actor
               )

      prepare(root, ref, selector)
    end

    assert {:error, :coop_worker_job_settings_changed} =
             JobAuthority.ensure_pinned(session, "/private/source", prepare)

    assert Repo.get!(Session, session.id).worker_job_document == nil
    assert Repo.aggregate(Placement, :count) == 0
  end

  test "a simultaneous valid pin wins instead of moving the source on retry", %{session: session} do
    prepare = fn root, _ref, _selector ->
      assert {:ok, pinned} = JobAuthority.ensure_pinned(session, root, &prepare/3)
      send(self(), {:winner, pinned.worker_job_digest})
      {:ok, %{source: put_in(source(), ["binding", "resolved_at"], "2026-09-26T13:00:00Z")}}
    end

    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", prepare)
    assert_received {:winner, digest}
    assert pinned.worker_job_digest == digest

    assert pinned.worker_job_document["source"]["binding"]["resolved_at"] ==
             "2026-09-26T12:00:00Z"
  end

  test "source or selector mismatch cannot grant a job", %{session: session} do
    for invalid <- [
          Map.put(source(), "github_repository_id", 18),
          put_in(source(), ["binding", "requested"], %{"kind" => "branch", "name" => "other"})
        ] do
      assert {:error, :coop_worker_source_unavailable} =
               JobAuthority.ensure_pinned(session, "/private/source", fn _, _, _ ->
                 {:ok, %{source: invalid}}
               end)

      assert Repo.get!(Session, session.id).worker_job_document == nil
    end
  end

  # tenantcorp/tenant-core, read-only in a tenant environment, vendors skypjack/entt, which Ryker
  # was never given. Every task there spent eight tries in two minutes and stopped as "source
  # unavailable", and nothing said which repository or why (2026-10-03).
  test "a submodule Ryker cannot fetch stops the job, naming the repository and the submodule",
       %{session: session} do
    refused = fn _root, ref, _selector ->
      {:error, {:coop_worker_source_refused, "example/" <> ref, "skypjack/entt"}}
    end

    assert {:error, {:coop_worker_source_refused, "example/app", "skypjack/entt"}} =
             JobAuthority.ensure_pinned(session, "/private/source", refused)

    add_repository!("library", 18)
    snapshot = add_repository!("tools", 19)

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["app", "library", "tools"]
        },
        snapshot.installation.revision,
        @actor
      )

    template =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :contributor and &1.scope_kind == :environment and
            &1.repository_ref == "app")
      )

    session =
      session
      |> Ecto.Changeset.change(
        environment_ref: "production",
        policy: template.policy_name,
        policy_digest: template.policy_digest,
        authority_digest: template.authority_digest,
        repository_context: %{
          "context_ref" => "production",
          "primary_repository" => "app",
          "read_only_repositories" => ["library", "tools"],
          "parallel_goal_limit" => 1
        }
      )
      |> Repo.update!()

    prepare = fn
      _root, "tools", _selector ->
        {:error, {:coop_worker_source_refused, "example/tools", "skypjack/entt"}}

      _root, ref, _selector ->
        {:ok,
         %{
           source:
             source()
             |> Map.put("repository_ref", ref)
             |> Map.put("github_repository", "example/" <> ref)
             |> Map.put("github_repository_id", %{"app" => 17, "library" => 18}[ref])
         }}
    end

    assert {:error, {:coop_worker_companion_refused, "example/tools", "skypjack/entt"}} =
             JobAuthority.ensure_pinned(session, nil, prepare)

    assert Repo.get!(Session, session.id).worker_job_document == nil
  end

  test "invalid persisted authority is never silently rebuilt", %{session: session} do
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)

    assert {:error, {:coop_fleet_authority_mismatch, :worker_job}} =
             JobAuthority.ensure_pinned(
               %{pinned | worker_job_digest: String.duplicate("f", 64)},
               nil,
               fn _, _, _ -> flunk("rebuilt invalid authority") end
             )
  end

  defp add_repository!(ref, id) do
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: ref, github_repository: "example/" <> ref, base_branch: "main"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _} =
      Settings.put_github_binding(
        %{
          name: ref,
          repository_ref: ref,
          installation_id: 41,
          repository_id: id,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        @actor
      )

    Repo.get_by!(Settings.Repository, ref: ref)
    |> Ecto.Changeset.change(source_commit: String.duplicate("a", 40))
    |> Repo.update!()

    Settings.fetch!()
  end

  defp prepare("/private/source", "app", %{"kind" => "default"}), do: {:ok, %{source: source()}}

  defp source do
    commit = String.duplicate("a", 40)

    %{
      "repository_ref" => "app",
      "github_repository" => "example/app",
      "github_repository_id" => 17,
      "submodules" => [],
      "binding" => %{
        "version" => 1,
        "kind" => "default",
        "requested" => %{"kind" => "default"},
        "remote_identity" => "origin",
        "default_ref" => "refs/heads/main",
        "selected_ref" => "refs/heads/main",
        "default_commit" => commit,
        "selected_commit" => commit,
        "base_commit" => commit,
        "admitted_tree" => String.duplicate("b", 40),
        "resolved_at" => "2026-09-26T12:00:00Z"
      }
    }
  end

  defp pinned_with_companions!(session) do
    add_repository!("library", 18)
    snapshot = add_repository!("tools", 19)

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["app", "library", "tools"]
        },
        snapshot.installation.revision,
        @actor
      )

    template =
      Enum.find(
        JobTemplates.from_settings(snapshot),
        &(&1.purpose == :contributor and &1.scope_kind == :environment and
            &1.repository_ref == "app")
      )

    session =
      session
      |> Ecto.Changeset.change(
        environment_ref: "production",
        policy: template.policy_name,
        policy_digest: template.policy_digest,
        authority_digest: template.authority_digest,
        repository_context: %{
          "context_ref" => "production",
          "primary_repository" => "app",
          "read_only_repositories" => ["library", "tools"],
          "parallel_goal_limit" => 1
        }
      )
      |> Repo.update!()

    assert {:ok, pinned} =
             JobAuthority.ensure_pinned(session, nil, fn _, ref, _ ->
               {:ok,
                %{
                  source:
                    source()
                    |> Map.put("repository_ref", ref)
                    |> Map.put("github_repository", "example/" <> ref)
                    |> Map.put(
                      "github_repository_id",
                      %{"app" => 17, "library" => 18, "tools" => 19}[ref]
                    )
                }}
             end)

    pinned
  end
end
