defmodule Ryker.SettingsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query
  alias Ryker.Retention.Data, as: RetentionData
  alias Ryker.Settings
  alias Ryker.Settings.{Edit, Installation, Retention}

  @actor "control-plane:local"
  @day 86_400

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
    for actor <- [nil, "", "slack:user:U1", "local-operator"] do
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

  test "a late apply result cannot mark a newer save applied or overwrite its failure" do
    assert {:ok, _} = Settings.initialize(@actor)
    assert :ok = Settings.record_application(1, :ok)
    assert {:ok, saved} = Settings.save_retention(%{audit_data_seconds: 60 * @day}, 1, @actor)
    assert Settings.application_status(saved) == :pending

    assert Settings.record_application(1, :ok) == {:error, :settings_revision_changed}

    assert Settings.record_application(1, {:error, :missing_credentials}) ==
             {:error, :settings_revision_changed}

    assert :ok = Settings.record_application(2, {:error, :missing_credentials})
    assert {:ok, failed} = Settings.fetch()
    assert Settings.application_status(failed) == {:failed, :missing_credentials}
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
end
