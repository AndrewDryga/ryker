defmodule Ryker.ControlPlane.RepositoryImport do
  @moduledoc """
  Adding repositories the connected GitHub App can reach, on a page of its
  own (`/repositories/new`, Andrew, 2026-09-27: an add form opened in place
  "blends into the content"): pick them, add them. The page shows the form
  only while the GitHub App works; otherwise its status line says how to fix
  that.

  The list loads when the page opens, without holding the page while GitHub
  answers, and the page's Refresh loads it again (Andrew, 2026-09-27: "you
  can load list of repos on load and have button to refresh the list when
  needed"); nothing has to be pressed before anything is listed.

  An import that adds everything chosen returns to the list, which says what
  was added; one that adds nothing, or not everything, stays here and says
  why. An added repository joins the default environment, which Ryker
  creates as Default when there is none; the page's description says so.
  """
  use Phoenix.Component

  alias Ryker.ControlPlane.{Components, Kit}

  attr(:view, :map, required: true)
  attr(:repositories, :list, required: true)

  attr(:discovery, :any,
    default: :idle,
    doc: ":idle before it starts, :loading, :complete, or {:error, message}"
  )

  attr(:notice, :any, default: nil, doc: "{tone, message} from the last import, or nil")

  def repository_import(assigns) do
    assigns =
      assign(assigns,
        loading: assigns.discovery in [:idle, :loading],
        addable: Enum.count(assigns.repositories, &(!&1.already_present))
      )

    ~H"""
    <div id="add-repositories" class="repository-import">
      <div class="repository-import-body">
        <Components.form_feedback
          :if={@notice}
          id="repository-import-notice"
          message={elem(@notice, 1)}
          tone={elem(@notice, 0)}
        />
        <Kit.empty
          :if={@loading and @repositories == []}
          id="repository-discovery-loading"
          variant={:hint}
          icon={:repository}
          title="Loading repositories from GitHub…"
          text="Ryker asks the GitHub App which repositories it can reach."
        />
        <Kit.empty
          :if={@discovery == :complete and @repositories == []}
          id="repository-discovery-empty"
          variant={:hint}
          icon={:repository}
          title="No repositories found"
          text="Give the GitHub App access to at least one repository on GitHub, then refresh."
        />
        <div :if={match?({:error, _}, @discovery)} class="repository-discovery-error">
          <Components.form_feedback message={elem(@discovery, 1)} tone={:error} />
          <.link navigate="/integrations/github" class="ui-button secondary">
            Review GitHub connection
          </.link>
        </div>
        <%!-- Nothing starts ticked, and the add button counts the choice: 37
        ticked rows meant unticking 32 to choose 5 (Andrew, 2026-09-26). --%>
        <form
          :if={@repositories != []}
          id="repository-picker"
          phx-submit="import-github-repositories"
          phx-hook="RepositoryPicker"
        >
          <label class="repository-search">
            <span>Search {length(@repositories)} repositories</span><input
              id="repository-search"
              type="search"
              placeholder="Owner or repository name"
              data-repository-search
            />
          </label>
          <div class="repository-select-all">
            <button type="button" class="ui-button quiet" data-repository-select="all">
              Select all shown
            </button>
            <button type="button" class="ui-button quiet" data-repository-select="none">
              Select none
            </button>
          </div>
          <ul>
            <li :for={repository <- @repositories} data-repository-name={repository.full_name}>
              <label><input
                type="checkbox"
                name="repository_ids[]"
                value={repository.repository_id}
                disabled={repository.already_present}
              />
              <strong>{repository.full_name}</strong><span>{if repository.already_present,
                do: "Already added",
                else: repository.default_branch}</span></label>
            </li>
          </ul>
          <label class="member-choice"><input
            type="checkbox"
            name="auto_add_repositories"
            value="true"
            checked={@view.snapshot.github.auto_add_repositories}
          /> Add new repositories automatically when the app gets access to them</label>
          <div class="repository-import-actions">
            <button
              class="ui-button primary"
              type="submit"
              name="import_mode"
              value="selected"
              data-repository-add-selected
              disabled
            >
              Add 0 selected
            </button>
            <button
              :if={@addable > 0}
              class="ui-button secondary"
              type="submit"
              name="import_mode"
              value="all"
            >Add all {@addable}</button>
            <.link patch="/repositories" class="ui-button secondary">Cancel</.link>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
