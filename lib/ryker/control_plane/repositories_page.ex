defmodule Ryker.ControlPlane.RepositoriesPage do
  @moduledoc """
  The Repositories list and each repository's own page: the code Ryker can
  read and work in.

  A row says whether the repository is ready, still being set up, not fully
  added or needs a person, and what to do about it, which environments it is
  in, and where its knowledge stands: when Ryker last updated it, and what is
  under way or failed (`Ryker.RepositoryKnowledge`). The whole row opens the
  repository's page (`detail_html/2`), which holds everything else in cards:
  what needs doing and its buttons, the knowledge itself, where the
  repository is used, GitHub's side, the last code Ryker used, and removing
  it (Andrew, 2026-09-28: "repos missing their own page where that buttons
  will move to"). Refreshing its knowledge and removing it ask first, over
  the page (`refresh_question/1`, `removal/1`). An open page redraws when
  anything it says changes (`subscriptions/0`).
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    CallRun,
    Components,
    Environments,
    Integrations,
    Kit,
    KnowledgeDocument,
    Paths,
    SettingsView,
    ShortTime
  }

  alias Ryker.{Episodes, RepositoryKnowledge, Schedules}
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
          href={Paths.repository(item.ref)}
          link_row
          state={state(item)}
          text={problem(item) || knowledge_problem(item)}
          meta={meta(item, @now)}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@items == [] and @view.q != ""}
        icon={:search}
        title={"No repositories match \"#{@view.q}\""}
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

  # A knowledge run's outcome as a dot and a word, the model, what it cost and
  # how long it took.
  defp run_tone(%{status: :applied}), do: :on
  defp run_tone(%{status: status}) when status in [:prepared, :responded], do: :busy
  defp run_tone(_run), do: :warn

  defp run_word(%{status: :applied}), do: "Written"
  defp run_word(%{status: :prepared}), do: "Running"
  defp run_word(%{status: :responded}), do: "Checking"
  defp run_word(%{status: :stale}), do: "Never started"
  defp run_word(_run), do: "Not used"

  # What a run cost and how long it took, opposite its summary.
  defp run_meta(%{call: call}) do
    case Enum.reject([call.cost, call.total_ms && CallRun.duration(call.total_ms)], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp commit_href(%{github_repository: repository}, commit) when is_binary(repository),
    do: "https://github.com/#{repository}/commit/#{commit}"

  defp commit_href(_repository, _commit), do: nil

  # The knowledge as formatted text, each link to a path in the repository
  # opened on GitHub at the commit the knowledge was written from.
  defp document(%{knowledge: %{document: text} = knowledge} = item) when is_binary(text) do
    {title, html} =
      KnowledgeDocument.render(text, %{
        github_repository: (item.configured || %{})[:github_repository],
        commit: knowledge[:document_commit]
      })

    %{title: title || "RYKER.md", html: html, text: text}
  end

  defp document(_item), do: nil

  attr(:prompt, :string, required: true)

  # What a run was sent, the way the timeline shows a briefing: the
  # instructions as text, then what the model was given as formatted JSON in
  # the order it was sent, with the exact prompt one click away. A prompt of
  # any other shape shows as it was sent.
  defp prompt_view(assigns) do
    assigns = assign(assigns, :parts, prompt_parts(assigns.prompt))

    ~H"""
    <%= case @parts do %>
      <% {instructions, context} -> %>
        <section class="knowledge-prompt-part">
          <h4>Instructions</h4>
          <p class="knowledge-prompt-instructions">{instructions}</p>
        </section>
        <section class="knowledge-prompt-part">
          <h4>What it was given</h4>
          <pre class="knowledge-run-text">{context}</pre>
        </section>
        <p class="knowledge-copy"><.copy_exact value={@prompt} label="Copy the exact prompt" /></p>
      <% nil -> %>
        <Components.copy_block label="Copy the prompt">
          <pre class="knowledge-run-text">{@prompt}</pre>
        </Components.copy_block>
    <% end %>
    """
  end

  defp prompt_parts(prompt) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(prompt, objects: :ordered_objects),
         %{"instructions" => instructions, "context" => context} = parts
         when map_size(parts) == 2 and is_binary(instructions) <- Map.new(values) do
      {instructions, Jason.encode!(context, pretty: true)}
    else
      _other -> nil
    end
  end

  attr(:value, :string, required: true)
  attr(:label, :string, required: true)

  # Copies the exact text a part shows formatted.
  defp copy_exact(assigns) do
    ~H"""
    <button type="button" class="ui-button secondary knowledge-copy-button" data-copy-value={@value}>
      <Components.icon name={:copy} />{@label}<span
        class="sr-only"
        data-copy-status
        aria-live="polite"
      ></span>
    </button>
    """
  end

  defp run_note(%{status: :applied, dropped: count}) when is_integer(count) and count > 0,
    do:
      "Ryker left out #{plural(count, "path or command", "paths or commands")} it could not find in the repository."

  defp run_note(%{status: :rejected, result: result}) when is_binary(result),
    do: "The answer did not match what Ryker asked for, so Ryker did not use it."

  defp run_note(%{status: :rejected}), do: "The run ended before the model answered."
  defp run_note(_run), do: nil

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

  @doc "A repository's page as the route hands it to the shell, under its name."
  @spec detail_html(map(), DateTime.t()) :: iodata()
  def detail_html(item, now \\ DateTime.utc_now()),
    do: Safe.to_iodata(detail(%{__changed__: nil, item: item, now: now}))

  attr(:item, :map, required: true)
  attr(:now, :any, required: true)

  # Its state first, then what needs a person and the buttons that fix it,
  # the knowledge every task here starts from with how it was written and
  # where the repository is used, GitHub's side, the code Ryker last used, and
  # removing it last.
  defp detail(assigns) do
    item = assigns.item

    assigns =
      assign(assigns,
        repository: item.configured || %{},
        state: state(item),
        problem: problem(item),
        knowledge: item[:knowledge],
        document: document(item),
        runs: Map.get(item, :knowledge_runs, [])
      )

    ~H"""
    <div class="repository-page">
      <Kit.status_line id="repository-state" state={@state}>
        <span :for={fact <- status_facts(@item, @now)}>{fact}</span>
      </Kit.status_line>
      <Kit.section_card :if={@problem} id="repository-attention" title="What to do" lede={@problem}>
        <:actions :if={retry?(@item) or add_again?(@item)}>
          <button
            :if={retry?(@item)}
            type="button"
            class="ui-button primary"
            phx-click="retry-github-onboarding"
            phx-value-repository={@item.ref}
            phx-disable-with="Retrying…"
          >Retry setup</button>
          <button
            :if={add_again?(@item)}
            type="button"
            class="ui-button primary"
            phx-click="add-repository-again"
            phx-value-repository={@item.ref}
            phx-disable-with="Adding…"
          >Add it again</button>
        </:actions>
      </Kit.section_card>
      <Kit.section_card
        id="repository-knowledge"
        title="Knowledge"
        lede="What Ryker knows about this repository, how a model wrote it, and where it is used. Every task here starts from it, and nothing is written to the repository."
      >
        <:actions :if={refreshable?(@item)}>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="confirm-settings-action"
            phx-value-action="refresh-knowledge"
            phx-value-ref={@item.ref}
          >Refresh knowledge</button>
        </:actions>
        <dl :if={@repository[:onboarding_state]} class="kit-facts">
          <.fact label="Written">
            {knowledge(@knowledge)}<ShortTime.time
              :if={@knowledge[:document_at]}
              at={@knowledge.document_at}
              now={@now}
              prefix=", "
            /><span :if={writing?(@knowledge)}> · being rewritten now</span>
          </.fact>
          <.fact :if={@knowledge[:reason]} label="Why">{@knowledge.reason}</.fact>
          <.fact :if={@knowledge[:next_check_at]} label="Checks">
            <ShortTime.time
              :if={@knowledge.checked_at}
              at={@knowledge.checked_at}
              now={@now}
              prefix="Last "
            /><span :if={@knowledge.checked_at}>, next </span><ShortTime.time
              at={@knowledge.next_check_at}
              now={@now}
              prefix={if @knowledge.checked_at, do: nil, else: "Next "}
            />
          </.fact>
          <.fact :if={knowledge_problem(@item)} label="Last try">
            <Kit.state tone={:warn} word="Failed" /> {knowledge_problem(@item)}
          </.fact>
        </dl>
        <div :if={@document} class="kit-rows">
          <Components.disclosure
            id="repository-knowledge-document"
            label={@document.title}
            kind={:source}
            class="knowledge-document-row"
          >
            <:meta>{CallRun.estimated_tokens(@document.text)}</:meta>
            <div id="repository-knowledge-text" class="markdown-preview knowledge-document">
              {@document.html}
            </div>
            <p class="knowledge-copy">
              <.copy_exact value={@document.text} label="Copy the Markdown" />
            </p>
          </Components.disclosure>
        </div>
        <Kit.card_part
          :if={@runs != []}
          id="repository-knowledge-runs"
          title="How it was written"
          lede="Each time a model read the code to write it, newest first."
        >
          <div class="kit-rows">
            <Components.disclosure
              :for={run <- @runs}
              id={"knowledge-run-" <> run.id}
              label={run_word(run)}
              kind={:source}
              class="knowledge-run"
            >
              <:label_content>
                <span class="knowledge-run-summary">
                  <Kit.state tone={run_tone(run)} word={run_word(run)} />
                  <ShortTime.time at={run.at} now={@now} />
                  <span :if={run.call.target} class="knowledge-run-model">
                    {CallRun.model_words(run.call.target)}
                  </span>
                </span>
              </:label_content>
              <:meta :if={run_meta(run)}>{run_meta(run)}</:meta>
              <p :if={run_note(run)} class="knowledge-run-note">{run_note(run)}</p>
              <CallRun.table run={run.call}>
                <:fact :if={run.commit} label="Code">
                  <a
                    :if={commit_href(@repository, run.commit)}
                    href={commit_href(@repository, run.commit)}
                    target="_blank"
                    rel="noopener noreferrer"
                  >{short(run.commit)}</a><span :if={!commit_href(@repository, run.commit)}>{short(
                    run.commit
                  )}</span>
                </:fact>
              </CallRun.table>
              <div :if={run.prompt || run.result} class="kit-rows knowledge-run-parts">
                <Components.disclosure
                  :if={run.prompt}
                  id={"knowledge-run-" <> run.id <> "-prompt"}
                  label="Prompt sent"
                  kind={:source}
                >
                  <:meta>{CallRun.estimated_tokens(run.prompt)}</:meta>
                  <.prompt_view prompt={run.prompt} />
                </Components.disclosure>
                <Components.disclosure
                  :if={run.result}
                  id={"knowledge-run-" <> run.id <> "-answer"}
                  label="The model's answer"
                  kind={:source}
                >
                  <:meta>{CallRun.estimated_tokens(run.result)}</:meta>
                  <Components.copy_block label="Copy the answer">
                    <pre class="knowledge-run-text">{run.result}</pre>
                  </Components.copy_block>
                </Components.disclosure>
              </div>
            </Components.disclosure>
          </div>
        </Kit.card_part>
        <Kit.card_part
          id="repository-use"
          title="Where it is used"
          lede="Channels choose environments, so work here comes from the channels, schedules and conversations of its environments."
        >
          <dl class="kit-facts">
            <.fact label="Environments">
              <%= if @item.in_environments == [] do %>
                None yet, so no channel's work can use it.
                <a href="/environments">Add it to an environment</a>
              <% else %>
                <%!-- Each name but the last carries its comma, so no space
                ever comes before one. --%>
                <%= for {environment, comma} <- with_commas(@item.in_environments) do %>
                  <a href={Paths.edit_environment(environment.ref)}>{environment.name}</a>{comma}
                <% end %>
              <% end %>
            </.fact>
            <.fact label="Channels">{count(@item.channels, "channel", "channels")}</.fact>
            <.fact label="Schedules">{count(@item.schedules, "schedule", "schedules")}</.fact>
            <.fact label="Tasks">
              {count(@item.sessions, "task", "tasks")}<span> · </span><a href={
                Paths.query("/activity", %{"repository" => @item.ref})
              }>See its requests</a>
            </.fact>
            <.fact :if={@item.publications > 0} label="Pull requests">
              {plural(@item.publications, "pull request", "pull requests")} opened by Ryker
            </.fact>
          </dl>
        </Kit.card_part>
      </Kit.section_card>
      <Kit.section_card
        :if={@repository[:github_repository] || Map.has_key?(@repository, :github_permissions)}
        id="repository-github"
        title="GitHub"
        lede="What the Ryker GitHub App may do in this repository, and the events GitHub sends Ryker from it."
      >
        <dl class="kit-facts">
          <.fact :if={@repository[:github_repository]} label="Repository">
            <a
              href={"https://github.com/" <> @repository.github_repository}
              target="_blank"
              rel="noopener noreferrer"
            >{@repository.github_repository}</a>
          </.fact>
          <.fact label="Access">{access(@repository[:github_access])}</.fact>
          <.fact :if={Map.has_key?(@repository, :github_permissions)} label="Permissions">
            {permissions(@repository.github_permissions)}
          </.fact>
          <.fact :if={@repository[:action_grants] not in [nil, []]} label="Allowed actions">
            {Enum.map_join(@repository.action_grants, ", ", &String.replace(&1, "_", " "))}
          </.fact>
          <.fact :if={is_map(@repository[:github_health])} label="Events">
            {events(@repository.github_health)}<ShortTime.time
              :if={@repository.github_health.last_event_at}
              at={@repository.github_health.last_event_at}
              now={@now}
              prefix=", last received "
            />
          </.fact>
        </dl>
      </Kit.section_card>
      <Kit.section_card
        id="repository-code"
        title="Code"
        lede="The code Ryker's last task here worked from, as that task recorded it. It is not a live check of GitHub."
      >
        <dl class="kit-facts">
          <.fact label="Last used">
            <%= if @item.freshness do %>
              <strong>{short(@item.freshness.resolved_revision || "")}</strong>
              from {branch(@item.freshness.requested_revision)}<ShortTime.time
                :if={parse(@item.freshness.fetched_at)}
                at={parse(@item.freshness.fetched_at)}
                now={@now}
                prefix=", fetched "
              />
            <% else %>
              None yet. It appears after Ryker's first task in this repository.
            <% end %>
          </.fact>
        </dl>
      </Kit.section_card>
      <Kit.remove_card
        :if={removable?(@item)}
        id="remove-repository"
        title="Remove repository"
        text={removal(@item).text}
        phx-click="confirm-settings-action"
        phx-value-action="remove-repository"
        phx-value-ref={@item.ref}
      />
    </div>
    """
  end

  # The state's own facts: while the repository is set up, the step and since
  # when. Everything else has its card.
  defp status_facts(%{configured: %{github_bound: false}}, _now), do: []

  defp status_facts(%{configured: %{onboarding_state: onboarding} = repository}, now)
       when onboarding in @setting_up,
       do: meta(%{configured: repository}, now) |> Enum.reject(&is_nil/1)

  defp status_facts(_item, _now), do: []

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

  defp with_commas(items),
    do: Enum.zip(items, List.duplicate(",", max(length(items) - 1, 0)) ++ [""])

  defp count(0, _one, _many), do: "None"
  defp count(count, one, many), do: plural(count, one, many)

  defp access(:available), do: "Available"
  defp access(:suspended), do: "Suspended in GitHub"
  defp access(:removed), do: "Removed in GitHub"
  defp access(_unknown), do: "Not recorded"

  # Who wrote the knowledge Work is briefed with, and from which commit.
  defp knowledge(%{document_by: :outline, document_commit: commit}),
    do: "An outline from the file list at #{short(commit)}; a model could not finish reading it"

  defp knowledge(%{document_by: :model, document_commit: commit}),
    do: "By a model from #{short(commit)}"

  defp knowledge(_knowledge), do: "Not yet"

  defp short(commit), do: String.slice(commit, 0, 7)

  # The branch a task asked for, as people name it: main, not refs/heads/main.
  defp branch("refs/heads/" <> name), do: name
  defp branch(revision) when is_binary(revision), do: revision
  defp branch(_none), do: "its default branch"

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
