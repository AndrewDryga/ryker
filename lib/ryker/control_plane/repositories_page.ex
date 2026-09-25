defmodule Ryker.ControlPlane.RepositoriesPage do
  @moduledoc """
  The Repositories list: the code Ryker can read and work in, one Kit row per
  repository. A row says whether the repository is ready, still being set up
  or needs a person, and what to do about it, and which environments it is
  in; access, permissions, GitHub events, RYKER.md, the last code Ryker used
  and the workers holding it wait in one closed Details disclosure per row.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, ShortTime}

  # The App permissions work needs; anything missing is named on the row.
  @required_permissions ~w(metadata contents pull_requests checks actions deployments issues)

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
          text={problem(item)}
          meta={meta(item, @now)}
        >
          <:actions :if={retry?(item)}>
            <button
              type="button"
              class="ui-button secondary"
              phx-click="retry-github-onboarding"
              phx-value-repository={item.ref}
              phx-disable-with="Retrying…"
            >Retry setup</button>
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
        title={"No repositories match “#{@view.q}”."}
        text="Try another name or clear the search."
      />
      <Kit.empty
        :if={@items == [] and @view.q == ""}
        title="No repositories yet."
        text={
          if @connected,
            do: "Add repositories from GitHub below, so Ryker can read their code and work in them.",
            else: "Once GitHub is connected, add the repositories Ryker should work in here."
        }
      />
    </div>
    """
  end

  attr(:settings, :any, required: true, doc: "The settings view the shell already read")

  @doc "One line saying whether GitHub is connected, with the way to fix or change it."
  def github_status(assigns) do
    assigns = assign(assigns, :github, github(assigns.settings))

    ~H"""
    <div class="connection-line" id="github-status">
      <p>
        <span class="connection-dot" data-tone={elem(@github, 0)} aria-hidden="true"></span>
        <strong>{elem(@github, 1)}</strong> {elem(@github, 2)}
      </p>
      <.link navigate="/integrations/github" class="ui-button secondary">{elem(@github, 3)}</.link>
    </div>
    """
  end

  defp github({:ok, %{github_connection: :ready} = view}) do
    {:on, "GitHub is connected",
     "as the #{view.snapshot.github.app_slug} app. Ryker can read the repositories the app can reach.",
     "Manage"}
  end

  defp github({:ok, %{github_connection: :invalid}}),
    do:
      {:warn, "GitHub needs repair.",
       "Ryker cannot read repositories or add new ones until the connection works again.",
       "Repair GitHub connection"}

  defp github({:ok, _missing}), do: not_connected()
  defp github({:error, :settings_not_initialized}), do: not_connected()

  defp github(_unavailable),
    do:
      {:warn, "GitHub status is unknown",
       "because settings could not be read. Repositories below are still current.",
       "Open settings"}

  defp not_connected,
    do: {:warn, "GitHub is not connected.", "Connect it to add repositories.", "Connect GitHub"}

  @doc "The name people know a repository by: owner/repo when it was added from GitHub."
  @spec name(map()) :: String.t()
  def name(%{configured: %{github_repository: name}}) when is_binary(name), do: name
  def name(%{ref: ref}), do: ref

  defp state(%{configured: %{onboarding_state: onboarding}} = item) do
    cond do
      problem(item) -> {:warn, "Needs attention"}
      onboarding == :ready -> {:on, "Ready"}
      true -> {:busy, "Setting up"}
    end
  end

  defp state(_observed), do: {:off, "Not added"}

  # One sentence: what is wrong, then what to do about it.
  defp problem(%{configured: %{github_access: :removed}}),
    do:
      "GitHub access was removed. Give the Ryker GitHub App access to this repository again, then retry."

  defp problem(%{configured: %{github_access: :suspended}}),
    do:
      "The Ryker GitHub App is suspended for this repository. Unsuspend it in GitHub, then retry."

  defp problem(%{configured: %{onboarding_state: :blocked} = repository}),
    do:
      "Setup stopped: #{String.trim_trailing(repository[:onboarding_error] || "the last step failed", ".")}. Fix the cause, then retry setup."

  defp problem(%{configured: %{github_permissions: permissions}}) when is_map(permissions) do
    case missing_permissions(permissions) do
      [] ->
        nil

      missing ->
        "The Ryker GitHub App is missing permission for #{Enum.join(missing, ", ")}. Grant it in the app's settings on GitHub."
    end
  end

  defp problem(_item), do: nil

  defp missing_permissions(permissions) do
    @required_permissions
    |> Enum.reject(&Map.has_key?(permissions, &1))
    |> Enum.map(&String.replace(&1, "_", " "))
  end

  defp retry?(%{configured: %{onboarding_state: :blocked, github_access: :available}}), do: true
  defp retry?(_item), do: false

  defp meta(%{configured: %{onboarding_state: onboarding} = repository}, now)
       when onboarding in [:pending, :cloning, :scanning, :publishing] do
    [
      step(onboarding),
      repository[:updated_at] &&
        ShortTime.time(%{__changed__: nil, at: repository.updated_at, now: now, prefix: "since "})
    ]
  end

  defp meta(item, now),
    do: [environments(item), used_in(item), tasks(item.sessions), code(item.freshness, now)]

  defp step(:pending), do: "Waiting to start"
  defp step(:cloning), do: "Copying the code"
  defp step(:scanning), do: "Reading the repository"
  defp step(:publishing), do: "Opening a pull request for RYKER.md"

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
      <a
        :if={@repository[:knowledge_pull_request_url]}
        href={@repository.knowledge_pull_request_url}
        target="_blank"
        rel="noopener noreferrer"
      >Setup pull request</a>
    </.fact>
    <.fact :if={@repository[:onboarding_state]} label="RYKER.md">{knowledge(@repository)}</.fact>
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
    <.fact :if={policies(@repository) != []} label="Work policies">
      {Enum.join(policies(@repository), " · ")}
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
      {Components.label(@item.freshness.stale_base_status || "not recorded")}
      <code :if={@item.freshness.workspace_base_revision}>
        {@item.freshness.workspace_base_revision}
      </code>
    </.fact>
    <.fact label="Workers">
      <%= if @item.workers == [] do %>
        No worker reports this repository right now.
      <% else %>
        <span :for={worker <- @item.workers} class="entity-fact-line">
          {worker.worker_ref}: {worker_state(worker.state)}, has
          <code>{worker.revision || "no recorded revision"}</code><ShortTime.time
            :if={worker.last_seen_at}
            at={worker.last_seen_at}
            now={@now}
            prefix=", seen "
          />
        </span>
      <% end %>
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
  defp setup(:scanning), do: "Reading the repository"
  defp setup(:publishing), do: "Opening a pull request for RYKER.md"
  defp setup(:ready), do: "Done"
  defp setup(:blocked), do: "Stopped"

  defp knowledge(%{knowledge_status: :accepted, knowledge_source_commit: commit})
       when is_binary(commit),
       do: "Accepted, written from commit #{String.slice(commit, 0, 12)}"

  defp knowledge(%{knowledge_status: :proposed}), do: "Proposed in the setup pull request"
  defp knowledge(_repository), do: "Not written yet"

  defp permissions(permissions) when is_map(permissions) do
    case missing_permissions(permissions) do
      [] -> "Everything Ryker needs"
      missing -> "Missing " <> Enum.join(missing, ", ")
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

  defp policies(repository) do
    [
      repository[:contributor_policy] && "tasks use #{repository.contributor_policy}",
      repository[:schedule_policy] && "schedules use #{repository.schedule_policy}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp worker_state(:eligible), do: "ready"
  defp worker_state(:busy), do: "busy"
  defp worker_state(:draining), do: "finishing its work"
  defp worker_state(state), do: Components.label(state)

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
