defmodule Responder.ControlPlane.ConfigurationPageTest do
  @moduledoc """
  The read-only effective configuration inside the Settings page: one
  heading for the evidence, grouped setting/value rows with their explanations
  beside them, the code-editing setup guide, and the tool-grant inventory —
  never an editable control, and never a claim that configured means healthy.
  """
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{HTML, Router}

  @source "durable settings"

  test "the effective configuration is one heading, grouped rows, the setup guide and the grant inventory in that order" do
    # Before 2026-09-13 the evidence opened with an "Effective host
    # configuration" h2 and intro of its own while the Settings page had just
    # rendered the same h2 and a second intro above it; the rows were one flat
    # list of fourteen presence flags and fourteen values, and the grants and
    # setup guide were bordered panels with 22px headings.
    document =
      render([
        row("admission", "enabled"),
        row("slack", "disabled"),
        row("runtime.mode", "product"),
        row("admission.policy", "responder-admission-v1"),
        row("work.concurrency", "4"),
        row("retention.audit_data_seconds", "2592000"),
        %{key: "future.option", value: "42", source: "/etc/override.yaml"}
      ])

    assert outline(document, "div.configuration-evidence > *") == [
             "section.configuration-values",
             "section.code-editing-setup",
             "section.configuration-grants",
             "p.muted"
           ]

    assert LazyHTML.query(document, "h2") |> LazyHTML.text() ==
             "Effective host configurationSet up code editingMCP and tool grants"

    assert Enum.empty?(LazyHTML.query(document, "h1, .configuration-guide, .table-wrap"))

    values = LazyHTML.query(document, "section.configuration-values")

    assert LazyHTML.query(document, "section.configuration-values > p.section-description code")
           |> LazyHTML.text() == @source

    note = LazyHTML.query(values, ".configuration-change-note")
    assert LazyHTML.text(note) =~ "read-only evidence"
    assert LazyHTML.text(note) =~ "without a deployment"
    assert LazyHTML.text(note) =~ "Configured means this installation saved a setting"

    assert LazyHTML.query(values, "h3") |> LazyHTML.text() ==
             "SubsystemsRuntimeAdmissionWork executionCleanup and retentionOther settings"

    admission = LazyHTML.query(values, ".configuration-group[data-group='admission']")

    assert LazyHTML.query(admission, ".configuration-setting[data-setting='admission.policy'] h4")
           |> LazyHTML.text() == "Admission execution policy"

    subsystems = LazyHTML.query(values, ".configuration-group[data-group='subsystems']")

    assert LazyHTML.query(subsystems, ".configuration-setting")
           |> LazyHTML.attribute("data-setting") ==
             ["admission", "slack"]

    assert LazyHTML.query(subsystems, ".configuration-value") |> LazyHTML.text() ==
             "ConfiguredNot configured"

    other = LazyHTML.query(values, ".configuration-group[data-group='other']")
    assert LazyHTML.text(other) =~ "Explanation unavailable"

    assert LazyHTML.query(other, ".configuration-provenance code") |> LazyHTML.text() ==
             "/etc/override.yaml"

    assert Enum.empty?(LazyHTML.query(admission, ".configuration-provenance"))
  end

  test "the effective configuration never renders an editable control" do
    # It is evidence of what the running process assembled. Product settings
    # are edited in the live sections above it; the deployment environment in
    # the unit file. A form here would be a fake.
    document = render([row("admission", "enabled"), row("work.concurrency", "4")])

    assert Enum.empty?(
             LazyHTML.query(document, "form, input, button, select, textarea, [phx-click]")
           )

    assert LazyHTML.text(document) =~ "does not enroll workers, change permissions or retry tasks"
  end

  test "tool grants are an inventory with their source, distinct from health and permission" do
    document =
      HTML.configuration(%{
        rows: [],
        grants: [
          %{kind: "MCP tool", name: "search_slack", source: "/etc/responder.yaml"},
          %{kind: "Capability", name: "responder-state", source: @source}
        ],
        source: @source
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    grants = LazyHTML.query(document, "section.configuration-grants")
    assert LazyHTML.text(grants) =~ "not a live tool-health check"
    assert LazyHTML.text(grants) =~ "does not grant permission"

    assert LazyHTML.query(grants, "table.data-table td[data-label='Capability or tool'] code")
           |> LazyHTML.text() == "search_slackresponder-state"

    assert LazyHTML.query(grants, "table.data-table td[data-label='Source'] code")
           |> LazyHTML.text() ==
             "/etc/responder.yaml" <> @source

    none =
      HTML.configuration(%{rows: [], grants: [], source: @source})
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(none, "section.configuration-grants p.empty-state") |> LazyHTML.text() =~
             "No MCP or tool grants are configured"

    assert LazyHTML.query(none, "section.configuration-values p.empty-state") |> LazyHTML.text() =~
             "No effective settings were published"
  end

  test "the static route renders the evidence under the shell's Settings title and description" do
    page =
      Router.snapshot("/configuration", "", %{
        projection: %{
          operator_configuration: fn ->
            %{rows: [row("admission", "enabled")], grants: [], source: @source}
          end
        }
      })

    assert page.title == "Settings"
    assert page.description =~ "What this installation decided"
    document = LazyHTML.from_fragment(page.body)
    assert Enum.count(LazyHTML.query(document, "div.configuration-evidence")) == 1
    assert Enum.count(LazyHTML.query(document, "h2")) == 3
  end

  defp row(key, value), do: %{key: key, value: value, source: @source}

  defp render(rows) do
    HTML.configuration(%{rows: rows, grants: [], source: @source})
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
