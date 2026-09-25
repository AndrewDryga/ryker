defmodule Ryker.ControlPlane.ConfigurationPageTest do
  @moduledoc """
  The read-only running system at the bottom of the Advanced settings page:
  whether code-changing work can run, then one folded disclosure with the
  loaded settings grouped by the part of Ryker they belong to, each with what
  it is for, and the tool-grant inventory. It never renders a control, and it
  never claims that configured means healthy.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{RunningSystem, SettingsPage}

  @source "durable settings"

  test "the loaded settings are one folded disclosure, grouped by subsystem, each with its purpose" do
    # Before 2026-09-24 the evidence was an open wall of 20px values and
    # explanations beside every key; the keys and raw values matter only for
    # support, so they sit under each setting's own Details.
    document =
      render([
        row("admission", "enabled"),
        row("slack", "disabled"),
        row("runtime.mode", "product"),
        row("admission.policy", "ryker-admission-v1"),
        row("work.concurrency", "4"),
        row("retention.audit_data_seconds", "2592000"),
        %{key: "future.option", value: "42", source: "/etc/override.yaml"}
      ])

    evidence = LazyHTML.query(document, "section.configuration-evidence")
    assert LazyHTML.query(evidence, ".section-head h2") |> LazyHTML.text() == "Running system"

    details = LazyHTML.query(evidence, "details.system-evidence")
    assert Enum.count(details) == 1
    assert LazyHTML.attribute(details, "open") == []

    assert LazyHTML.query(details, ".configuration-group > h3") |> Enum.map(&LazyHTML.text/1) ==
             [
               "Subsystems",
               "Runtime",
               "Admission",
               "Work execution",
               "Cleanup and retention",
               "Other settings"
             ]

    values = LazyHTML.query(details, ".configuration-values")
    note = values |> LazyHTML.query("p.settings-lede") |> LazyHTML.text()
    assert note =~ "read-only evidence"
    assert note =~ "without a deployment"
    assert note =~ "Configured means a setting was saved"
    assert LazyHTML.query(values, "p.settings-lede code") |> LazyHTML.text() == @source

    admission = LazyHTML.query(values, ".configuration-group[data-group='admission']")

    assert LazyHTML.query(admission, "[data-setting='admission.policy'] .entity-name")
           |> LazyHTML.text() == "Admission execution policy"

    subsystems = LazyHTML.query(values, ".configuration-group[data-group='subsystems']")

    assert LazyHTML.query(subsystems, ".configuration-setting")
           |> LazyHTML.attribute("data-setting") == ["admission", "slack"]

    assert LazyHTML.query(subsystems, ".configuration-value")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) == ["Configured", "Not configured"]

    # The key and the raw value are support details, folded under the setting.
    assert LazyHTML.query(admission, ".entity-body > details.settings-row-details dd code")
           |> Enum.map(&LazyHTML.text/1) == ["admission.policy", "ryker-admission-v1"]

    other = LazyHTML.query(values, ".configuration-group[data-group='other']")
    assert LazyHTML.text(other) =~ "Explanation unavailable"

    assert LazyHTML.query(other, ".configuration-provenance code") |> LazyHTML.text() ==
             "/etc/override.yaml"

    assert Enum.empty?(LazyHTML.query(admission, ".configuration-provenance"))
  end

  test "the running system never renders an editable control" do
    # It is evidence of what the running process assembled. Product settings
    # are changed on the settings pages above it; the deployment environment
    # where Ryker is installed. A form here would be a fake.
    document = render([row("admission", "enabled"), row("work.concurrency", "4")])

    assert Enum.empty?(
             LazyHTML.query(document, "form, input, button, select, textarea, [phx-click]")
           )

    assert LazyHTML.text(document) =~
             "Docker Compose installations should provide work execution automatically"
  end

  test "code changes that cannot run are shown outside the folded evidence, where recovery links" do
    # The Work recovery card links to /settings/advanced#code-editing. The
    # problem it points at needs a person, so it is never folded away.
    document = render([])
    section = LazyHTML.query(document, "section#code-editing")
    assert Enum.count(section) == 1
    assert Enum.empty?(LazyHTML.query(document, "details.system-evidence #code-editing"))

    assert LazyHTML.query(section, ".state-word[data-tone=bad]") |> LazyHTML.text() ==
             "Code changes are unavailable"
  end

  test "tool grants are an inventory with their source, distinct from health and permission" do
    document =
      RunningSystem.html(%{
        rows: [],
        grants: [
          %{kind: "MCP tool", name: "search_slack", source: "/etc/ryker.yaml"},
          %{kind: "Capability", name: "responder-state", source: @source}
        ],
        source: @source
      })
      |> LazyHTML.from_fragment()

    grants = LazyHTML.query(document, ".configuration-grants")
    assert LazyHTML.text(grants) =~ "not a live tool-health check"
    assert LazyHTML.text(grants) =~ "does not grant permission"

    assert LazyHTML.query(grants, ".entity-row .entity-name")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) == ["search_slack", "responder-state"]

    assert LazyHTML.query(grants, ".entity-row .entity-meta")
           |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" "))) ==
             ["MCP tool · From /etc/ryker.yaml", "Capability · From #{@source}"]

    none =
      RunningSystem.html(%{rows: [], grants: [], source: @source})
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(none, ".configuration-grants .entity-empty") |> LazyHTML.text() =~
             "No MCP or tool grants are configured"

    assert LazyHTML.query(none, ".configuration-values .entity-empty") |> LazyHTML.text() =~
             "No effective settings were published"
  end

  test "the running system renders under the Advanced page's own title and no other" do
    # The settings pages are native: the shell renders SettingsPage's header,
    # and this evidence carries section titles only.
    assert SettingsPage.title(:system) == "Advanced"
    document = render([row("admission", "enabled")])
    assert Enum.count(LazyHTML.query(document, "section.configuration-evidence")) == 1

    assert LazyHTML.query(document, ".section-head h2") |> Enum.map(&LazyHTML.text/1) ==
             ["Work execution", "Running system"]

    assert Enum.empty?(LazyHTML.query(document, "h1"))
  end

  defp row(key, value), do: %{key: key, value: value, source: @source}

  defp render(rows) do
    RunningSystem.html(%{rows: rows, grants: [], source: @source})
    |> LazyHTML.from_fragment()
  end
end
