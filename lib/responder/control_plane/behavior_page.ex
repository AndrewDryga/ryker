defmodule Responder.ControlPlane.BehaviorPage do
  @moduledoc "Human-readable, scoped instructions and their existing lifecycle controls."
  use Phoenix.Component
  import Responder.ControlPlane.Components, except: [status: 1]
  alias Responder.ControlPlane.{BehaviorLibrary, SlackNames}

  def title(:standing_assignment), do: "Standing rules"
  def title(:preference), do: "Preferences"
  def title(:guidance), do: "Guidance"

  # The shell's one-line description under the title. Guidance keeps its
  # authority boundary here, visible, rather than inside the closed help.
  def description(:standing_assignment),
    do: "Instructions that run when a matching event arrives."

  def description(:preference),
    do:
      "Saved choices for how Responder replies and works, scoped to a person, conversation, repository, or workspace."

  def description(:guidance),
    do:
      "Confirmed instructions recalled in relevant conversations. Guidance helps the model; it does not grant permission to act."

  @status_options [
    {"current", "Active & paused"},
    {"all", "All statuses"},
    {"active", "Active"},
    {"disabled", "Paused"},
    {"expired", "Expired"},
    {"archived", "Archived"}
  ]
  @scope_options [
    {"", "All scopes"},
    {"conversation", "Conversation"},
    {"workspace", "Workspace"},
    {"repository", "Repository"},
    {"operator", "Person"}
  ]

  def render(assigns) do
    assigns =
      assign(assigns,
        path: BehaviorLibrary.path(assigns.view.kind),
        status_options: @status_options,
        scope_options: @scope_options
      )

    ~H"""
    <div class="behavior-library">
      <.page_help id={help_id(@view.kind)} label={help_label(@view.kind)}>
        <p>{create_help(@view.kind)}</p>
        <p>Review and confirm the proposed card in that conversation before it takes effect.</p>
        <p>
          Use Pause or Resume to change whether an entry applies. Delete removes it from active use while keeping its history.
        </p>
        <p :if={@view.kind == :guidance}>
          Guidance is recalled when relevant. Use <a href="/instructions">Instructions</a>
          for global or channel defaults supplied on every model turn.
        </p>
        <p><a href="/channels">Slack channels →</a></p>
      </.page_help>
      <.filter_toolbar
        id="behavior-search"
        path={@path}
        label={"Filter #{String.downcase(title(@view.kind))}"}
        placeholder="Search instructions or scope"
        query={@view.params["q"]}
        filtered={filtered?(@view)}
        selects={[
          %{
            id: "behavior-status",
            name: "status",
            label: "Status",
            value: @view.params["status"],
            options: @status_options
          },
          %{
            id: "behavior-scope",
            name: "scope",
            label: "Applies to",
            value: @view.params["scope"],
            options: @scope_options
          }
        ]}
      />
      <.result_count
        :if={@view.total > 0}
        count={@view.total}
        one={noun(@view.kind, 1)}
        many={noun(@view.kind, 2)}
      />
      <div :if={@view.items == []} class="behavior-empty">
        <h2>
          {empty_title(@view)}
        </h2>
        <p>
          {if filtered?(@view),
            do: "Change the filters to see other saved entries.",
            else: empty_help(@view.kind)}
        </p>
        <a
          :if={!filtered?(@view) && Enum.sum(Map.values(@view.counts)) > 0}
          href={@path <> "?status=all"}
        >Show expired and archived entries →</a>
      </div>
      <div class="behavior-entries">
        <article :for={item <- @view.items} id={"behavior-#{item.ref}"} class="behavior-entry">
          <header>
            <h2>{subject(item)}</h2><span class={"ui-status status-#{if item.status == "active", do: "done", else: "quiet"}"}>{status(
              item.status
            )}</span>
          </header>
          <p class="behavior-instruction">{instruction(item)}</p>
          <dl class="behavior-meta">
            <div>
              <dt>Applies to</dt><dd title={item.scope_ref}>{scope(item)}</dd>
            </div>
            <div :if={item.kind == :standing_assignment}>
              <dt>When</dt><dd>{trigger(item.payload)}</dd>
            </div>
            <div :if={item.kind == :standing_assignment && item.payload["source_filter"]}>
              <dt>From</dt><dd>{sender(item.payload["source_filter"])}</dd>
            </div>
            <div :if={item.payload["repository"]}>
              <dt>Repository</dt><dd>{item.payload["repository"]}</dd>
            </div>
            <div>
              <dt>Expires</dt><dd>
                {if item.expires_at, do: timestamp(item.expires_at), else: "No expiry"}
              </dd>
            </div>
            <div>
              <dt>Used</dt><dd>
                {item.use_count} times<span :if={item.last_used_at}> · {timestamp(item.last_used_at)}</span>
              </dd>
            </div>
          </dl>
          <details
            :if={item.kind == :guidance || item.payload["filter"]}
            id={"behavior-#{item.ref}-details"}
          >
            <summary>
              {if item.kind == :guidance, do: "Full guidance", else: "Event conditions"}
            </summary>
            <p :if={item.kind == :guidance} class="behavior-instruction">{item.payload["text"]}</p>
            <pre :if={is_map(item.payload["filter"])}>{Jason.encode!(item.payload["filter"], pretty: true)}</pre>
            <p :if={is_binary(item.payload["filter"])}>{item.payload["filter"]}</p>
          </details>
          <footer>
            <div class="behavior-links">
              <a :if={source_url(item)} href={source_url(item)} rel="noopener noreferrer">Original conversation →</a><span title={
                item.ref
              }>Confirmed {timestamp(item.confirmed_at)}</span>
            </div>
            <div :if={item.status in ["active", "disabled"]} class="action-controls">
              <.action_button
                path={action(item, if(item.status == "active", do: "disabled", else: "active"))}
                label={if item.status == "active", do: "Pause", else: "Resume"}
              />
              <.action_button path={action(item, "deleted")} label="Delete" tone={:danger} />
            </div>
          </footer>
        </article>
      </div>
      <nav :if={@view.pages > 1} class="behavior-pagination" aria-label="Saved instruction pages">
        <a :if={@view.page > 1} href={page_url(@path, @view, @view.page - 1)}>← Previous</a><span>Page {@view.page} of {@view.pages} · {@view.total} entries</span><a
          :if={@view.page < @view.pages}
          href={page_url(@path, @view, @view.page + 1)}
        >Next →</a>
      </nav>
      <section :if={@view.kind == :standing_assignment && @view.items != []} class="behavior-history">
        <h2>Recent rule matches</h2><p :if={@view.runs == []}>No recorded matches for these rules.</p>
        <ol :if={@view.runs != []}>
          <li :for={run <- @view.runs}>
            <time>{timestamp(run.at)}</time><a href={"#behavior-#{run.rule_ref}"}>{rule_title(
              @view.items,
              run.rule_ref
            )}</a><span>{outcome(run)}</span><a
              :if={run.episode_ref}
              href={"/timeline/#{URI.encode_www_form(run.episode_ref)}"}
            >Open timeline →</a>
          </li>
        </ol><p :if={length(@view.runs) == 25} class="muted">
          Latest 25 matches for the rules on this page.
        </p>
      </section>
    </div>
    """
  end

  def subject(%{kind: :preference, payload: payload}), do: label(payload["key"] || "Preference")

  def subject(%{kind: :standing_assignment, payload: payload}),
    do: payload["title"] || trigger(payload)

  def subject(item),
    do:
      item.payload["title"] || item.payload["subject"] || item.payload["task"] || title(item.kind)

  defp instruction(%{kind: :preference, payload: payload}),
    do: label(payload["value"] || "Not recorded")

  defp instruction(%{kind: :guidance, payload: payload}),
    do: payload["summary"] || payload["text"]

  defp instruction(item), do: item.payload["task"]
  defp status("disabled"), do: "Paused"
  defp status(other), do: label(other)

  defp filtered?(view),
    do: view.params["q"] != "" || view.params["scope"] != "" || view.params["status"] != "current"

  defp empty_title(view) do
    cond do
      filtered?(view) ->
        "No matching entries"

      Enum.sum(Map.values(view.counts)) > 0 ->
        "No active or paused #{String.downcase(title(view.kind))}"

      true ->
        "No #{String.downcase(title(view.kind))} yet"
    end
  end

  defp action(item, status), do: "/actions/behavior/#{URI.encode_www_form(item.ref)}/#{status}"

  defp page_url(path, view, page),
    do: path <> "?" <> URI.encode_query(Map.put(view.params, "page", page))

  defp rule_title(items, ref), do: items |> Enum.find(&(&1.ref == ref)) |> subject()
  defp outcome(%{outcome: :pending}), do: "Awaiting routing"
  defp outcome(%{outcome: :superseded}), do: "Replaced by newer input"
  defp outcome(%{action: :ignore}), do: "No response needed"
  defp outcome(%{action: :start_episode}), do: "Started work"
  defp outcome(%{action: :continue_episode}), do: "Continued work"
  defp outcome(%{action: :reply}), do: "Reply selected"
  defp outcome(%{action: :react}), do: "Reaction selected"
  defp outcome(_), do: "Routed"
  defp trigger(%{"source_kind" => kind}), do: label(kind)
  defp trigger(%{"trigger" => trigger}), do: label(trigger)
  defp trigger(_), do: "Source event"
  defp sender("human"), do: "People only"
  defp sender("app"), do: "Apps only"
  defp sender("any"), do: "People and apps"
  defp sender(_), do: "Not recorded"

  defp scope(%{scope_kind: :conversation} = item), do: SlackNames.destination(item.scope_ref)
  defp scope(%{scope_kind: :workspace}), do: "Entire workspace"

  defp scope(%{
         scope_kind: :operator,
         scope_ref: "slack:user:" <> person,
         workspace_ref: "slack:" <> workspace
       }),
       do: SlackNames.name(workspace, person)

  defp scope(%{scope_kind: :operator}), do: "One person"
  defp scope(item), do: item.scope_ref

  defp source_url(%{source_conversation_ref: "control-plane:lab:" <> id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> "/lab/#{id}"
      :error -> nil
    end
  end

  defp source_url(%{source_conversation_ref: "slack:" <> rest, source_message_ref: stamp}) do
    with [team, channel] <- String.split(rest, ":"),
         true <- Regex.match?(~r/\A[A-Z0-9]+\z/, team),
         true <- Regex.match?(~r/\A[A-Z0-9]+\z/, channel),
         true <- is_binary(stamp) && Regex.match?(~r/\A[0-9]+\.[0-9]+\z/, stamp) do
      "https://slack.com/app_redirect?" <>
        URI.encode_query(%{team: team, channel: channel, message_ts: stamp})
    else
      _ -> nil
    end
  end

  defp source_url(_), do: nil

  defp help_id(:standing_assignment), do: "rules-help"
  defp help_id(:preference), do: "preferences-help"
  defp help_id(:guidance), do: "guidance-help"

  defp help_label(:standing_assignment), do: "How to add and manage rules"
  defp help_label(:preference), do: "How to save and manage preferences"
  defp help_label(:guidance), do: "How to add and manage guidance"

  defp noun(:standing_assignment, 1), do: "rule"
  defp noun(:standing_assignment, _), do: "rules"
  defp noun(:preference, 1), do: "preference"
  defp noun(:preference, _), do: "preferences"
  defp noun(:guidance, 1), do: "guidance entry"
  defp noun(:guidance, _), do: "guidance entries"

  defp create_help(:standing_assignment),
    do:
      "Ask Responder in the channel where the rule should apply. Describe which events to watch and what to do—for example, review Terraform plans posted in that channel."

  defp create_help(:preference),
    do:
      "Ask Responder to save your preferred response detail, health-check depth, or response location. Specify whether it applies to you, this conversation, a repository, or the workspace. Response location cannot be repository-scoped."

  defp create_help(:guidance),
    do:
      "Ask Responder to save an instruction or review checklist as guidance. Include where it applies and how long to retain it. To change existing guidance, open its original conversation and request a replacement."

  defp empty_help(:standing_assignment),
    do:
      "No confirmed rules are active in this Responder. Rules from the old responder are not automatically enabled here."

  defp empty_help(:preference),
    do: "No confirmed preferences are active. Responder is using its defaults."

  defp empty_help(:guidance),
    do:
      "No confirmed guidance is active. Ask Responder to remember an instruction to make it available here."
end
