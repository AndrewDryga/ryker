defmodule Responder.ControlPlane.ConfigurationHelpTest do
  use ExUnit.Case, async: false

  alias Responder.ControlPlane.ConfigurationHelp
  alias Responder.ControlPlane.HTML
  alias Responder.ControlPlane.OperatorProjection

  @settings ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks runtime.mode admission.policy admission.decision_timeout_ms work.concurrency work.poll_interval_ms retention.operational_data_seconds retention.closed_work_seconds retention.episode_history_seconds retention.audit_data_seconds)

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
    assert page =~ "does not make the model think faster"
    assert page =~ "Required when retention is configured; there is no implicit default"
    assert page =~ "restart"
    refute page =~ "<form"
  end

  test "policy help explains immutable pins instead of treating policy names as model names" do
    page = html([row("admission.policy", "responder-admission-v1")])
    assert page =~ "Coop execution policy"
    assert page =~ "policy digest"
    assert page =~ "not a model name"
    assert page =~ "admission.policy.name"
    assert page =~ "responder-admission-v1"
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
      admission: %{policy: "responder-admission-v1", decision_timeout_ms: 30_000},
      work: %{concurrency: 4, poll_interval_ms: 250},
      retention: %{
        operational_data_seconds: 86_400,
        closed_work_seconds: 604_800,
        episode_history_seconds: 2_592_000,
        audit_data_seconds: 2_592_000
      }
    }

    previous =
      Map.new(configured, fn {key, _} -> {key, Application.fetch_env(:responder, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:responder, key, value)
        {key, :error} -> Application.delete_env(:responder, key)
      end)
    end)

    Enum.each(configured, fn {key, value} -> Application.put_env(:responder, key, value) end)
    snapshot = OperatorProjection.operator_configuration()
    assert Enum.sort(Enum.map(snapshot.rows, & &1.key)) == Enum.sort(@settings)
    assert Enum.all?(snapshot.rows, &ConfigurationHelp.setting(&1.key).documented)
  end

  defp row(key, value), do: %{key: key, value: value, source: "/etc/responder.yaml"}

  defp html(rows),
    do:
      HTML.configuration(%{rows: rows, grants: [], source: "/etc/responder.yaml"})
      |> IO.iodata_to_binary()
end
