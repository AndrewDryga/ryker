defmodule Ryker.ControlPlane.RepositoryImport do
  @moduledoc """
  Adding repositories the connected GitHub App can reach, on the
  Repositories page: find them, pick them, add them. The page shows it only
  while the GitHub App works; otherwise its status line says how to fix that.

  The panel is a disclosure the page's "Add repositories" action opens. It
  starts open while nothing is added yet, and the result of the last import
  is said inside it, where the person who added them is looking. An added
  repository joins the default environment, which Ryker creates as Default
  when there is none, and the panel says so.
  """
  use Phoenix.Component

  alias Ryker.ControlPlane.Components

  attr(:view, :map, required: true)
  attr(:repositories, :list, required: true)
  attr(:discovery, :any, default: :idle)
  attr(:notice, :any, default: nil, doc: "{tone, message} from the last import, or nil")

  def repository_import(assigns) do
    assigns =
      assign(assigns, open: assigns.view.snapshot.repositories == [])

    ~H"""
    <details id="add-repositories" class="repository-import" open={@open}>
      <summary>
        <span class="repository-import-title">Add repositories</span>
        <span class="repository-import-lede">
          Import repositories the connected GitHub App can reach. Each one joins the default
          environment, where new channels work.
        </span>
      </summary>
      <div class="repository-import-body">
        <Components.form_feedback
          :if={@notice}
          id="repository-import-notice"
          message={elem(@notice, 1)}
          tone={elem(@notice, 0)}
        />
        <button
          :if={@discovery == :idle}
          type="button"
          class="ui-button secondary"
          phx-click="discover-github-repositories"
          phx-disable-with="Finding repositories…"
        >Find repositories</button>
        <div
          :if={@discovery == :complete && @repositories == []}
          class="repository-discovery-result"
        >
          <div>
            <strong>No repositories found</strong>
            <p>Give the GitHub App access to at least one repository, then try again.</p>
          </div>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="discover-github-repositories"
            phx-disable-with="Checking again…"
          >Try again</button>
        </div>
        <div
          :if={match?({:error, _}, @discovery)}
          class="repository-discovery-result repository-discovery-error"
        >
          <Components.form_feedback
            message={elem(@discovery, 1)}
            tone={:error}
            class="repository-discovery-feedback"
          />
          <div class="repository-discovery-actions">
            <button
              type="button"
              class="ui-button secondary"
              phx-click="discover-github-repositories"
              phx-disable-with="Trying again…"
            >Try again</button>
            <.link navigate="/integrations/github" class="ui-button secondary">
              Review GitHub connection
            </.link>
          </div>
        </div>
        <form :if={@repositories != []} phx-submit="import-github-repositories">
          <label class="repository-search">
            <span>Search {length(@repositories)} repositories</span><input
              id="repository-search"
              type="search"
              placeholder="Owner or repository name"
              phx-hook="RepositorySearch"
            />
          </label>
          <ul>
            <li :for={repository <- @repositories} data-repository-name={repository.full_name}>
              <label><input
                type="checkbox"
                name="repository_ids[]"
                value={repository.repository_id}
                checked={!repository.already_present}
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
            <button class="ui-button secondary" type="submit" name="import_mode" value="selected">
              Add selected
            </button>
            <button class="ui-button primary" type="submit" name="import_mode" value="all">Add all {Enum.count(
              @repositories,
              &(!&1.already_present)
            )}</button>
          </div>
        </form>
      </div>
    </details>
    """
  end
end
