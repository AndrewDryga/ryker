defmodule Responder.ControlPlane.BehaviorPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{BehaviorPage, CardLab}

  test "typed rules show sender restrictions and their full instruction only once" do
    # Trigger-based rules have no title and can carry a long task. Repeating
    # it as a heading hides the scope and controls below duplicate prose.
    for {source, label} <- [
          {"human", "People only"},
          {"app", "Apps only"},
          {"any", "People and apps"}
        ] do
      rule = %{
        item(:standing_assignment)
        | payload: %{
            "trigger" => "terraform_plan",
            "source_filter" => source,
            "task" => "Review the exact posted Terraform plan and report material risk."
          }
      }

      html = render_component(&BehaviorPage.render/1, view: view(:standing_assignment, [rule]))
      assert html =~ label
      assert html |> String.split(rule.payload["task"]) |> length() == 2
      assert html =~ "Terraform plan"
    end
  end

  test "a library with only expired history is not presented as never configured" do
    snapshot = %{view(:guidance, []) | counts: %{"expired" => 2}}
    html = render_component(&BehaviorPage.render/1, view: snapshot)
    assert html =~ "No active or paused guidance"
    refute html =~ "No guidance yet"
  end

  test "each empty library explains how to use the feature and links to a real preview" do
    for kind <- [:standing_assignment, :preference, :guidance] do
      html = render_component(&BehaviorPage.render/1, view: view(kind, []))
      assert html =~ "Review and confirm the proposed card"
      assert html =~ "All statuses"
      assert html =~ "Applies to"
      assert html =~ "No #{String.downcase(BehaviorPage.title(kind))} yet"
      document = LazyHTML.from_fragment(html)
      [path] = document |> LazyHTML.query("a[href^='/card-lab/']") |> LazyHTML.attribute("href")
      ["card-lab", family, state] = String.split(path, "/", trim: true)
      assert {:ok, _} = CardLab.fetch(family, state)
    end
  end

  test "active instructions expose scope and confirmation buttons while history stays read only" do
    # This is an adversarial host-state fixture, not a fabricated model response.
    item = item(:standing_assignment)

    view = %{
      view(item.kind, [item])
      | pages: 3,
        page: 2,
        total: 60,
        runs: [
          %{
            rule_ref: item.ref,
            episode_ref: "episode:one",
            at: item.confirmed_at,
            outcome: :decided,
            action: :ignore
          }
        ]
    }

    html = render_component(&BehaviorPage.render/1, view: view)
    assert html =~ "&lt;unsafe&gt;"
    refute html =~ "<unsafe>"
    assert html =~ "No expiry"
    assert html =~ "No response needed"
    assert html =~ "Original conversation"
    assert html =~ "/episodes/episode%3Aone"
    assert html =~ "page=1"
    assert html =~ "page=3"
    document = LazyHTML.from_fragment(html)
    assert document |> LazyHTML.query("form.action-control button") |> LazyHTML.text() =~ "Pause"

    assert document |> LazyHTML.query("form.action-control") |> LazyHTML.attribute("method") == [
             "get",
             "get"
           ]

    assert html =~ "Event conditions"

    for status <- ["expired", "deleted", "superseded"] do
      html =
        render_component(&BehaviorPage.render/1,
          view: view(item.kind, [%{item | status: status}])
        )

      refute html =~ "action-control"
    end

    assert render_component(&BehaviorPage.render/1,
             view: view(item.kind, [%{item | status: "disabled"}])
           ) =~ "Resume"
  end

  test "guidance and preferences display their meaning without machine identifiers" do
    guidance = %{
      item(:guidance)
      | payload: %{
          "subject" => "Review guidance",
          "summary" => "Risk first",
          "text" => "Full instruction"
        },
        scope_kind: :workspace
    }

    html = render_component(&BehaviorPage.render/1, view: view(:guidance, [guidance]))
    assert html =~ "Full instruction"
    assert html =~ "Entire workspace"

    preference = %{
      item(:preference)
      | payload: %{"key" => "response_detail", "value" => "concise"},
        scope_kind: :repository,
        scope_ref: "emisar"
    }

    html = render_component(&BehaviorPage.render/1, view: view(:preference, [preference]))
    assert html =~ "Response detail"
    assert html =~ "Concise"
    assert html =~ "emisar"
  end

  test "filtered empty libraries do not pretend all instructions are absent" do
    snapshot = %{
      view(:guidance, [])
      | params: %{"q" => "missing", "status" => "all", "scope" => ""}
    }

    html = render_component(&BehaviorPage.render/1, view: snapshot)
    assert html =~ "No matching entries"
    assert html =~ "Clear filters"
    refute html =~ "No guidance yet"
  end

  defp view(kind, items),
    do: %{
      kind: kind,
      items: items,
      counts: %{},
      total: length(items),
      page: 1,
      pages: 1,
      runs: [],
      params: %{"q" => "", "scope" => "", "status" => "current"}
    }

  defp item(kind),
    do: %{
      kind: kind,
      ref: "behavior:one",
      payload: %{
        "title" => "<unsafe>",
        "task" => "Review the plan",
        "filter" => %{"action" => "submitted"},
        "source_kind" => "github",
        "repository" => "emisar"
      },
      status: "active",
      scope_kind: :conversation,
      scope_ref: "slack:T123:C456",
      workspace_ref: "slack:T123",
      confirmed_at: ~U[2026-09-06 12:00:00Z],
      use_count: 3,
      last_used_at: nil,
      expires_at: nil,
      source_conversation_ref: "slack:T123:C456",
      source_message_ref: "1787832000.000100"
    }
end
