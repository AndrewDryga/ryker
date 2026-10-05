defmodule Ryker.SettingsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query
  alias Ryker.ControlPlane.RepositoryNames
  alias Ryker.Retention.Data, as: RetentionData
  alias Ryker.Settings
  alias Ryker.Settings.{Edit, Installation, Retention}

  @actor "control-plane:local"
  @day 86_400

  test "historical policy rows do not keep an otherwise unreferenced repository alive" do
    {:ok, initialized} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(%{ref: "retired"}, initialized.installation.revision, @actor)

    Repo.query!("""
    INSERT INTO policy_bindings
      (id, purpose, scope_kind, scope_ref, policy_name, policy_digest, verified_by, inserted_at, updated_at)
    VALUES ('00000000-0000-4000-8000-000000000001', 'conversational', 'repository', 'retired',
      'retired-policy', repeat('a', 64), 'import', NOW(), NOW())
    """)

    assert {:ok, saved} =
             Settings.delete_repository("retired", snapshot.installation.revision, @actor)

    assert saved.repositories == []
    refute Map.has_key?(saved, :policy_bindings)
    assert Repo.query!("SELECT count(*) FROM policy_bindings").rows == [[1]]
  end

  test "a removed repository keeps the GitHub name its history reads, and one added again reads today's" do
    # Andrew, 2026-09-28: "repos must be named like on GH". Removing a
    # repository deleted its settings row, the only record of its GitHub name,
    # while 32 learning passes, 72 usage rows and two learned topics kept its
    # ref: every page then read "andrewdryga-andrewdryga", not
    # "AndrewDryga/AndrewDryga".
    {:ok, initialized} = Settings.initialize(@actor)

    {:ok, added} =
      Settings.put_repository(
        %{ref: "acme-api", github_repository: "Acme/API"},
        initialized.installation.revision,
        @actor
      )

    {:ok, removed} = Settings.delete_repository("acme-api", added.installation.revision, @actor)
    assert removed.repositories == []
    assert RepositoryNames.all() == %{"acme-api" => "Acme/API"}
    assert RepositoryNames.name(RepositoryNames.all(), "acme-api") == "Acme/API"
    assert RepositoryNames.name(%{}, "never-added") == "never-added"

    {:ok, _again} =
      Settings.put_repository(
        %{ref: "acme-api", github_repository: "Acme/api-renamed"},
        removed.installation.revision,
        @actor
      )

    assert RepositoryNames.all() == %{"acme-api" => "Acme/api-renamed"}
  end

  test "a missing installation is explicit rather than an implicit default grant" do
    assert Settings.fetch() == {:error, :settings_not_initialized}

    assert Settings.save_retention(%{audit_data_seconds: 60 * @day}, 0, @actor) ==
             {:error, :settings_not_initialized}

    assert Repo.aggregate(Installation, :count) == 0
  end

  test "initialization saves one stable identity and typed defaults without enabling work" do
    assert {:ok, saved} = Settings.initialize(@actor)
    assert saved.installation.host_ref =~ "installation:"
    assert saved.installation.revision == 1
    assert saved.installation.applied_revision == 0
    assert saved.installation.saved_by == @actor
    assert saved.installation.saved_at != nil
    assert saved.retention.operational_data_seconds == 30 * @day
    assert saved.retention.closed_work_seconds == 30 * @day
    assert saved.retention.episode_history_seconds == 30 * @day
    assert saved.retention.audit_data_seconds == 30 * @day
    assert saved.retention.conversation_memory_seconds == 90 * @day
    assert Settings.application_status(saved) == :pending
    assert {:ok, ^saved} = Settings.fetch()
    assert {:ok, ^saved} = Settings.initialize(@actor)
    assert Repo.aggregate(Installation, :count) == 1
    assert Repo.aggregate(Edit, :count) == 1
  end

  test "only the authenticated local settings boundary may initialize or edit" do
    for actor <- [nil, "", "slack:user:U1", "local-operator", "migration:legacy-environment"] do
      assert Settings.initialize(actor) == {:error, :settings_forbidden}
      assert Settings.save_retention(%{}, 0, actor) == {:error, :settings_forbidden}
    end

    assert Repo.aggregate(Installation, :count) == 0
    assert Repo.aggregate(Edit, :count) == 0
  end

  test "a fresh install may write instructions before it creates its settings" do
    # Until the YAML importer was retired, product rows written before the
    # first save made a fresh database refuse to initialize and point the
    # operator at an import that had nothing to import. The instructions page
    # is reachable before setup, so this was a dead end one typed sentence away.
    assert {:ok, _} =
             Ryker.Instructions.save(:global, "Existing operator guidance", 0, @actor)

    assert {:ok, saved} = Settings.initialize(@actor)
    assert saved.installation.revision == 1
    assert Repo.aggregate(Installation, :count) == 1
    assert Ryker.Instructions.get(:global).text == "Existing operator guidance"
  end

  test "a normalized no-op does not buy a revision, audit or reconfiguration" do
    assert {:ok, current} = Settings.initialize(@actor)

    assert {:ok, saved} =
             Settings.save_retention(
               %{"audit_data_seconds" => Integer.to_string(30 * @day)},
               1,
               @actor
             )

    assert saved == current
    assert Repo.aggregate(Edit, :count) == 1
  end

  # A write inside another transaction announced its revision before that
  # transaction committed. The runtime owner reads the saved settings when it
  # hears a revision, so it read the previous one, found nothing to apply, and
  # the change waited for the next save or restart. A workspace-wide
  # participation change from Slack took exactly that path.
  test "a settings change is announced after it commits, not before" do
    assert {:ok, _} = Settings.initialize(@actor)
    :ok = Settings.subscribe()

    assert {:ok, revision} =
             Settings.atomically(fn ->
               assert {:ok, saved} =
                        Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)

               refute_received {:settings_saved, _revision}
               {:ok, saved.installation.revision}
             end)

    assert_received {:settings_saved, ^revision}
  end

  test "a failed change rolls every write in it back and announces nothing" do
    assert {:ok, _} = Settings.initialize(@actor)
    :ok = Settings.subscribe()

    assert {:error, :second_write_failed} =
             Settings.atomically(fn ->
               {:ok, _saved} =
                 Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)

               {:error, :second_write_failed}
             end)

    assert Settings.fetch!().installation.revision == 1
    assert Settings.fetch!().retention.audit_data_seconds == 30 * @day
    refute_received {:settings_saved, _revision}
  end

  test "a successful edit records provenance and survives a fresh database read" do
    assert {:ok, initial} = Settings.initialize(@actor)
    assert :ok = Settings.record_application(1, :ok)

    assert {:ok, saved} = Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)
    assert saved.installation.host_ref == initial.installation.host_ref
    assert saved.installation.revision == 2
    assert saved.installation.applied_revision == 1
    assert Settings.application_status(saved) == :pending
    assert saved.retention.audit_data_seconds == 60 * @day
    assert saved.retention.operational_data_seconds == 30 * @day
    assert {:ok, ^saved} = Settings.fetch()

    edit = Repo.one!(from(e in Edit, where: e.revision == 2))
    assert edit.domain == :retention
    assert edit.actor_ref == @actor
    assert edit.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a stale save returns the winner without changing its value or provenance" do
    assert {:ok, _} = Settings.initialize(@actor)
    assert {:ok, winner} = Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)

    assert Settings.save_retention(%{audit_data_seconds: 90 * @day}, 1, @actor) ==
             {:error, {:settings_conflict, winner}}

    # Even an identical stale body cannot acknowledge a revision the editor never saw.
    assert Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor) ==
             {:error, {:settings_conflict, winner}}

    assert Repo.aggregate(Edit, :count) == 2
  end

  test "unknown settings and unsafe retention combinations are rejected atomically" do
    assert {:ok, before} = Settings.initialize(@actor)

    invalid = [
      %{unexpected: true},
      %{operational_data_seconds: 0},
      %{audit_data_seconds: 29 * @day},
      %{closed_work_seconds: 31 * @day},
      %{conversation_memory_seconds: 10 * 365 * @day + 1}
    ]

    for attributes <- invalid do
      assert {:error, {:invalid_settings, _}} = Settings.save_retention(attributes, 1, @actor)
      assert {:ok, ^before} = Settings.fetch()
    end

    assert Repo.aggregate(Edit, :count) == 1
  end

  test "shortening retention requires confirmation of the exact proposed values and revision" do
    assert {:ok, _} = Settings.initialize(@actor)
    attributes = %{conversation_memory_seconds: 60 * @day}

    assert {:ok, preview} = Settings.preview_retention(attributes, 1)
    assert preview.shortened_fields == [:conversation_memory_seconds]
    assert preview.current_revision == 1

    assert Settings.save_retention(attributes, 1, @actor) ==
             {:error, :retention_impact_confirmation_required}

    assert Settings.save_retention(
             %{conversation_memory_seconds: 45 * @day},
             1,
             @actor,
             preview.confirmation
           ) ==
             {:error, :retention_impact_confirmation_required}

    assert {:ok, saved} = Settings.save_retention(attributes, 1, @actor, preview.confirmation)
    assert saved.retention.conversation_memory_seconds == 60 * @day
    assert saved.installation.revision == 2
    assert Repo.aggregate(Edit, :count) == 2
  end

  # The question before a shorter limit counted every row older than the new
  # limit, the ones the current limit had already let go included, and named
  # the wrong data: "closed work sessions" for incident rooms and task cards,
  # and three of the audit trail's ten ledgers, without the finished requests
  # it deletes (2026-10-04 review).
  test "a shorter limit counts what it newly lets go, named as what is deleted" do
    assert {:ok, _snapshot} = Settings.initialize(@actor)

    longer = %{
      closed_work_seconds: 60 * @day,
      episode_history_seconds: 60 * @day,
      audit_data_seconds: 90 * @day
    }

    assert {:ok, _snapshot} = Settings.save_retention(longer, 1, @actor)

    for days <- [100, 75] do
      Repo.insert!(%Edit{
        id: Ecto.UUID.generate(),
        domain: :retention,
        revision: 1_000 + days,
        actor_ref: @actor,
        fingerprint: String.duplicate("a", 64),
        inserted_at: DateTime.add(DateTime.utc_now(), -days * @day, :second)
      })
    end

    finished_request!(75)
    finished_request!(100)

    shorter = %{closed_work_seconds: 45 * @day, audit_data_seconds: 60 * @day}
    assert {:ok, preview} = Settings.preview_retention(shorter, 2)

    assert Enum.map(preview.impact.closed_work_seconds, & &1.label) == [
             "closed incident rooms",
             "task cards"
           ]

    audit = Map.new(preview.impact.audit_data_seconds, &{&1.label, &1.count})

    assert audit == %{
             "finished requests" => 1,
             "settings and credential changes" => 1,
             "Slack button presses" => 0,
             "channel joins and leaves" => 0,
             "operator actions" => 0,
             "settled memory reviews" => 0
           }
  end

  test "a late apply result cannot mark a newer save applied or overwrite its failure" do
    assert {:ok, _} = Settings.initialize(@actor)
    assert :ok = Settings.record_application(1, :ok)
    assert {:ok, saved} = Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)
    assert Settings.application_status(saved) == :pending

    assert Settings.record_application(1, :ok) == {:error, :settings_revision_changed}

    assert Settings.record_application(1, {:error, :runtime_start_failed}) ==
             {:error, :settings_revision_changed}

    assert :ok = Settings.record_application(2, {:error, :runtime_start_failed})
    assert {:ok, failed} = Settings.fetch()
    assert Settings.application_status(failed) == {:failed, :runtime_start_failed}
    assert failed.installation.applied_revision == 1

    assert :ok = Settings.record_application(2, :ok)
    assert {:ok, applied} = Settings.fetch()
    assert Settings.application_status(applied) == :applied
    assert applied.installation.applied_revision == 2
    assert applied.installation.failure_code == nil
    assert Repo.aggregate(Edit, :count) == 2
  end

  test "apply failures cannot retain arbitrary provider text or secrets" do
    assert {:ok, _} = Settings.initialize(@actor)

    assert Settings.record_application(1, {:error, "secret-bearing provider text"}) ==
             {:error, :invalid_settings_application_result}

    assert {:ok, current} = Settings.fetch()
    assert Settings.application_status(current) == :pending
  end

  test "an unavailable settings table raises instead of returning fresh defaults" do
    # The test transaction restores this new table. Do not stop the shared Repo
    # to simulate a connection failure and invalidate unrelated test ownership.
    Repo.query!("ALTER TABLE installation_settings RENAME TO unavailable_installation_settings")
    assert_raise Postgrex.Error, fn -> Settings.fetch() end
  end

  test "settings survive audit expiry without resetting revision or pending application" do
    assert {:ok, _} = Settings.initialize(@actor)
    assert {:ok, saved} = Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)
    Repo.update_all(Edit, set: [inserted_at: DateTime.add(DateTime.utc_now(), -61 * @day)])

    assert {:ok, result} =
             RetentionData.prune(
               Map.from_struct(saved.retention)
               |> Map.delete(:__meta__)
               |> Map.delete(:id)
             )

    assert result.audit_rows == 2
    assert Repo.aggregate(Edit, :count) == 0
    assert {:ok, ^saved} = Settings.fetch()
    assert Repo.aggregate(Retention, :count) == 1
  end

  # A request whose history retention already deleted, last changed `days` ago.
  defp finished_request!(days) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Ryker.Episodes.apply(
               Ryker.Fixtures.Episodes.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "settings-preview:#{episode_id}",
                 native_input_id: "source:settings-preview:#{episode_id}"
               })
             )

    Repo.query!(
      """
      UPDATE episode_kernel_episodes
      SET history_pruned_at = clock_timestamp(),
          updated_at = clock_timestamp() - ($1 * interval '1 day')
      WHERE id = $2
      """,
      [days, Ecto.UUID.dump!(episode_id)]
    )
  end
end
