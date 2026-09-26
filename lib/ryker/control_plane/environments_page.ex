defmodule Ryker.ControlPlane.EnvironmentsPage do
  @moduledoc """
  Environments at /environments: where Ryker works.

  One Kit row per environment says what it holds, how many repositories and
  the default one (a task picks the one it changes) and its Emisar account,
  and who chooses it. The default comes first and says so. A row's name and
  Edit open its editor in place, under the row (`EnvironmentEditor`); Add an
  environment opens one above the list and, pressed again, closes it. Use as
  default moves the default in one save; Remove asks first, and a removal the
  settings refuse names who still uses the environment. The LiveView runs
  every write; this only renders.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{
    Components,
    EnvironmentEditor,
    Environments,
    Integrations,
    Kit,
    SettingsPage
  }

  attr(:view, :map, required: true, doc: "The settings view")
  attr(:params, :map, default: %{}, doc: "The page's query: q searches, edit opens an editor")
  attr(:confirm, :any, default: nil, doc: "{action, ref} of the question now open, if any")

  def render(assigns) do
    snapshot = assigns.view.snapshot
    environments = Environments.ordered(snapshot.environments)
    query = query(assigns.params)
    edit = edit(assigns.params, environments)

    assigns =
      assign(assigns,
        environments: environments,
        edit: edit,
        # A link to an environment that is gone says so, instead of quietly
        # showing the list as if it had opened.
        missing: is_binary(assigns.params["edit"]) and is_nil(edit),
        query: query,
        rows: Enum.filter(environments, &matches?(&1, query, snapshot))
      )

    ~H"""
    <div class="environments-page">
      <Components.form_feedback
        :if={@missing}
        id="environment-not-found"
        tone={:warning}
        message="That environment was not found. It may have been removed."
      />
      <Kit.counts label="Environments" items={counts(@rows, @query, @view)} />
      <Kit.toolbar>
        <Components.filter_toolbar
          id="environment-search"
          path="/environments"
          label="Search environments"
          placeholder="Search environments"
          query={@query}
          filtered={@query != ""}
          disabled={@environments == []}
        />
      </Kit.toolbar>
      <.live_component
        :if={@edit == "new"}
        module={EnvironmentEditor}
        id="environment-editor-new"
        ref="new"
        view={@view}
      />
      <Kit.entity_list :if={@rows != []} label="Environments">
        <Kit.entity_row
          :for={environment <- @rows}
          id={"environment-" <> environment.ref}
          icon={:grid}
          name={environment.display_name}
          href={"/environments?" <> URI.encode_query(%{"edit" => environment.ref})}
          navigate={true}
          tag={if environment.is_default, do: "Default"}
          text={environment.description}
          meta={meta(environment, @view)}
        >
          <:actions :if={@edit != environment.ref}>
            <.link
              patch={"/environments?" <> URI.encode_query(%{"edit" => environment.ref})}
              class="ui-button secondary"
            >Edit<span class="sr-only">{" " <> environment.display_name}</span></.link>
            <button
              :if={!environment.is_default}
              type="button"
              class="ui-button secondary"
              phx-click="make-default-environment"
              phx-value-ref={environment.ref}
            >Use as default</button>
            <button
              :if={@confirm != {"delete-environment", environment.ref}}
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="delete-environment"
              phx-value-ref={environment.ref}
            >Remove</button>
          </:actions>
          <:details>
            <SettingsPage.confirmation
              :if={@confirm == {"delete-environment", environment.ref}}
              title={"Remove #{environment.display_name}?"}
              text={removal(environment)}
              label="Remove environment"
              phx-click="delete-environment"
              phx-value-ref={environment.ref}
            />
            <.live_component
              :if={@edit == environment.ref}
              module={EnvironmentEditor}
              id={"environment-editor-" <> environment.ref}
              ref={environment.ref}
              view={@view}
            />
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <.first_environment :if={@environments == [] and @edit != "new"} view={@view} />
      <Kit.empty
        :if={@environments != [] and @rows == []}
        title={"No environments match “#{@query}”."}
        text="Try another name or clear the search."
      />
    </div>
    """
  end

  attr(:open, :boolean, default: false, doc: "Whether the editor for a new environment is open")

  @doc """
  The page's own action: adding an environment opens its editor above the
  list, and pressed again closes it.
  """
  def add(assigns) do
    ~H"""
    <.link
      patch={if @open, do: "/environments", else: "/environments?edit=new"}
      class="ui-button secondary"
      aria-expanded={to_string(@open)}
    >
      <Components.icon name={:plus} />Add an environment
    </.link>
    """
  end

  # The page leads with how many environments it lists and, once any channel
  # chose none, how many channels work without code or Emisar.
  defp counts(rows, query, view) do
    without = Map.get(view.environment_channels, nil, 0)

    [
      Kit.list_total(length(rows), {"environment", "environments"}, query != ""),
      without > 0 &&
        %{
          value: without,
          label:
            if(without == 1,
              do: "channel without an environment",
              else: "channels without an environment"
            ),
          href: "/channels"
        }
    ]
    |> Enum.filter(& &1)
  end

  defp meta(environment, view) do
    snapshot = view.snapshot

    Environments.repository_facts(snapshot, environment) ++
      [
        Environments.emisar_fact(snapshot, environment),
        Environments.used_by(
          Map.get(view.environment_channels, environment.ref, 0),
          Enum.count(snapshot.webhook_sources, &(&1.environment_ref == environment.ref))
        )
      ]
  end

  attr(:view, :map, required: true)

  # The first environment comes with the first repository, and a repository
  # needs a working GitHub App: the empty page names the step GitHub's own
  # state says is next.
  defp first_environment(assigns) do
    assigns = assign(assigns, :github, Integrations.github(assigns.view))

    ~H"""
    <Kit.empty title="No environments yet" text={first_step(@github)}>
      <.link navigate={first_action(@github).href} class="ui-button secondary">
        {first_action(@github).label}
      </.link>
    </Kit.empty>
    """
  end

  defp first_step(%{status: status}) do
    first =
      case status do
        :not_set_up -> "Connect GitHub, then add a repository: "
        :broken -> "Repair the GitHub connection, then add a repository: "
        _app_works -> "Add a repository and "
      end

    first <>
      "Ryker creates the Default environment for it. You can also add one yourself with " <>
      "Add an environment."
  end

  defp first_action(%{status: status, action: action}) when status in [:not_set_up, :broken],
    do: action

  defp first_action(_app_works), do: %{label: "Add repositories", href: "/repositories"}

  defp removal(%{is_default: true}),
    do:
      "Its repositories and Emisar account stay. Chat and every conversation without its own " <>
        "environment then work without one until you choose another default."

  defp removal(_environment), do: "Its repositories and Emisar account stay."

  defp query(%{"q" => q}) when is_binary(q), do: q |> String.trim() |> String.slice(0, 200)
  defp query(_params), do: ""

  # Only an environment that is listed, or a new one, opens an editor.
  defp edit(%{"edit" => "new"}, _environments), do: "new"

  defp edit(%{"edit" => ref}, environments) when is_binary(ref),
    do: if(Enum.any?(environments, &(&1.ref == ref)), do: ref)

  defp edit(_params, _environments), do: nil

  defp matches?(_environment, "", _snapshot), do: true

  defp matches?(environment, query, snapshot) do
    query = String.downcase(query)

    [
      environment.display_name,
      environment.description,
      Environments.emisar_name(snapshot, environment)
      | Enum.map(
          environment.repositories,
          &Environments.repository_name(snapshot, &1.repository_ref)
        )
    ]
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), query)))
  end
end
