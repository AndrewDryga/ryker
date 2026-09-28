defmodule Ryker.ControlPlane.RepositoriesPage do
  @moduledoc """
  The Repositories list: the code Ryker can read and work in, one Kit row per
  repository. A row says whether the repository is ready, still being set up,
  not fully added or needs a person, and what to do about it, which
  environments it is in, and where its RYKER.md stands: when Ryker last
  updated it, and what is under way or failed (`Ryker.RepositoryKnowledge`).
  Access, permissions, GitHub events, RYKER.md
  and the last code Ryker used wait in one closed Details disclosure per row.
  A ready repository's RYKER.md can be refreshed at once, and every added
  repository can be removed; the page asks first, over the list
  (`refresh_question/1`, `removal/1`). An open list redraws when anything a
  row says changes (`subscriptions/0`).
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Environments, Integrations, Kit, SettingsView, ShortTime}
  alias Ryker.{Episodes, RepositoryKnowledge, Schedules}
  alias Ryker.Episodes.Words
  alias Ryker.GitHub.Events, as: GitHubEvents
  alias Ryker.Publication.Custody, as: Publications
  alias Ryker.Work.Custody, as: WorkCustody

  # The App permissions a repository cannot be set up or worked in without;
  # anything missing is named on the row and needs a person.
  @required_permissions ~w(metadata contents pull_requests)
  # Each of these only turns one feature on: reading CI (checks), rerunning it
  # (actions), issue events (issues) and deployment events (deployments), so
  # one that is missing is a detail. Flagging a missing deployments permission
  # put Andrew's repository in Needs attention (2026-09-26).
  @optional_permissions ~w(checks actions deployments issues)
  @setting_up [:pending, :cloning]

  @doc """
  The topics an open Repositories list listens to, as the context functions
  that subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the repositories
  and GitHub's state, which live in the settings (`SettingsView.subscriptions/0`,
  which includes the workers holding them); GitHub's deliveries; each
  repository's RYKER.md; and the schedules, working copies, code changes and
  runs each row counts.
  """
  def subscriptions do
    SettingsView.subscriptions() ++
      [
        {GitHubEvents, :subscribe_deliveries, []},
        {RepositoryKnowledge, :subscribe, []},
        {Schedules, :subscribe_schedules, []},
        {WorkCustody, :subscribe_sessions, []},
        {Publications, :subscribe_publications, []},
        {Episodes, :subscribe_episodes, []}
      ]
  end

  @doc "The search phrase from the page's query."
  @spec view(map()) :: %{q: String.t()}
  def view(params),
    do: %{q: if(is_binary(params["q"]), do: String.trim(params["q"]), else: "")}

  @doc "The page body as HTML, as the route hands it to the shell."
  @spec html(map()) :: binary()
  def html(assigns) do
    assigns
    |> Map.put(:__changed__, nil)
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  attr(:items, :list, required: true)
  attr(:view, :map, required: true)
  attr(:now, :any, default: nil)
  attr(:connected, :boolean, default: true)

  @doc "The list body: search, then one row per repository or what would put one here."
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:now, fn -> nil end)
      |> then(&assign(&1, :now, &1.now || DateTime.utc_now()))

    ~H"""
    <div class="repositories-page">
      <Kit.counts label="Repositories" items={counts(@items, @view.q)} />
      <Kit.toolbar>
        <Components.filter_toolbar
          id="operator-search"
          path="/repositories"
          label="Search repositories"
          placeholder="Search repositories"
          query={@view.q}
          filtered={@view.q != ""}
          disabled={@items == [] and @view.q == ""}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@items != []} label="Repositories">
        <Kit.entity_row
          :for={item <- @items}
          id={"repository-" <> item.ref}
          icon={:repository}
          name={name(item)}
          state={state(item)}
          text={problem(item) || knowledge_problem(item)}
          meta={meta(item, @now)}
        >
          <:actions :if={removable?(item)}>
            <button
              :if={refreshable?(item)}
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="refresh-knowledge"
              phx-value-ref={item.ref}
            >Refresh knowledge<span class="sr-only">{" of " <> name(item)}</span></button>
            <button
              :if={retry?(item)}
              type="button"
              class="ui-button secondary"
              phx-click="retry-github-onboarding"
              phx-value-repository={item.ref}
              phx-disable-with="Retrying…"
            >Retry setup</button>
            <button
              :if={add_again?(item)}
              type="button"
              class="ui-button secondary"
              phx-click="add-repository-again"
              phx-value-repository={item.ref}
              phx-disable-with="Adding…"
            >Add it again</button>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="remove-repository"
              phx-value-ref={item.ref}
            >Remove<span class="sr-only">{" " <> name(item)}</span></button>
          </:actions>
          <:details>
            <details id={"repository-" <> item.ref <> "-details"} class="entity-details">
              <summary>Details</summary>
              <dl class="entity-facts">
                <.facts item={item} now={@now} />
              </dl>
            </details>
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <Kit.empty
        :if={@items == [] and @view.q != ""}
        icon={:search}
        title={"No repositories match “#{@view.q}”"}
        text="Try another name or clear the search."
      />
      <Kit.empty
        :if={@items == [] and @view.q == ""}
        icon={:repository}
        title="No repositories yet"
        text={
          if @connected,
            do: "Add repositories from GitHub, so Ryker can read their code and work in them.",
            else: "Once GitHub is connected, add the repositories Ryker should work in here."
        }
      />
    </div>
    """
  end

  attr(:settings, :any, required: true, doc: "The settings view the shell already read")

  @doc """
  One line saying where GitHub stands, in the words the GitHub page uses. Its
  button opens GitHub's page: Add repositories is the list's own action, so
  the line never offers it a second time (Andrew, 2026-09-27: "what is the
  point to show two add repositories buttons here?").
  """
  def github_status(assigns) do
    assigns =
      assign(assigns, :integration, assigns.settings |> github() |> without_adding())

    ~H"""
    <Integrations.line id="github-status" key={:github} integration={@integration} />
    """
  end

  defp github(settings), do: Integrations.read(:github, settings)

  defp without_adding(%{action: %{href: "/repositories/new"}} = integration),
    do: %{integration | action: %{label: "Manage", href: "/integrations/github"}}

  defp without_adding(integration), do: integration

  @doc """
  What removing a repository asks: its name, then what removing it does, in
  the order it matters to the people using it.
  """
  @spec removal(map()) :: %{title: String.t(), text: String.t()}
  def removal(item) do
    text =
      [
        item.environments != [] &&
          "Work in #{Environments.sentence(item.environments)} can no longer use its code.",
        item.schedules > 0 && "Schedules that work in it stop running.",
        if(get_in(item, [:configured, :onboarding_state]) in @setting_up,
          do: "Its setup stops, and Ryker deletes the copy of its code it keeps.",
          else: "Ryker deletes the copy of its code it keeps."
        ),
        "Past requests stay, and you can add it again later."
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    %{title: "Remove #{name(item)}?", text: text}
  end

  @doc """
  What Refresh knowledge asks: what refreshing does, and that Ryker keeps
  what it writes: nothing reaches the repository.
  """
  @spec refresh_question(map()) :: %{title: String.t(), text: String.t()}
  def refresh_question(item) do
    %{
      title: "Refresh knowledge of #{name(item)}?",
      text:
        "A model reads the repository again now and Ryker rewrites its knowledge from " <>
          "what it finds, checking every path and command against the code. Work in the " <>
          "repository starts from the new version as soon as it is written. Nothing is " <>
          "written to the repository."
    }
  end

  @doc "The name people know a repository by: owner/repo when it was added from GitHub."
  @spec name(map()) :: String.t()
  def name(%{configured: %{github_repository: name}}) when is_binary(name), do: name
  def name(%{ref: ref}), do: ref

  # Saved without its GitHub binding (an import that stopped half-way), a
  # repository can be neither set up nor worked in, and retrying its setup
  # only stops again at "GitHub binding is missing".
  defp state(%{configured: %{github_bound: false}}), do: {:warn, "Not fully added"}

  defp state(%{configured: %{onboarding_state: onboarding}} = item) do
    cond do
      problem(item) -> {:warn, "Needs attention"}
      onboarding == :ready -> {:on, "Ready"}
      true -> {:busy, "Setting up"}
    end
  end

  defp state(_observed), do: {:off, "Not added"}

  # How many repositories the list holds, then how many need a person.
  defp counts(items, query) do
    attention = Enum.count(items, &problem/1)

    [
      Kit.list_total(length(items), {"repository", "repositories"}, query != ""),
      attention > 0 &&
        %{
          value: attention,
          label: if(attention == 1, do: "needs attention", else: "need attention"),
          tone: :warn
        }
    ]
    |> Enum.filter(& &1)
  end

  # One sentence: what is wrong, then what to do about it.
  defp problem(%{configured: %{github_bound: false} = repository}) do
    if is_binary(repository[:github_repository]),
      do:
        "Adding it stopped before it finished, so Ryker cannot use it yet. " <>
          "Add it again, or remove it.",
      else:
        "It was not added from GitHub, so Ryker cannot use it. Remove it, then add it from " <>
          "GitHub."
  end

  defp problem(%{configured: %{github_access: :removed}}),
    do:
      "GitHub access was removed. Give the Ryker GitHub App access to this repository again, then retry."

  defp problem(%{configured: %{github_access: :suspended}}),
    do:
      "The Ryker GitHub App is suspended for this repository. Unsuspend it in GitHub, then retry."

  # A reason that already says how to go on is not followed by a second
  # instruction: an archived repository's "Unarchive it on GitHub and retry,
  # or remove it" read on with "Fix the cause, then retry setup" (2026-09-27).
  defp problem(%{configured: %{onboarding_state: :blocked} = repository}) do
    reason = repository[:onboarding_error] || "The last step failed."

    if reason =~ ~r/\bretry\b/i,
      do: "Setup stopped. " <> reason,
      else: "Setup stopped. #{reason} Fix the cause, then retry setup."
  end

  defp problem(%{configured: %{github_permissions: permissions}}) when is_map(permissions) do
    case missing_permissions(permissions) do
      [] ->
        nil

      missing ->
        needed =
          missing
          |> Enum.map(&"#{String.capitalize(&1)} (#{permission_level(&1)})")
          |> Environments.sentence()

        "The Ryker GitHub App cannot use this repository without #{needed}. " <>
          "In GitHub, open Settings › Developer settings › GitHub Apps, choose the Ryker app, " <>
          "and set them under Permissions & events. Then approve the new permissions where " <>
          "the app is installed (Settings › Applications › Installed GitHub Apps); Ryker sees " <>
          "the change on its own."
    end
  end

  defp problem(_item), do: nil

  # The level each permission needs, in GitHub's own words.
  defp permission_level("metadata"), do: "Read-only"
  defp permission_level("checks"), do: "Read-only"
  defp permission_level("deployments"), do: "Read-only"
  defp permission_level(_write), do: "Read and write"

  defp missing_permissions(permissions, wanted \\ @required_permissions) do
    wanted
    |> Enum.reject(&Map.has_key?(permissions, &1))
    |> Enum.map(&String.replace(&1, "_", " "))
  end

  defp retry?(%{
         configured: %{onboarding_state: :blocked, github_access: :available, github_bound: true}
       }),
       do: true

  defp retry?(_item), do: false

  # RYKER.md is written for a repository that is set up and still granted,
  # and not while a model is writing it already.
  defp refreshable?(%{
         configured: %{onboarding_state: :ready, github_access: :available, github_bound: true},
         knowledge: knowledge
       }),
       do: not writing?(knowledge)

  defp refreshable?(_item), do: false

  defp writing?(%{phase: phase}), do: phase == :write
  defp writing?(_knowledge), do: false

  defp add_again?(%{configured: %{github_bound: false, github_repository: name}}),
    do: is_binary(name)

  defp add_again?(_item), do: false

  # Only a saved repository can be removed; one Ryker only saw in past work
  # has nothing to remove but its history, which stays.
  defp removable?(%{configured: %{onboarding_state: _saved}}), do: true
  defp removable?(_item), do: false

  # Not fully added, a repository is not being set up whatever its state says.
  defp meta(%{configured: %{github_bound: false}} = item, now), do: use_facts(item, now)

  defp meta(%{configured: %{onboarding_state: onboarding} = repository}, now)
       when onboarding in @setting_up do
    [
      step(onboarding),
      repository[:updated_at] &&
        ShortTime.time(%{__changed__: nil, at: repository.updated_at, now: now, prefix: "since "})
    ]
  end

  defp meta(%{configured: %{onboarding_state: :ready}} = item, now),
    do: use_facts(item, now) ++ knowledge_facts(Map.get(item, :knowledge), now)

  defp meta(item, now), do: use_facts(item, now)

  defp use_facts(item, now),
    do: [environments(item), used_in(item), tasks(item.sessions), code(item.freshness, now)]

  defp step(:pending), do: "Waiting to start"
  defp step(:cloning), do: "Copying the code"

  # Where RYKER.md stands, in the row's own line: what is under way, or when
  # Ryker last updated it.
  defp knowledge_facts(nil, _now), do: ["Knowledge not written yet"]
  defp knowledge_facts(%{phase: :write}, _now), do: ["Writing knowledge"]

  defp knowledge_facts(%{document_by: :outline} = knowledge, now),
    do: [updated(knowledge, now, "Knowledge outline written ")]

  defp knowledge_facts(%{document_at: %DateTime{}} = knowledge, now),
    do: [updated(knowledge, now, "Knowledge updated ")]

  defp knowledge_facts(_knowledge, _now), do: ["Knowledge not written yet"]

  defp updated(knowledge, now, prefix),
    do:
      ShortTime.time(%{
        __changed__: nil,
        at: knowledge.document_at,
        now: now,
        prefix: prefix
      })

  # A failed step says why on the row, beneath anything that needs a person
  # more; the repository itself still works.
  defp knowledge_problem(%{
         configured: %{onboarding_state: :ready},
         knowledge: %{phase: :idle, error: error}
       })
       when is_binary(error),
       do: error

  defp knowledge_problem(_item), do: nil

  # Channels choose environments, so an added repository in none of them is
  # code no channel's work can reach; the row says so.
  defp environments(%{configured: nil}), do: nil
  defp environments(%{environments: []}), do: "In no environment yet"
  defp environments(%{environments: names}), do: "In " <> Enum.join(names, ", ")

  defp used_in(%{channels: channels, schedules: schedules}) do
    places =
      [plural(channels, "channel", "channels"), plural(schedules, "schedule", "schedules")]
      |> Enum.reject(&is_nil/1)

    if places != [], do: "used in " <> Enum.join(places, " and ")
  end

  defp tasks(0), do: nil
  defp tasks(count), do: plural(count, "task", "tasks")

  defp code(nil, _now), do: nil

  defp code(freshness, now) do
    revision = String.slice(freshness.resolved_revision || "", 0, 8)
    code_fact(%{__changed__: nil, revision: revision, fetched_at: freshness.fetched_at, now: now})
  end

  defp code_fact(assigns) do
    ~H"""
    code from
    <strong>{@revision}</strong><ShortTime.time
      :if={@fetched_at}
      at={@fetched_at}
      now={@now}
      prefix=", fetched "
    />
    """
  end

  attr(:item, :map, required: true)
  attr(:now, :any, required: true)

  # The support facts behind a row, as plain sentences: nothing here is
  # needed to understand the row, and everything here is exact.
  defp facts(assigns) do
    assigns = assign(assigns, :repository, assigns.item.configured || %{})

    ~H"""
    <.fact :if={@repository[:github_repository]} label="GitHub">
      {@repository.github_repository} · access {access(@repository[:github_access])}
    </.fact>
    <.fact :if={@repository[:onboarding_state]} label="Setup">
      {setup(@repository.onboarding_state)}
    </.fact>
    <.fact :if={@repository[:onboarding_state]} label="Knowledge">
      {knowledge(@item[:knowledge])}
      <Components.disclosure
        :if={@item[:knowledge][:document]}
        id={"repository-knowledge-#{@repository.ref}"}
        label="Read it"
        class="repository-knowledge-document"
      >
        <pre>{@item.knowledge.document}</pre>
      </Components.disclosure>
    </.fact>
    <.fact :if={@item[:knowledge][:reason]} label="Last written because">
      {@item.knowledge.reason}
    </.fact>
    <.fact :if={@item[:knowledge][:next_check_at]} label="Knowledge checks">
      <ShortTime.time
        :if={@item.knowledge.checked_at}
        at={@item.knowledge.checked_at}
        now={@now}
        prefix="Last "
      /><span :if={@item.knowledge.checked_at}>, next </span><ShortTime.time
        at={@item.knowledge.next_check_at}
        now={@now}
        prefix={if @item.knowledge.checked_at, do: nil, else: "Next "}
      />
    </.fact>
    <.fact :if={Map.has_key?(@repository, :github_permissions)} label="Permissions">
      {permissions(@repository.github_permissions)}
    </.fact>
    <.fact :if={@repository[:action_grants] not in [nil, []]} label="Allowed GitHub actions">
      {Enum.map_join(@repository.action_grants, ", ", &String.replace(&1, "_", " "))}
    </.fact>
    <.fact :if={is_map(@repository[:github_health])} label="GitHub events">
      {events(@repository.github_health)}<ShortTime.time
        :if={@repository.github_health.last_event_at}
        at={@repository.github_health.last_event_at}
        now={@now}
        prefix=", last received "
      />
    </.fact>
    <.fact label="Last code used">
      <%= if @item.freshness do %>
        <code>{@item.freshness.resolved_revision}</code>
        from {@item.freshness.requested_revision}, fetched {Components.timestamp(
          parse(@item.freshness.fetched_at)
        )}. This is the code saved with Ryker's last task here, not a live check.
      <% else %>
        None yet. It appears after Ryker's first task in this repository.
      <% end %>
    </.fact>
    <.fact :if={@item.freshness} label="Base">
      {Words.label(@item.freshness.stale_base_status || "not recorded")}
      <code :if={@item.freshness.workspace_base_revision}>
        {@item.freshness.workspace_base_revision}
      </code>
    </.fact>
    <.fact :if={@item.publications > 0} label="Pull requests">
      {plural(@item.publications, "pull request", "pull requests")} opened by Ryker
    </.fact>
    <.fact label="Requests">
      <a href={"/activity?" <> URI.encode_query(%{"repository" => @item.ref})}>
        See requests in this repository
      </a>
    </.fact>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp fact(assigns) do
    ~H"""
    <div>
      <dt>{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp access(:available), do: "available"
  defp access(:suspended), do: "suspended"
  defp access(:removed), do: "removed"
  defp access(_unknown), do: "not recorded"

  defp setup(:pending), do: "Waiting to start"
  defp setup(:cloning), do: "Copying the code"
  defp setup(:ready), do: "Done"
  defp setup(:blocked), do: "Stopped"

  # Who wrote the RYKER.md Work is briefed with.
  defp knowledge(%{document_by: :outline, document_commit: commit}),
    do: "An outline from the file list at #{short(commit)}; a model could not finish reading it."

  defp knowledge(%{document_by: :model, document_commit: commit}),
    do: "Written by a model from #{short(commit)}."

  defp knowledge(_knowledge), do: "Not written yet."

  defp short(commit), do: String.slice(commit, 0, 7)

  defp permissions(permissions) when is_map(permissions) do
    case {missing_permissions(permissions),
          missing_permissions(permissions, @optional_permissions)} do
      {[], []} -> "Everything Ryker needs"
      {[], optional} -> "Enough to work here. Not shared: " <> Enum.join(optional, ", ")
      {missing, _optional} -> "Missing " <> Enum.join(missing, ", ")
    end
  end

  defp permissions(_unchecked), do: "Not checked yet"

  defp events(health) do
    [
      if(health.pending == 0, do: "Up to date", else: "#{health.pending} waiting"),
      if(health.failed > 0, do: "#{health.failed} failed"),
      if(health.duplicate_count > 0,
        do: "#{health.duplicate_count} duplicate deliveries ignored"
      ),
      if(is_nil(health.last_event_at), do: "none received yet")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp plural(0, _one, _many), do: nil
  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  defp parse(%DateTime{} = at), do: at

  defp parse(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  defp parse(_missing), do: nil
end
