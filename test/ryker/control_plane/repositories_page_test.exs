defmodule Ryker.ControlPlane.RepositoriesPageTest do
  @moduledoc """
  The Repositories list: one search box over Kit rows that say whether each
  repository is ready, still being set up, or needs a person and what to do,
  with the exact support facts in one closed Details disclosure per row.
  """
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Pages, RepositoriesPage}

  @now ~U[2026-08-28 14:00:00Z]

  @repository %{
    channels: 2,
    environments: ["Production", "Staging"],
    configured: %{
      action_grants: ["merge_pull_request"],
      contributor_policy: "ryker-write",
      github_access: :available,
      github_health: %{
        duplicate_count: 0,
        failed: 0,
        last_event_at: ~U[2026-08-28 13:00:00Z],
        pending: 0
      },
      github_permissions:
        Map.new(
          ~w(metadata contents pull_requests checks actions deployments issues),
          &{&1, "write"}
        ),
      github_repository: "acme/checkout-api",
      knowledge_pull_request_url: nil,
      knowledge_source_commit: String.duplicate("b", 40),
      knowledge_status: :accepted,
      onboarding_error: nil,
      onboarding_state: :ready,
      ref: "acme-checkout-api",
      updated_at: ~U[2026-08-28 13:56:00Z]
    },
    freshness: %{
      fetched_at: "2026-08-28T12:00:00Z",
      recorded_at: ~U[2026-08-28 12:01:00Z],
      remote_identity: "origin",
      requested_revision: "refs/heads/main",
      resolved_revision: "3f9a1c2e" <> String.duplicate("a", 32),
      stale_base_revision: nil,
      stale_base_status: "current",
      version: 2,
      workspace_base_revision: String.duplicate("a", 40)
    },
    publications: 1,
    ref: "acme-checkout-api",
    schedules: 1,
    sessions: 14,
    workers: [
      %{
        last_seen_at: ~U[2026-08-28 13:59:00Z],
        revision: "commit:abc123",
        state: :eligible,
        worker_ref: "coop-worker-one"
      }
    ]
  }

  test "repositories are a search over Kit rows, never a comparison table" do
    # Before 2026-09-24 this was a six-column table of counts with the access
    # policy and a frozen freshness receipt in "details" rows under each one.
    document = render([@repository, %{@repository | ref: "emisar", configured: nil}])

    assert outline(document, "div.repositories-page > *") == [
             "div.kit-toolbar",
             "div.entity-list"
           ]

    assert Enum.count(LazyHTML.query(document, "article.entity-row[role=listitem]")) == 2
    assert Enum.empty?(LazyHTML.query(document, "table, h1, h2, .result-count"))
  end

  test "a ready repository names itself as owner/repo and says where it is used" do
    row = render([@repository]) |> LazyHTML.query("article.entity-row")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "acme/checkout-api"
    assert state(row) == {"Ready", ["on"]}
    assert Enum.empty?(LazyHTML.query(row, "p.entity-text, .entity-actions"))

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In Production, Staging · used in 2 channels and 1 schedule · 14 tasks · code from 3f9a1c2e, fetched 2 h ago"

    assert LazyHTML.query(row, "p.entity-meta strong") |> LazyHTML.text() == "3f9a1c2e"
  end

  test "each repository says which environments it is in, or that it is in none" do
    # Channels choose an environment, not a repository, so a repository in no
    # environment is code no channel's work can reach. The row says so rather
    # than leaving the person to find out from a channel that cannot read it.
    alone = %{@repository | environments: [], channels: 0, schedules: 0}
    row = render([alone]) |> LazyHTML.query("article.entity-row")

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In no environment yet · 14 tasks · code from 3f9a1c2e, fetched 2 h ago"
  end

  test "a repository still being set up says which step it is on and since when" do
    setting_up = put_in(@repository, [:configured, :onboarding_state], :scanning)
    row = render([setting_up]) |> LazyHTML.query("article.entity-row")

    assert state(row) == {"Setting up", ["busy"]}

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "Reading the repository · since 4 min ago"
  end

  test "a repository that needs a person says what is wrong and what to do, one sentence each" do
    removed = put_in(@repository, [:configured, :github_access], :removed)
    row = render([removed]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "GitHub access was removed. Give the Ryker GitHub App access to this repository again, then retry."

    # Retrying while access is gone could only fail, so it is not offered.
    assert Enum.empty?(LazyHTML.query(row, "button[phx-click=retry-github-onboarding]"))

    document =
      @repository
      |> put_in([:configured, :github_permissions], %{"metadata" => "read"})
      |> render()

    text = document |> LazyHTML.query("p.entity-text") |> LazyHTML.text()
    assert text =~ "missing permission for contents, pull requests, checks"
    assert state(LazyHTML.query(document, "article.entity-row")) == {"Needs attention", ["warn"]}
  end

  test "a blocked setup offers Retry setup on its row, bound to that repository" do
    blocked =
      @repository
      |> put_in([:configured, :onboarding_state], :blocked)
      |> put_in([:configured, :onboarding_error], "Cloning failed: repository is empty.")

    row = render([blocked]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "Setup stopped: Cloning failed: repository is empty. Fix the cause, then retry setup."

    retry =
      LazyHTML.query(
        row,
        ".entity-actions button.ui-button.secondary[phx-click=retry-github-onboarding][phx-value-repository=acme-checkout-api]"
      )

    assert LazyHTML.text(retry) == "Retry setup"
  end

  test "the support facts wait in one closed Details disclosure per row" do
    details = render([@repository]) |> LazyHTML.query("article.entity-row details:not([open])")
    assert Enum.count(details) == 1
    assert LazyHTML.query(details, "summary") |> LazyHTML.text() == "Details"

    text = details |> LazyHTML.text() |> squeeze()
    assert text =~ "acme/checkout-api · access available"
    assert text =~ "Accepted, written from commit bbbbbbbbbbbb"
    assert text =~ "Everything Ryker needs"
    assert text =~ "merge pull request"
    assert text =~ "Up to date"
    assert text =~ "tasks use ryker-write"
    assert text =~ "from refs/heads/main"
    assert text =~ "not a live check"
    assert text =~ "coop-worker-one: ready"
    assert text =~ "commit:abc123"
    assert text =~ "1 pull request opened by Ryker"

    assert LazyHTML.query(details, "a[href='/activity?repository=acme-checkout-api']")
           |> Enum.count() == 1
  end

  test "a repository Ryker only saw in past work is not ready, and invents no receipt or worker" do
    observed = %{@repository | configured: nil, freshness: nil, workers: [], sessions: 0}
    row = render([observed]) |> LazyHTML.query("article.entity-row")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "acme-checkout-api"
    assert state(row) == {"Not added", ["off"]}
    text = row |> LazyHTML.query("details") |> LazyHTML.text() |> squeeze()
    assert text =~ "None yet. It appears after Ryker's first task in this repository."
    assert text =~ "No worker reports this repository right now."
  end

  test "an empty list says how to add one, and a search miss says so" do
    bare = render([])

    assert LazyHTML.query(bare, ".entity-empty-title") |> LazyHTML.text() ==
             "No repositories yet."

    assert LazyHTML.query(bare, "form.filter-toolbar input[type=search][disabled]")
           |> Enum.count() == 1

    miss = render([], %{"q" => "absent"})

    assert LazyHTML.query(miss, ".entity-empty-title") |> LazyHTML.text() ==
             "No repositories match “absent”."
  end

  test "without a working GitHub App the page offers no Add repositories action" do
    # The header action and the import panel both led to "Repair the GitHub
    # connection first", beside the status line that already said so.
    page =
      Pages.page(["repositories"], %{}, %{
        projection: %{
          repositories: fn _params -> [] end,
          settings: fn -> {:ok, %{github_connection: :invalid}} end
        }
      })

    refute Map.has_key?(page, :action)

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query(".entity-empty")
           |> LazyHTML.text() =~ "Once GitHub is connected"
  end

  test "with GitHub working, the route carries the search and offers Add repositories as the page's one action" do
    parent = self()

    page =
      Pages.page(["repositories"], %{"q" => " checkout "}, %{
        projection: %{
          repositories: fn params ->
            send(parent, {:repositories, params})
            [@repository]
          end,
          settings: fn -> {:ok, %{github_connection: :ready}} end
        }
      })

    assert_received {:repositories, %{"q" => "checkout"}}
    assert page.title == "Repositories"
    assert page.description == "Code Ryker can read and work in."

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query("form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["checkout"]

    action = LazyHTML.from_fragment(page.action)

    assert LazyHTML.query(action, "a.ui-button.primary[href='#add-repositories']")
           |> LazyHTML.text() == "Add repositories"

    refute page.body =~ "Publishing settings"
  end

  test "the GitHub line says whether GitHub is connected and where to change it" do
    for {settings, words, link} <- [
          {{:ok, %{github_connection: :ready, snapshot: %{github: %{app_slug: "ryker-acme"}}}},
           "GitHub is connected as the ryker-acme app.", "Manage"},
          {{:ok, %{github_connection: :invalid}}, "GitHub needs repair.",
           "Repair GitHub connection"},
          {{:ok, %{github_connection: :missing}}, "GitHub is not connected.", "Connect GitHub"},
          {{:error, :settings_not_initialized}, "GitHub is not connected.", "Connect GitHub"}
        ] do
      line =
        %{__changed__: nil, settings: settings}
        |> RepositoriesPage.github_status()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      assert line |> LazyHTML.query("p") |> LazyHTML.text() |> squeeze() =~ words
      assert LazyHTML.query(line, "a[href='/integrations/github']") |> LazyHTML.text() =~ link
    end
  end

  defp state(row) do
    state = LazyHTML.query(row, ".entity-side .state-word")
    {LazyHTML.text(state), LazyHTML.attribute(state, "data-tone")}
  end

  defp render(items, params \\ %{}) do
    %{items: List.wrap(items), view: RepositoriesPage.view(params), now: @now}
    |> RepositoriesPage.html()
    |> LazyHTML.from_fragment()
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

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
