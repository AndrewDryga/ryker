defmodule Ryker.CoopFleet.JobAuthorityTest do
  use Ryker.DataCase, async: true

  alias Ryker.CoopFleet.{Command, JobAuthority, JobSpec, JobTemplates, Placement}
  alias Ryker.{Episodes, Repo, Settings}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, Session}

  @actor "control-plane:local"

  setup do
    {:ok, _} = Settings.initialize(@actor)
    snapshot = add_repository!("app", 17)

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

  test "freezes settings and exact source before any placement or command", %{
    session: session,
    snapshot: snapshot
  } do
    assert {:ok, pinned} = JobAuthority.ensure_pinned(session, "/private/source", &prepare/3)
    job = pinned.worker_job_document
    assert job["job_ref"] == session.external_ref
    assert job["targets"] == snapshot.work.contributor_models
    assert job["source"] == source()
    assert job["mode"] == "normal"
    refute job["repository_read_only"]
    assert job["project_env"] == false
    assert job["project_mcp"] == false
    assert job["egress"] == %{"mode" => "open", "rules" => [], "export_destinations" => false}
    assert {:ok, digest} = JobSpec.digest(job)
    assert pinned.worker_job_digest == digest
    assert Repo.get!(Session, session.id).worker_job_document == job
    assert Repo.aggregate(Placement, :count) == 0
    assert Repo.aggregate(Command, :count) == 0

    Repo.update_all(Settings.Repository, set: [github_access: :suspended])

    assert {:ok, ^pinned} =
             JobAuthority.ensure_pinned(pinned, nil, fn _, _, _ ->
               flunk("refetched a frozen job")
             end)
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
end
