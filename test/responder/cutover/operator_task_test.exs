defmodule Responder.Cutover.OperatorTaskTest do
  use Responder.DataCase, async: false

  alias Mix.Tasks.Responder.Cutover
  alias Responder.CanonicalJSON
  alias Responder.Cutover.{LegacySchema, Run}
  alias Responder.Repo

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Shell.Process.flush()

    root =
      Path.join(
        System.tmp_dir!(),
        "responder-cutover-operator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      Mix.Shell.Process.flush()
      Mix.shell(previous_shell)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "one operator command prepares applies and rolls back the reviewed empty inventory", %{
    root: root
  } do
    {manifest_path, review_path} = write_reviewed_inventory!(root)
    configuration_path = write_configuration!(root)

    Cutover.run(["prepare", manifest_path, review_path])

    assert %{
             "operation" => "prepared",
             "run_id" => run_id,
             "status" => "prepared"
           } = receive_json!()

    assert Repo.get!(Run, run_id).status == :prepared

    Cutover.run(["apply", run_id, configuration_path])

    assert %{
             "operation" => "applied",
             "run_id" => ^run_id,
             "status" => "applied"
           } = receive_json!()

    assert Repo.get!(Run, run_id).status == :applied

    Cutover.run(["rollback", run_id, "operator:andrew"])

    assert %{
             "operation" => "rolled_back",
             "run_id" => ^run_id,
             "status" => "rolled_back"
           } = receive_json!()

    assert %Run{status: :rolled_back, rolled_back_by: "operator:andrew"} =
             Repo.get!(Run, run_id)
  end

  test "the operator can prepare a sealed schedule inventory in a fresh task process", %{
    root: root
  } do
    # A production Blitz rehearsal reached this path before any Ecto schema had
    # loaded the schedule atom. The manifest is trusted data, but parsing it
    # must not depend on incidental module-load order.
    {manifest_path, review_path} = write_schedule_inventory!(root)

    Cutover.run(["prepare", manifest_path, review_path])

    assert %{
             "operation" => "prepared",
             "run_id" => run_id,
             "status" => "prepared"
           } = receive_json!()

    assert Repo.get!(Run, run_id).item_count == 1
  end

  test "manifest kind parsing is independent of incidental module load order" do
    # Run only the compiled modules needed to validate the artifact. Naming a
    # local variable `schedule` in this child script would itself intern that
    # atom and mask the production failure, so the two items stay deliberately
    # generic here.
    script = """
    data = %{"id" => "legacy-daily-briefing"}
    first = %{
      "data" => data,
      "decision" => "import",
      "id" => "schedule:legacy-daily-briefing",
      "kind" => "schedule",
      "source" => %{
        "ref" => "legacy-daily-briefing",
        "sha256" => Responder.CanonicalJSON.digest(data),
        "table" => "scheduled_tasks"
      }
    }
    wait_data = %{"episode_id" => "missing"}
    second = %{
      "data" => wait_data,
      "decision" => "import",
      "id" => "wait:missing-parent",
      "kind" => "wait",
      "source" => %{
        "ref" => "missing-parent",
        "sha256" => Responder.CanonicalJSON.digest(wait_data),
        "table" => "episode_wakeups"
      }
    }
    manifest = %{
      "cutover_at" => "2026-08-30T12:00:00.000000Z",
      "items" => [first, second],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => Responder.Cutover.LegacySchema.sha256(),
        "schema_version" => Responder.Cutover.LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{"schedule" => 1, "wait" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }
    envelope = %{"manifest" => manifest, "sha256" => Responder.CanonicalJSON.digest(manifest)}
    review = %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }
    IO.inspect(Responder.Cutover.Ledger.prepare(envelope, review))
    """

    code_paths =
      [:responder, :jason, :ecto, :ecto_sql, :db_connection, :decimal]
      |> Enum.flat_map(fn application ->
        ebin = application |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")
        ["-pa", ebin]
      end)

    {output, status} =
      System.cmd(System.find_executable("elixir"), code_paths ++ ["-e", script],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert output =~
             ~s({:error, {:cutover_wait_episode_not_imported, "wait:missing-parent"}})
  end

  test "operator invocation fails before mutating state when artifacts or arguments are invalid",
       %{
         root: root
       } do
    assert_raise Mix.Error, ~r/usage: mix responder.cutover/, fn -> Cutover.run([]) end

    assert_raise Mix.Error, ~r/cutover inventory failed.*timestamp_must_be_utc/, fn ->
      Cutover.run([
        "inventory",
        Path.join(root, "source.sqlite"),
        Path.join(root, "manifest.json"),
        "slack:T123",
        "2026-08-30T12:00:00+01:00"
      ])
    end

    assert_raise Mix.Error, ~r/cutover prepare failed.*artifact_file_invalid/, fn ->
      Cutover.run(["prepare", "relative-manifest.json", "relative-review.json"])
    end

    assert_raise Mix.Error, ~r/cutover rolled_back failed.*cutover_run_not_found/, fn ->
      Cutover.run(["rollback", Ecto.UUID.generate(), "operator:andrew"])
    end

    assert Repo.aggregate(Run, :count) == 0
  end

  defp write_reviewed_inventory!(root) do
    manifest = %{
      "cutover_at" => "2026-08-30T12:00:00.000000Z",
      "items" => [],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    envelope = %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}

    review = %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }

    manifest_path = Path.join(root, "manifest.json")
    review_path = Path.join(root, "review.json")
    File.write!(manifest_path, Jason.encode!(envelope))
    File.write!(review_path, Jason.encode!(review))
    {manifest_path, review_path}
  end

  defp write_schedule_inventory!(root) do
    data = %{"id" => "legacy-daily-briefing"}

    item = %{
      "data" => data,
      "decision" => "import",
      "id" => "schedule:legacy-daily-briefing",
      "kind" => "schedule",
      "source" => %{
        "ref" => "legacy-daily-briefing",
        "sha256" => CanonicalJSON.digest(data),
        "table" => "scheduled_tasks"
      }
    }

    manifest = %{
      "cutover_at" => "2026-08-30T12:00:00.000000Z",
      "items" => [item],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("b", 64)
      },
      "summary" => %{"schedule" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    envelope = %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}

    review = %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }

    manifest_path = Path.join(root, "schedule-manifest.json")
    review_path = Path.join(root, "schedule-review.json")
    File.write!(manifest_path, Jason.encode!(envelope))
    File.write!(review_path, Jason.encode!(review))
    {manifest_path, review_path}
  end

  defp write_configuration!(root) do
    path = Path.join(root, "responder.yaml")

    File.write!(path, """
    version: 1
    mode: component
    host_ref: responder-cutover
    coop:
      socket: /tmp/coop.sock
    repositories: {}
    admission:
      policy:
        name: admission-read
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    work: {}
    """)

    path
  end

  defp receive_json! do
    receive do
      {:mix_shell, :info, [document]} -> Jason.decode!(document)
    after
      100 -> flunk("expected cutover operator output")
    end
  end
end
