defmodule Responder.Operator.ImportConfigurationTest do
  # The operator command that runs once, against the real production document,
  # with the writer stopped. Its refusals are the only thing standing between a
  # rerun and an operator's settings, so every one of them is pinned here.
  use Responder.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Responder.ImportConfiguration
  alias Responder.Settings

  @actor Responder.Settings.actor()
  @source Path.expand(
            "../../../testdata/configuration/retired-elixir-configuration.yaml",
            __DIR__
          )

  setup do
    # The deployment environment the release has when the importer runs; the
    # importer reads the registered credential names from it and nothing else.
    put_variable("DATABASE_URL", "ecto://responder:import-test@127.0.0.1/responder_import_test")
    put_variable("RESPONDER_WEBHOOK_SECRET_NAMES", "GENERIC_WEBHOOK_SECRET")

    # A database that already ran the product: the importer is the only path
    # that may create the installation under retained history.
    {:ok, _instructions} =
      Responder.Instructions.save(:global, "Existing operator guidance", 0, @actor)

    :ok
  end

  test "a configuration import takes exactly one document path" do
    # An importer that guessed at its argument would run the wrong document
    # against a production database with the writer stopped.
    for arguments <- [
          [],
          [@source, @source],
          ["--apply"],
          ["--config", @source],
          [@source, "--apply", "--apply"]
        ] do
      assert_raise Mix.Error, ~r/invalid_arguments/, fn -> ImportConfiguration.run(arguments) end
    end

    assert Settings.fetch() == {:error, :settings_not_initialized}
  end

  test "a dry run prints the plan an operator reads and writes nothing" do
    plan = run!([@source])

    assert plan["status"] == "ready"
    assert plan["host_ref"] == "example-local-manual"
    assert plan["receipt"] == nil

    # The sections the runbook tells the operator to read before applying.
    assert Enum.any?(plan["settings"], &(&1["setting"] == "slack.identity.workspace_ref"))
    assert Enum.any?(plan["retired"], &(&1["setting"] == "mode"))
    assert Enum.any?(plan["secret_remap"], &(&1["from"] == "EMISAR_API_KEY"))
    assert Enum.any?(plan["replaced_tuning"], &(&1["setting"] == "work.concurrency"))
    assert plan["changed_effects"] != []
    assert plan["deployment"] != []
    assert plan["writes"] != []
    assert plan["participation"]["installation_default"] == "mentions"
    assert plan["source"]["fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
    assert plan["plan_fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Settings.fetch() == {:error, :settings_not_initialized}
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 0
    assert Repo.aggregate(Settings.Edit, :count) == 0
  end

  test "a refused document is reported by path and never prints the value it refused" do
    path = variant!([{"  maximum_open_incidents: 10", "  maximum_open_incidents: 100000"}])

    error = assert_raise(Mix.Error, fn -> ImportConfiguration.run([path]) end)
    message = error.message

    assert message =~ "slack.maximum_open_incidents"
    assert message =~ "must_be_an_integer_in_range"
    refute message =~ "100000"
    assert Settings.fetch() == {:error, :settings_not_initialized}
  end

  test "--apply writes the import once and reports the revision it produced" do
    outcome = run!([@source, "--apply"])

    assert outcome["status"] == "applied"
    assert is_integer(outcome["revision"])
    assert outcome["receipt_id"] =~ ~r/\A[0-9a-f-]{36}\z/
    assert outcome["plan"]["status"] == "ready"

    assert {:ok, saved} = Settings.fetch()
    assert saved.installation.host_ref == "example-local-manual"
    assert saved.installation.revision == outcome["revision"]
    assert saved.slack.channel_prefix == "ems"
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 1
  end

  test "a rerun of the same document reports already applied rather than a second revision" do
    applied = run!([@source, "--apply"])
    rerun = run!([@source, "--apply"])

    assert rerun["status"] == "already_applied"
    assert rerun["revision"] == applied["revision"]
    assert rerun["plan"]["status"] == "already_applied"

    assert Repo.aggregate(Settings.ImportReceipt, :count) == 1
    assert Settings.fetch!().installation.revision == applied["revision"]
  end

  test "a changed document refuses rather than overwriting the settings it imported" do
    applied = run!([@source, "--apply"])
    changed = variant!([{"  channel_prefix: ems", "  channel_prefix: inc"}])

    assert_raise Mix.Error, ~r/import_conflict, :source_changed/, fn ->
      ImportConfiguration.run([changed, "--apply"])
    end

    assert Settings.fetch!().slack.channel_prefix == "ems"
    assert Settings.fetch!().installation.revision == applied["revision"]
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 1
  end

  test "settings edited after the import refuse a rerun rather than reverting the edit" do
    applied = run!([@source, "--apply"])

    {:ok, edited} = Settings.save_slack(%{channel_prefix: "inc"}, applied["revision"], @actor)

    assert_raise Mix.Error, ~r/import_conflict, :target_edited/, fn ->
      ImportConfiguration.run([@source, "--apply"])
    end

    assert Settings.fetch!().slack.channel_prefix == "inc"
    assert Settings.fetch!().installation.revision == edited.installation.revision
  end

  test "a document that is not on disk is reported instead of assumed empty" do
    missing = Path.join(System.tmp_dir!(), "responder-import-absent-#{System.unique_integer()}")

    assert_raise Mix.Error, ~r/configuration import failed/, fn ->
      ImportConfiguration.run([missing])
    end

    assert Settings.fetch() == {:error, :settings_not_initialized}
  end

  defp run!(arguments) do
    arguments |> capture_run() |> Jason.decode!()
  end

  defp capture_run(arguments), do: capture_io(fn -> ImportConfiguration.run(arguments) end)

  defp variant!(replacements) do
    document =
      Enum.reduce(replacements, File.read!(@source), fn {from, to}, document ->
        assert String.contains?(document, from), "fixture no longer contains #{inspect(from)}"
        String.replace(document, from, to)
      end)

    path =
      Path.join(
        System.tmp_dir!(),
        "responder-import-task-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, document)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
