defmodule Ryker.ControlPlane.RelearnPanel do
  @moduledoc """
  The way to relearn a topic Ryker stopped using, on the topic's own page:
  the messages that still exist, searchable and paged, to choose from, and
  the one bound form that relearns the topic from the chosen ones.

  It is a section of the page, never a collapsed disclosure: relearning is
  what a topic Ryker no longer uses needs, and a form under a collapsed
  summary was a primary input hidden behind a click (Andrew's rules,
  2026-09-25).
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components,
    only: [filter_toolbar: 1, form_feedback: 1, pager: 1, timestamp: 1]

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{ConversationMemory, CSRF, Kit, LearningActivity, Paths, SlackMarkdown}
  alias Ryker.ControlPlane.SourceText
  alias Ryker.InspectionRedactor
  alias Ryker.Slack

  @doc """
  The panel for one topic's `preview`. `error` is why the last submission
  was refused, shown beside the form the person chose sources in.
  """
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:error, fn -> nil end)
      |> assign(:sources, sources(assigns.preview))
      |> assign(:submission, submission(assigns.preview))

    ~H"""
    <section class="knowledge-rebuild" id="relearn" aria-label="Relearn this topic">
      <Kit.section_head
        title="Relearn this topic"
        lede="A message Ryker learned this from changed, was removed or expired, so Ryker stopped using it. Choose messages that still exist: Ryker relearns the topic from them alone, keeps its update history and posts nothing to the conversation."
      />
      <p :if={@preview.existing_batch} class="relearn-existing">
        A relearning request already exists ·
        <a href={LearningActivity.path(@preview.existing_batch.id)}>Inspect its progress and attempts →</a>
      </p>
      <p :if={!@preview.eligible?} class="memory-note">{reason(@preview.reason)}</p>
      <div :if={@preview.eligible?}>
        <.filter_toolbar
          id="relearn-search"
          path="/memory/learned#relearn"
          label="Find current source messages"
          name="rebuild_q"
          placeholder="Search messages in this conversation"
          query={Map.get(@preview, :q, "")}
          hidden={[{"item", @preview.topic_id}]}
        />
        <Kit.empty
          :if={@sources == []}
          variant={:hint}
          icon={:search}
          title="No current messages match"
          text="Try another search, or wait for new messages in this conversation."
        />
        <form
          method="post"
          action={@submission.path}
          phx-submit="relearn-sources"
          data-relearn-scope={@submission.action <> ":" <> @submission.resource}
        >
          <input
            type="hidden"
            name="_token"
            value={CSRF.token(@csrf_secret, @submission.action, @submission.resource)}
          />
          <input type="hidden" name="kind" value={@submission.kind} />
          <input type="hidden" name="target" value={@submission.id} />
          <input :for={{name, value} <- @submission.fields} type="hidden" name={name} value={value} />
          <div data-relearn-hidden hidden></div>
          <fieldset>
            <legend>Choose up to 16 messages about this topic</legend>
            <p class="relearn-hint">
              Nothing is selected automatically. Suggested messages are connected to earlier sources;
              check that they still describe this topic. Choose messages from one execution mode.
            </p>
            <p class="relearn-hint" data-relearn-help>
              Without JavaScript and browser storage, selections stay on the current page only.
              Search before selecting messages.
            </p>
            <div class="relearn-selection-tools">
              <span data-relearn-count role="status" aria-live="polite" hidden>0 of 16 selected</span>
              <button type="button" class="ui-button secondary" data-relearn-clear hidden>
                Clear selection
              </button>
            </div>
            <ul class="relearn-sources">
              <li :for={source <- @sources}>
                <label for={"relearn-source-#{source.id}"}>
                  <input
                    id={"relearn-source-#{source.id}"}
                    type="checkbox"
                    name="sources[]"
                    value={source.value}
                    data-relearn-source={source.id}
                  />
                  <span>
                    <span class="relearn-source-meta">
                      <time datetime={DateTime.to_iso8601(source.at)}>{timestamp(source.at)}</time>
                      <%= if source.person do %>
                        <Kit.person person={source.person} />
                      <% else %>
                        <span>{source.actor}</span>
                      <% end %>
                      <span :if={source.mode}>{source.mode}</span>
                      <span :if={source.suggested}>Connected to earlier sources</span>
                    </span>
                  </span>
                </label>
                <div class={[
                  "relearn-excerpt markdown-preview",
                  source.expanded && "relearn-excerpt-clipped"
                ]}>
                  {source.html}
                </div>
                <details :if={source.expanded}>
                  <summary>Read full message</summary>
                  <div class="relearn-full-message markdown-preview">
                    {source.html}
                  </div>
                </details>
                <a
                  :if={source.url}
                  class="relearn-original"
                  href={source.url}
                  rel="noopener noreferrer"
                >Open original message →</a>
                <p :if={source.truncated} class="relearn-hint">
                  This message exceeds the inspection display limit.
                </p>
              </li>
            </ul>
          </fieldset>
          <p :if={@preview.existing_batch} class="relearn-hint">
            Selecting again keeps this request and its past attempts. It grants one additional model start;
            it does not reset the amount already spent.
          </p>
          <.form_feedback :if={@error} id="relearn-error" message={@error} tone={:error} />
          <button type="submit" class="ui-button primary">{@submission.label}</button>
        </form>
        <.pager
          page={@preview.page}
          pages={@preview.pages}
          path={&path(@preview, &1)}
          label="Relearning source pages"
          earlier="← Previous messages"
          later="Next messages →"
          summary={"#{@preview.total} messages"}
        />
      </div>
    </section>
    """
  end

  def resource(id, version, generation), do: "#{id}:#{version}:#{generation}"

  def reselect_resource(id, budget, version, generation),
    do: "#{id}:#{budget}:#{version}:#{generation}"

  def source_value(entry) do
    %{
      "source_input_id" => entry.input_id,
      "revision" => entry.revision,
      "fingerprint" => entry.fingerprint
    }
    |> CanonicalJSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  def reason(:learning_disabled),
    do: "Learning is disabled. Enable the learning worker before requesting relearning."

  def reason(:knowledge_available),
    do: "This topic is available for recall; normal learning can update it."

  def reason(:knowledge_changed), do: "This topic changed. Reload it before choosing sources."

  def reason(:learning_remote_unresolved) do
    "An earlier model execution has not stopped. Relearning must wait for its stop confirmation."
  end

  def reason(:learning_batch_busy),
    do: "This request is still in progress. Inspect its activity before choosing new sources."

  def reason(:knowledge_not_found), do: "This topic no longer exists."

  def reason(:learning_configuration_invalid) do
    "Learning cannot start with its current configuration. Check Learning and Models in Settings before relearning this topic."
  end

  def reason(:knowledge_rebuild_conflict) do
    "This topic or its source access changed. Reload the topic and choose current messages again."
  end

  def reason(:learning_source_stale) do
    "The selected sources are no longer eligible. Choose current messages from this conversation."
  end

  def reason(:learning_mixed_execution_modes) do
    "Choose messages from the same execution mode: either live or shadow. Clear the mixed selection and select again."
  end

  def reason(:token),
    do: "This topic changed since the page was drawn. Reload it and choose current messages."

  def reason(:invalid_learning_rebuild), do: reason(:form)
  def reason(:form), do: "Choose 1 to 16 current messages using the source selector."
  def reason(reason), do: LearningActivity.error(reason)

  defp submission(%{existing_batch: %{id: id, budget_version: budget}} = preview) do
    %{
      kind: "reselect",
      id: id,
      path: "/actions/learning/#{id}/reselect",
      action: "learning:reselect",
      resource: reselect_resource(id, budget, preview.version, preview.generation),
      fields: [
        {"budget_version", budget},
        {"version", preview.version},
        {"generation", preview.generation}
      ],
      label: "Use these messages and grant one more start"
    }
  end

  defp submission(preview) do
    %{
      kind: "relearn",
      id: preview.topic_id,
      path: "/actions/knowledge/#{preview.topic_id}/relearn",
      action: "knowledge:relearn",
      resource: resource(preview.topic_id, preview.version, preview.generation),
      fields: [{"version", preview.version}, {"generation", preview.generation}],
      label: "Relearn from selected messages"
    }
  end

  defp sources(preview) do
    secrets = InspectionRedactor.configured_secrets()
    workspace = Slack.destination_workspace(Map.get(preview, :conversation_ref))

    Enum.map(preview.entries, fn entry ->
      artifact = InspectionRedactor.artifact(entry.content, secrets: secrets, max_bytes: 65_536)

      text =
        case Jason.decode(artifact.text || "{}") do
          {:ok, %{} = content} -> SourceText.from_content(content) || artifact.text
          _ -> artifact.text || "Message text is unavailable."
        end

      %{
        id: entry.input_id,
        value: source_value(entry),
        at: entry.occurred_at,
        url:
          ConversationMemory.source_message(%{
            transport: Map.get(preview, :transport),
            conversation_ref: Map.get(preview, :conversation_ref),
            source_message_ref: entry.source_message_ref
          }),
        # A Slack person reads as every person does; the name cache redacts
        # their name as it keeps it.
        person:
          if(Slack.person_ref?(entry.actor_ref), do: Slack.person(workspace, entry.actor_ref)),
        actor:
          InspectionRedactor.artifact(actor(workspace, entry.actor_ref), secrets: secrets).text,
        mode: mode(Map.get(entry, :execution_mode)),
        suggested: entry.suggested?,
        html: SlackMarkdown.html(text, workspace),
        expanded: String.length(text) > 240,
        truncated: artifact.truncated
      }
    end)
  end

  defp actor(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    ref = ref |> String.replace_prefix("slack:user:", "") |> String.replace_prefix("bot:", "")
    Slack.name(workspace, ref)
  end

  defp actor(_workspace, ref), do: ref

  defp mode(mode) when mode in [:shadow, "shadow"], do: "Shadow mode"
  defp mode(mode) when mode in [:live, "live"], do: "Live mode"
  defp mode(_mode), do: nil

  defp path(preview, page) do
    "/memory/learned?" <>
      Paths.encode_query(%{
        "item" => preview.topic_id,
        "rebuild_q" => Map.get(preview, :q, ""),
        "rebuild_page" => page
      }) <> "#relearn"
  end
end
