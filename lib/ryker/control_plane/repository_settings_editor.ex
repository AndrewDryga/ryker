defmodule Ryker.ControlPlane.RepositorySettingsEditor do
  @moduledoc """
  One repository automation section, with its own draft and save outcome.
  Background reads advance the revision only while this section's saved
  values are unchanged. Other sections can save without discarding this one.
  """
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, FormDraft, Kit}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    latest = values(assigns.section, assigns.repository)

    socket =
      assign(socket,
        current_values: latest,
        current_revision: assigns.repository.settings_revision
      )

    cond do
      not Map.has_key?(socket.assigns, :draft) ->
        {:ok, reset(socket)}

      socket.assigns.confirm and
          assigns.repository.settings_revision != socket.assigns.expected_revision ->
        {:ok, assign(socket, confirm: false, conflict: true, error: conflict_message())}

      latest == socket.assigns.baseline ->
        {:ok, assign(socket, expected_revision: assigns.repository.settings_revision)}

      socket.assigns.dirty ->
        {:ok, assign(socket, conflict: true, error: conflict_message())}

      true ->
        {:ok, reset(socket)}
    end
  end

  defp reset(%{assigns: %{current_values: nil}} = socket), do: socket

  defp reset(socket) do
    %{current_values: baseline, current_revision: revision} = socket.assigns

    assign(socket,
      baseline: baseline,
      draft: baseline,
      expected_revision: revision,
      dirty: false,
      confirm: false,
      conflict: false,
      error: nil,
      saved: false
    )
  end

  defp values(:issue_actions, repository),
    do: %{"enabled" => to_string(repository.github_issue_actions)}

  defp values(:issue_triage, repository),
    do: %{
      "enabled" => to_string(repository.github_issue_triage),
      "labels" => to_string(repository.github_triage_labels)
    }

  defp values(:approvals, repository), do: %{"enabled" => to_string(repository.approvals_allowed)}

  defp values(:ci_repair, repository),
    do: %{"policy" => to_string(repository.github_ci_repair)}

  @impl true
  def handle_event("change", params, socket), do: {:noreply, put_draft(socket, params)}

  def handle_event("save", params, socket),
    do: {:noreply, socket |> put_draft(params) |> submit()}

  def handle_event("cancel-approvals", _params, socket),
    do: {:noreply, assign(socket, confirm: false)}

  def handle_event(
        "confirm-approvals",
        _params,
        %{assigns: %{section: :approvals, confirm: true}} = socket
      ),
      do: {:noreply, socket |> assign(confirm: false) |> save()}

  def handle_event("confirm-approvals", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("restore", kept, %{assigns: %{dirty: false}} = socket) do
    case FormDraft.read(kept, socket.assigns.baseline) do
      {:ok, params, revision} ->
        restored = put_draft(socket, params)

        cond do
          not restored.assigns.dirty ->
            {:reply, %{restored: false}, socket}

          revision == :current ->
            {:reply, %{restored: true}, restored}

          true ->
            {:reply, %{restored: true},
             assign(restored,
               baseline: :unknown,
               expected_revision: revision,
               conflict: true,
               error: conflict_message()
             )}
        end

      :error ->
        {:reply, %{restored: false}, socket}
    end
  end

  def handle_event("restore", _kept, socket), do: {:reply, %{restored: false}, socket}

  defp put_draft(socket, params) do
    keys = Map.keys(socket.assigns.draft)
    submitted = Map.take(params, keys)
    draft = Map.merge(socket.assigns.draft, submitted)

    assign(socket,
      confirm: false,
      draft: draft,
      dirty: draft != socket.assigns.baseline,
      saved: false,
      error: if(socket.assigns.conflict, do: socket.assigns.error)
    )
  end

  defp submit(
         %{
           assigns: %{
             section: :approvals,
             dirty: true,
             conflict: false,
             draft: %{"enabled" => "true"}
           }
         } = socket
       ),
       do: assign(socket, confirm: true)

  defp submit(socket), do: save(socket)

  defp save(%{assigns: %{section: :approvals, draft: %{"enabled" => value}}} = socket)
       when value not in ["true", "false"],
       do: assign(socket, error: "Choose whether Ryker may approve pull requests.")

  defp save(%{assigns: %{conflict: true}} = socket), do: socket
  defp save(%{assigns: %{dirty: false}} = socket), do: socket

  defp save(socket) do
    %{section: section, draft: draft, ref: ref, expected_revision: revision} = socket.assigns
    attributes = section |> attributes(draft) |> Map.put(:ref, ref)

    case socket.assigns.save.(attributes, revision) do
      {:ok, snapshot} ->
        repository = saved_record(snapshot, section, ref)
        baseline = values(section, repository)
        send(self(), :repository_settings_saved)

        assign(socket,
          baseline: baseline,
          current_values: baseline,
          current_revision: snapshot.installation.revision,
          draft: baseline,
          dirty: false,
          saved: true,
          error: nil,
          expected_revision: snapshot.installation.revision
        )

      {:error, {:settings_conflict, snapshot}} ->
        save_conflict(socket, snapshot)

      {:error, :settings_forbidden} ->
        assign(socket, :error, "This console is not allowed to change settings.")

      {:error, _reason} ->
        assign(
          socket,
          :error,
          "These settings could not be saved. Your choices are kept; try again."
        )
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      assign(
        socket,
        :error,
        "Ryker could not reach its settings. Your choices are kept; try again."
      )
  end

  # The refusal already carries the latest values. Reset must use them even
  # before the parent's debounced refresh, and must never revive a removed repo.
  defp save_conflict(socket, snapshot) do
    case saved_record(snapshot, socket.assigns.section, socket.assigns.ref) do
      nil ->
        assign(socket,
          current_values: nil,
          current_revision: snapshot.installation.revision,
          conflict: true,
          error: "This repository is no longer added. Your choices have not been saved."
        )

      repository ->
        assign(socket,
          current_values: values(socket.assigns.section, repository),
          current_revision: snapshot.installation.revision,
          conflict: true,
          error: conflict_message()
        )
    end
  end

  defp saved_record(snapshot, :approvals, ref),
    do: Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref))

  defp saved_record(snapshot, _section, ref),
    do: Enum.find(snapshot.repositories, &(&1.ref == ref))

  defp attributes(:approvals, draft), do: %{allowed: draft["enabled"] == "true"}

  # Keep form values as supplied for Settings' changeset to validate. Never
  # turn an unexpected checkbox value into a silent false, or accept a ref
  # or another section's attributes from the browser.
  defp attributes(:issue_actions, draft), do: %{github_issue_actions: draft["enabled"]}

  defp attributes(:issue_triage, draft),
    do: %{github_issue_triage: draft["enabled"], github_triage_labels: draft["labels"]}

  defp attributes(:ci_repair, draft), do: %{github_ci_repair: draft["policy"]}

  defp conflict_message do
    "Saved settings changed while you were editing. Your choices are kept. " <>
      "Use saved settings to review the latest values before editing again."
  end

  defp title(:approvals), do: "Pull request approvals"
  defp title(:issue_actions), do: "Issue actions"
  defp title(:issue_triage), do: "Issue triage"
  defp title(:ci_repair), do: "Auto-fix CI"

  defp lede(:approvals), do: "Choose what Ryker can submit when it reviews a pull request."
  defp lede(:issue_actions), do: "Let repository writers start work from a GitHub issue."
  defp lede(:issue_triage), do: "Review new issues with the code and related reports for context."
  defp lede(:ci_repair), do: "Fix reproducible failures and push the changes to the same PR."

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        enabled: assigns.draft["enabled"] == "true",
        labels: assigns.draft["labels"] == "true",
        policy: assigns.draft["policy"]
      )

    ~H"""
    <div id={@id}>
      <Kit.section_card
        id={@card_id}
        title={title(@section)}
        lede={lede(@section)}
        class="repository-settings"
      >
        <form
          id={"#{@id}-form"}
          class="settings-form"
          phx-change="change"
          phx-submit="save"
          phx-target={@myself}
          data-dirty={to_string(@dirty)}
          data-draft={"repository:#{@ref}:#{@section}"}
          data-revision={@expected_revision}
          data-baseline={FormDraft.digest(@baseline)}
        >
          <div :if={@section == :approvals} class="settings-field settings-choice">
            <input type="hidden" name="enabled" value="false" />
            <label class="settings-option" for={"#{@id}-enabled"}>
              <input
                id={"#{@id}-enabled"}
                type="checkbox"
                name="enabled"
                value="true"
                checked={@enabled}
              />
              <span>
                <strong>Allow Ryker to approve pull requests</strong>
                <small>An approval can count toward branch protection. With this off, Ryker can still comment and request changes.</small>
              </span>
            </label>
          </div>
          <div :if={@section == :issue_actions} class="settings-field settings-choice">
            <input type="hidden" name="enabled" value="false" />
            <label class="settings-option" for={"#{@id}-enabled"}>
              <input
                id={"#{@id}-enabled"}
                type="checkbox"
                name="enabled"
                value="true"
                checked={@enabled}
              />
              <span>
                <strong>Show quick actions on new issues</strong>
                <small>Add “Make a plan” and “Build this” links. Writers sign in and confirm before work starts.</small>
              </span>
            </label>
            <p :if={not @repository.github_issue_actions_ready} class="repository-setup-note">
              <strong>GitHub sign-in is required.</strong>
              <a href="/integrations/github#github-action-sign-in">Set up sign-in</a>
              to make these links usable.
            </p>
          </div>
          <div :if={@section == :issue_triage} class="settings-field settings-choice">
            <input type="hidden" name="enabled" value="false" />
            <label class="settings-option" for={"#{@id}-enabled"}>
              <input
                id={"#{@id}-enabled"}
                type="checkbox"
                name="enabled"
                value="true"
                checked={@enabled}
              />
              <span>
                <strong>Triage issues from repository writers</strong>
                <small>Automatically triage reports opened and updated by people with Write access. A writer can choose “Triage this issue” on any report.</small>
              </span>
            </label>
            <input type="hidden" name="labels" value="false" />
            <label class="settings-option" for={"#{@id}-labels"}>
              <input
                id={"#{@id}-labels"}
                type="checkbox"
                name="labels"
                value="true"
                checked={@labels}
              />
              <span>
                <strong>Apply labels during triage</strong>
                <small>Choose from existing labels. Keep labels added by people.</small>
              </span>
            </label>
            <p class="settings-help repository-settings-note">
              Older issues are indexed without comments. Use “Triage this issue” to review one.
              Issues are never closed automatically.
            </p>
          </div>
          <fieldset
            :if={@section == :ci_repair}
            class="settings-field settings-choice repository-ci-choices"
          >
            <legend>Automatically repair</legend>
            <label
              :for={
                {value, label, help} <- [
                  {"off", "Off", "Fix CI only when someone asks."},
                  {"own", "Ryker’s PRs only", "Automatically fix PRs opened by Ryker."},
                  {"all", "All PRs in this repository",
                   "Include PRs opened by people. Forks are excluded."}
                ]
              }
              class="settings-option"
              for={"#{@id}-#{value}"}
            >
              <input
                id={"#{@id}-#{value}"}
                type="radio"
                name="policy"
                value={value}
                checked={@policy == value}
              />
              <span><strong>{label}</strong><small>{help}</small></span>
            </label>
            <p class="settings-help repository-settings-note">
              Up to two repair rounds until CI passes. Ryker never merges the PR.
              Add <code>ryker:no-ci-fix</code> to stop automatic repairs, including work in progress.
              Remove it to check CI again.
            </p>
          </fieldset>
          <Components.form_feedback :if={@error} message={@error} tone={:error} />
          <div class="settings-actions">
            <button
              type="submit"
              class="ui-button primary"
              disabled={not @dirty or @conflict}
              phx-disable-with="Saving…"
            >Save changes</button>
            <button
              :if={@dirty and not is_nil(@current_values)}
              type="button"
              class="ui-button secondary"
              phx-click="reset"
              phx-target={@myself}
            >
              {if @conflict, do: "Use saved settings", else: "Discard changes"}
            </button>
            <Components.form_feedback
              :if={@saved}
              message="Saved"
              tone={:success}
              class="repository-saved"
            />
            <span :if={@dirty and is_nil(@error)} class="settings-help" role="status">Unsaved changes</span>
          </div>
        </form>
      </Kit.section_card>
      <Kit.confirm_modal
        :if={@confirm}
        id="confirm-approvals"
        title={"Allow Ryker to approve PRs in #{@repository.github_repository}?"}
        text="If branch protection counts the Ryker App’s review, an approval from Ryker can satisfy a required review."
        label="Allow PR approvals"
        cancel="cancel-approvals"
        target={@myself}
        phx-target={@myself}
        phx-click="confirm-approvals"
        pending="Saving…"
        tone={:primary}
      />
    </div>
    """
  end
end
