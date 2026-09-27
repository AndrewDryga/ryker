defmodule Ryker.ControlPlane.EnvironmentsPage do
  @moduledoc """
  Environments at /environments: where Ryker works.

  One Kit row per environment says what it holds, how many repositories, the
  default one (the one a task changes unless it picks another) and how many
  work only reads, its Emisar account, and who chooses it. The default
  environment comes first and says so. Add an environment and a row's name or
  Edit open its form on a page of its own (`form/1`, `EnvironmentEditor`).
  Use as default moves the default in one save; Remove asks first in a modal,
  and a removal the settings refuse names who still uses the environment.
  The LiveView runs every write; this only renders.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{
    Components,
    EnvironmentEditor,
    Environments,
    Integrations,
    Kit
  }

  alias Ryker.Settings.Environment

  attr(:view, :map, required: true, doc: "The settings view")
  attr(:params, :map, default: %{}, doc: "The page's query: q searches")
  attr(:confirm, :any, default: nil, doc: "{action, ref} of the question now open, if any")

  def render(assigns) do
    snapshot = assigns.view.snapshot
    environments = Environments.ordered(snapshot.environments)
    query = query(assigns.params)

    assigns =
      assign(assigns,
        environments: environments,
        query: query,
        rows: Enum.filter(environments, &matches?(&1, query, snapshot)),
        removing:
          case assigns.confirm do
            {"delete-environment", ref} -> Environments.find(snapshot, ref)
            _other -> nil
          end
      )

    ~H"""
    <div class="environments-page">
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
      <Kit.entity_list :if={@rows != []} label="Environments">
        <Kit.entity_row
          :for={environment <- @rows}
          id={"environment-" <> environment.ref}
          icon={:grid}
          name={environment.display_name}
          href={edit_path(environment.ref)}
          navigate={true}
          tag={if environment.is_default, do: "Default"}
          text={environment.description}
          meta={meta(environment, @view)}
        >
          <:actions>
            <.link
              patch={edit_path(environment.ref)}
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
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="delete-environment"
              phx-value-ref={environment.ref}
            >Remove<span class="sr-only">{" " <> environment.display_name}</span></button>
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
      <.first_environment :if={@environments == []} view={@view} />
      <Kit.empty
        :if={@environments != [] and @rows == []}
        icon={:search}
        title={"No environments match “#{@query}”"}
        text="Try another name or clear the search."
      />
      <Kit.confirm_modal
        :if={@removing}
        id="confirm-delete-environment"
        title={"Remove #{@removing.display_name}?"}
        text={removal(@removing)}
        label="Remove environment"
        cancel="cancel-settings-action"
        phx-click="delete-environment"
        phx-value-ref={@removing.ref}
      />
    </div>
    """
  end

  @doc "The page's own action: Add an environment opens its form on its own page."
  def add(assigns) do
    ~H"""
    <.link patch="/environments/new" class="ui-button secondary">
      <Components.icon name={:plus} />Add an environment
    </.link>
    """
  end

  attr(:view, :map, required: true)
  attr(:ref, :string, default: nil, doc: "The environment it edits; nil adds one")

  @doc """
  The page of one environment's form, adding one (`ref` nil) or editing one.
  An address for an environment that is gone says so instead of an empty form.
  """
  def form(assigns) do
    assigns =
      assign(assigns,
        found:
          is_nil(assigns.ref) or not is_nil(Environments.find(assigns.view.snapshot, assigns.ref))
      )

    ~H"""
    <Kit.form_card :if={@found} label={if @ref, do: "Edit environment", else: "Add an environment"}>
      <.live_component
        module={EnvironmentEditor}
        id={"environment-editor-" <> (@ref || "new")}
        ref={@ref}
        view={@view}
      />
    </Kit.form_card>
    <Kit.empty
      :if={!@found}
      id="environment-not-found"
      icon={:search}
      title="That environment was not found"
      text="It may have been removed. Go back to Environments to see what is there now."
    >
      <.link patch="/environments" class="ui-button secondary">Back to Environments</.link>
    </Kit.empty>
    """
  end

  @doc "Where one environment is edited, on its own page."
  @spec edit_path(String.t()) :: String.t()
  def edit_path(ref), do: "/environments/" <> URI.encode(ref, &URI.char_unreserved?/1) <> "/edit"

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
        read_only(environment),
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
    <Kit.empty icon={:grid} title="No environments yet" text={first_step(@github)}>
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

  defp first_action(_app_works), do: %{label: "Add repositories", href: "/repositories/new"}

  # How many of its repositories work only reads, when any.
  defp read_only(environment) do
    case length(Environment.read_only_refs(environment)) do
      0 -> nil
      count -> "#{count} read only"
    end
  end

  defp removal(%{is_default: true}),
    do:
      "Its repositories and Emisar account stay. Chat and every conversation without its own " <>
        "environment then work without one until you choose another default."

  defp removal(_environment), do: "Its repositories and Emisar account stay."

  defp query(%{"q" => q}) when is_binary(q), do: q |> String.trim() |> String.slice(0, 200)
  defp query(_params), do: ""

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
