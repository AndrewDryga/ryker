defmodule Responder.ControlPlane.BehaviorPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.BehaviorPage

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

  test "creation help is a closed disclosure under the description that links only to surviving pages" do
    # The Standing rules screenshot Andrew sent on 2026-09-09 showed the
    # creation help floated into a right-hand column beside three 30px status
    # counts, always open, linking into the Card Lab and /lab surfaces that
    # are being retired. The help still has to be discoverable and still has
    # to say an entry is proposed and confirmed in a conversation; it now
    # lives under the description as a specifically labelled disclosure that
    # points only at pages that survive.
    for {kind, label} <- [
          {:standing_assignment, "How to add and manage rules"},
          {:preference, "How to save and manage preferences"},
          {:guidance, "How to add and manage guidance"}
        ] do
      html = render_component(&BehaviorPage.render/1, view: view(kind, []))
      document = LazyHTML.from_fragment(html)
      help = LazyHTML.query(document, "details.page-help:not([open])")
      assert Enum.count(help) == 1
      assert help |> LazyHTML.query("summary") |> LazyHTML.text() == label
      assert LazyHTML.text(help) =~ "Review and confirm the proposed card"
      assert LazyHTML.text(help) =~ "Pause or Resume"
      assert "/channels" in (help |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href"))

      for href <- document |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href") do
        refute String.starts_with?(href, "/card-lab"), href
        refute String.starts_with?(href, "/lab"), href
      end

      refute html =~ "behavior-create"
      assert Enum.empty?(LazyHTML.query(document, ".behavior-library > h2, .page-help h2"))
      assert html =~ "No #{String.downcase(BehaviorPage.title(kind))} yet"
    end
  end

  test "the library reads help, toolbar, count, entries, history with no statistics row or apply button" do
    # Same screenshot: a <dl class="behavior-counts"> of Active/Paused/Expired
    # numbers above the list, an Apply button beside the filters, and the
    # total only inside the pagination line. Andrew approved one column:
    # help, one compact toolbar, a quiet count, the entries, then history.
    item = item(:standing_assignment)
    html = render_component(&BehaviorPage.render/1, view: view(:standing_assignment, [item]))
    document = LazyHTML.from_fragment(html)

    assert outline(document, ".behavior-library > *") == [
             "details.page-help",
             "form.filter-toolbar",
             "p.result-count",
             "div.behavior-entries",
             "section.behavior-history"
           ]

    refute html =~ "behavior-counts"
    refute html =~ "behavior-overview"
    assert document |> LazyHTML.query("p.result-count") |> LazyHTML.text() == "1 rule"

    toolbar = LazyHTML.query(document, "form.filter-toolbar")
    assert LazyHTML.attribute(toolbar, "method") == ["get"]
    assert LazyHTML.attribute(toolbar, "action") == ["/rules"]
    assert Enum.empty?(LazyHTML.query(toolbar, "button:not(noscript button)"))

    for {name, id} <- [
          {"q", "behavior-search"},
          {"status", "behavior-status"},
          {"scope", "behavior-scope"}
        ] do
      assert LazyHTML.query(toolbar, "[name=#{name}]") |> LazyHTML.attribute("id") == [id]
      assert Enum.count(LazyHTML.query(toolbar, "label[for=#{id}]")) == 1
    end

    assert Enum.empty?(LazyHTML.query(toolbar, "a.filter-clear"))
  end

  test "the result count is the filtered total, never the unfiltered status counts" do
    # BehaviorLibrary counts statuses before search and scope filtering while
    # total is filtered. The old page showed the former as if they described
    # the current list; the count beside the list must be the list's own.
    for {kind, one, many} <- [
          {:standing_assignment, "1 rule", "2 rules"},
          {:preference, "1 preference", "2 preferences"},
          {:guidance, "1 guidance entry", "2 guidance entries"}
        ] do
      snapshot = %{view(kind, [item(kind)]) | counts: %{"active" => 9, "expired" => 4}}
      one_html = render_component(&BehaviorPage.render/1, view: snapshot)
      assert count_text(one_html) == one
      refute one_html =~ ">9<"
      refute one_html =~ ">4<"

      two = %{snapshot | items: [item(kind), %{item(kind) | ref: "behavior:two"}], total: 2}
      assert count_text(render_component(&BehaviorPage.render/1, view: two)) == many
    end

    filtered = %{
      view(:guidance, [])
      | counts: %{"active" => 9},
        params: %{"q" => "missing", "status" => "all", "scope" => ""}
    }

    html = render_component(&BehaviorPage.render/1, view: filtered)
    document = LazyHTML.from_fragment(html)
    assert Enum.empty?(LazyHTML.query(document, "p.result-count"))
    assert html =~ "No matching entries"

    assert LazyHTML.query(document, "form.filter-toolbar a.filter-clear")
           |> LazyHTML.attribute("href") == ["/guidance"]
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
    assert html =~ "/timeline/episode%3Aone"
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

  defp count_text(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query("p.result-count") |> LazyHTML.text()

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
