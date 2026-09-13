defmodule Ryker.ControlPlane.ConfigurationHelpTest do
  use ExUnit.Case, async: false

  alias Ryker.ControlPlane.CodeEditingSetup
  alias Ryker.ControlPlane.ConfigurationHelp
  alias Ryker.ControlPlane.ConfigurationProjection
  alias Ryker.ControlPlane.HTML

  @settings ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks runtime.mode admission.policy admission.decision_timeout_ms work.concurrency work.poll_interval_ms retention.operational_data_seconds retention.closed_work_seconds retention.episode_history_seconds retention.audit_data_seconds retention.disposable_bytes_limit retention.reclaim_target_seconds retention.storage_high_watermark_bytes retention.storage_low_watermark_bytes retention.storage_reserve_bytes)

  test "code editing help explains the required setup without changing it" do
    page = html([])
    document = LazyHTML.from_document(page)
    section = LazyHTML.query(document, "#code-editing") |> LazyHTML.text()
    assert section =~ "Set up code editing"
    assert section =~ "recoverable copy"
    assert section =~ "Work placement"
    assert section =~ "Execution policies"
    assert section =~ "fleet"
    assert section =~ "Docker"
    assert section =~ "does not enroll"
    commands = LazyHTML.query(document, "#code-editing details") |> LazyHTML.text()
    assert commands =~ "Administrator commands and configuration"
    assert commands =~ "coop sessions doctor"
    assert commands =~ "MIX_ENV=prod mix ryker.doctor"
    assert commands =~ "applied revision beside the saved one"
    refute commands =~ "ryker.doctor --config"
    assert commands =~ "0600"
    refute page =~ "<form"
  end

  test "setup support reflects the running adapter rather than an edited YAML file" do
    previous = Application.fetch_env(:ryker, :work)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ryker, :work, value)
        :error -> Application.delete_env(:ryker, :work)
      end
    end)

    for config <- [nil, %{}, %{api: Ryker.Coop.Client}] do
      Application.put_env(:ryker, :work, config)
      refute CodeEditingSetup.checkpoint_supported?()
      assert html([]) =~ "does not support saving coding work"
    end

    Application.put_env(:ryker, :work, api: Ryker.CoopFleet.Client)
    assert CodeEditingSetup.checkpoint_supported?()
    assert html([]) =~ "does not prove that a compatible coding worker is online"
  end

  test "each effective setting explains its purpose, behavior and default beside its value" do
    # The old key/value table left operators guessing what a policy or timeout did.
    rows = Enum.map(@settings, &row(&1, "configured"))
    document = html(rows) |> LazyHTML.from_document()

    for key <- @settings do
      setting = LazyHTML.query(document, "[data-setting='#{key}']")
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-purpose")) != "", key
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-behavior")) != "", key
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-default")) != "", key
      refute LazyHTML.text(setting) =~ "Explanation unavailable"
    end
  end

  test "timing help distinguishes faster polling from faster inference and retention from defaults" do
    page =
      html([
        row("admission.decision_timeout_ms", "30000"),
        row("work.poll_interval_ms", "250"),
        row("retention.operational_data_seconds", "86400")
      ])

    assert page =~ "30 seconds"
    assert page =~ "250 milliseconds"
    assert page =~ "1 day"

    assert ConfigurationHelp.value("retention.disposable_bytes_limit", "10737418240") ==
             "10.00 GiB"

    assert ConfigurationHelp.value("retention.reclaim_target_seconds", "3600") == "1 hour"
    assert page =~ "does not make the model think faster"
    assert page =~ "Required when retention is configured; there is no implicit default"
    # The evidence section must not send an operator back to a file or a
    # restart: these values are assembled from settings that apply live.
    assert page =~ "read-only evidence"
    assert page =~ "without a deployment"
    refute page =~ "restart"
    refute page =~ "<form"
  end

  test "readiness availability is not described as GitHub publication authority" do
    page = html([row("publication", "enabled")])
    assert page =~ "Readiness reviews run whenever a delivery adapter is configured"
    assert page =~ "Publishing requires GitHub and an explicitly configured repository binding"
    refute page =~ "Not configured unless publication is present"
  end

  test "policy help explains immutable pins instead of treating policy names as model names" do
    page = html([row("admission.policy", "ryker-admission-v1")])
    assert page =~ "Coop execution policy"
    assert page =~ "policy digest"
    assert page =~ "not a model name"
    assert page =~ "admission.policy.name"
    assert page =~ "ryker-admission-v1"
  end

  test "policy names are never mistaken for component presence flags" do
    for name <- ["enabled", "disabled"] do
      document = html([row("admission.policy", name)]) |> LazyHTML.from_document()
      assert LazyHTML.text(LazyHTML.query(document, ".configuration-value")) == name
      assert ConfigurationHelp.value("future.option", name) == name
    end

    assert ConfigurationHelp.value("admission", "enabled") == "Configured"
    assert ConfigurationHelp.value("admission", "disabled") == "Not configured"
  end

  test "unknown settings and grant names remain escaped without invented explanations" do
    page =
      HTML.configuration(%{
        source: "<source>",
        rows: [row("future.<option>", "<script>alert(1)</script>")],
        grants: [%{kind: "MCP tool", name: "<tool>", source: "<source>"}]
      })
      |> IO.iodata_to_binary()

    assert page =~ "Explanation unavailable"
    assert page =~ "&lt;option&gt;"
    assert page =~ "&lt;script&gt;"
    assert page =~ "&lt;tool&gt;"
    assert page =~ "does not grant permission"
    refute page =~ "<script>"
    refute page =~ "<source>"
    refute page =~ "<tool>"
  end

  test "the current configuration projection cannot silently outgrow its explanations" do
    configured = %{
      runtime_mode: :product,
      admission: %{policy: "ryker-admission-v1", decision_timeout_ms: 30_000},
      work: %{concurrency: 4, poll_interval_ms: 250},
      retention: %{
        operational_data_seconds: 86_400,
        closed_work_seconds: 604_800,
        episode_history_seconds: 2_592_000,
        audit_data_seconds: 2_592_000,
        disposable_bytes_limit: 10_737_418_240,
        reclaim_target_seconds: 3_600,
        storage_high_watermark_bytes: 64_424_509_440,
        storage_low_watermark_bytes: 48_318_382_080,
        storage_reserve_bytes: 5_368_709_120
      }
    }

    previous =
      Map.new(configured, fn {key, _} -> {key, Application.fetch_env(:ryker, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ryker, key, value)
        {key, :error} -> Application.delete_env(:ryker, key)
      end)
    end)

    Enum.each(configured, fn {key, value} -> Application.put_env(:ryker, key, value) end)
    snapshot = ConfigurationProjection.fetch()
    assert Enum.sort(Enum.map(snapshot.rows, & &1.key)) == Enum.sort(@settings)
    assert Enum.all?(snapshot.rows, &ConfigurationHelp.setting(&1.key).documented)
  end

  defp row(key, value), do: %{key: key, value: value, source: "/etc/ryker.yaml"}

  defp html(rows),
    do:
      HTML.configuration(%{rows: rows, grants: [], source: "/etc/ryker.yaml"})
      |> IO.iodata_to_binary()
end
