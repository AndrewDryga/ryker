defmodule Ryker.ControlPlane.EnvironmentsPage do
  @moduledoc """
  Environments at /environments: where Ryker works.

  One Kit row per environment says what it holds, its repositories in order
  (the first takes the changes) and its Emisar account, and who chooses it.
  The default comes first and says so. A row's name and Edit open its editor
  in place (`EnvironmentEditor`); Use as default moves the default in one
  save; Remove asks first, and a removal the settings refuse names who still
  uses the environment. The LiveView runs every write; this only renders.
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
        query: query,
        rows: Enum.filter(environments, &matches?(&1, query, snapshot))
      )

    ~H"""
    <div class="environments-page">
      <Kit.toolbar count={Integrations.count(length(@environments), "environment")}>
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
      <Kit.empty
        :if={@environments == []}
        title="No environments yet"
        text="Adding a repository creates the Default environment. You can also add one yourself with Add an environment."
      />
      <Kit.empty
        :if={@environments != [] and @rows == []}
        title={"No environments match “#{@query}”."}
        text="Try another name or clear the search."
      />
      <.live_component
        :if={@edit == "new"}
        module={EnvironmentEditor}
        id="environment-editor-new"
        ref="new"
        view={@view}
      />
    </div>
    """
  end

  @doc "The page's own action: adding an environment opens the editor below the list."
  def add(assigns) do
    ~H"""
    <.link patch="/environments?edit=new" class="ui-button secondary">
      <Components.icon name={:plus} />Add an environment
    </.link>
    """
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
