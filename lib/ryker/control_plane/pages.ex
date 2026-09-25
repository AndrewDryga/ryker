defmodule Ryker.ControlPlane.Pages do
  @moduledoc """
  The secondary operator pages: one prepared title, description and body per
  path, built from the projection callbacks and nothing else.

  `WorkbenchLive` renders these inside the live shell; there is no HTTP route
  for them. The status tells the shell what it holds: 200 is a page, 404 a
  path or record that does not exist, and 503 a projection that could not
  answer, which the shell reports instead of showing a stale page as current.
  """

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    BehaviorPage,
    ChannelDetail,
    ChannelPage,
    ChannelsPage,
    ConfigurationGuide,
    FactsPage,
    FailureExplanation,
    FailureProjection,
    FailuresPage,
    FindingsPage,
    HTML,
    IncidentRoomsPage,
    LearnedPage,
    LearningPage,
    PathRef,
    RepositoriesPage,
    SchedulesPage,
    SlackNames,
    SubscriptionsPage,
    UsagePage,
    WorkingCopiesPage
  }

  @type page :: %{
          required(:status) => 200 | 404 | 503,
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:body) => binary(),
          optional(:action) => binary()
        }

  # Every kind the failures page can list, because it links each row it lists
  # and a kind missing here answers 404 to its own link. Publications were
  # listed and unreachable in production for exactly that reason.
  @failure_kinds ~w(admission delivery emisar publication retention slack_incident slack_interaction stopping work)

  @doc """
  The page at `segments`, the request path split as the browser sent it, for
  the decoded query `params`.

  A reference segment is percent-decoded once here, so a ref carrying a literal
  percent sign survives; the shell must not decode the path before splitting it.
  """
  @spec page([String.t()], %{optional(String.t()) => term()}, map()) :: page()
  def page(["incident-rooms"], params, options) do
    snapshot = options.projection.incidents.(Map.take(params, ["q", "status"]))

    ok(
      "Incident rooms",
      IncidentRoomsPage.description(),
      IncidentRoomsPage.list(snapshot, params)
    )
  end

  def page(["incident-rooms", incident_ref], _params, options) do
    with {:ok, incident_ref} <- PathRef.decode(incident_ref),
         {:ok, snapshot} <- options.projection.incident.(incident_ref) do
      ok(
        snapshot.room.title,
        IncidentRoomsPage.summary(snapshot.room),
        IncidentRoomsPage.detail(snapshot)
      )
    else
      {:error, :path_ref} -> not_found("Incident room")
      :not_found -> not_found("Incident room")
      {:error, _reason} -> unavailable("Incident room")
    end
  end

  def page(["schedules"], params, options) do
    params = SchedulesPage.params(params)
    items = options.projection.schedules.(params)
    ok("Schedules", SchedulesPage.description(), SchedulesPage.list(items, params))
  end

  # A schedule that can still change keeps its controls opposite the title.
  def page(["schedules", schedule_ref], _params, options) do
    with {:ok, schedule_ref} <- PathRef.decode(schedule_ref),
         {:ok, snapshot} <- options.projection.schedule.(schedule_ref) do
      page = ok(snapshot.schedule.title, SchedulesPage.detail(snapshot))

      case SchedulesPage.actions(snapshot.schedule) do
        nil -> page
        action -> Map.put(page, :action, action)
      end
    else
      {:error, :path_ref} -> not_found("Schedule")
      :not_found -> not_found("Schedule")
      {:error, _reason} -> unavailable("Schedule")
    end
  end

  def page(["follow-ups"], params, options) do
    params = SubscriptionsPage.params(params)
    items = options.projection.subscriptions.(params)
    ok("Follow-ups", SubscriptionsPage.description(), SubscriptionsPage.list(items, params))
  end

  def page(["channels"], params, options) do
    view = ChannelsPage.view(params)
    items = options.projection.channels.(ChannelsPage.query(view))

    "Channels"
    |> ok(
      "Slack channels Ryker is in, and how it takes part in each one.",
      ChannelsPage.html(%{items: items, view: view, now: nil})
    )
    |> Map.put(
      :action,
      ~s(<a class="ui-button secondary" href="/integrations/slack#new-channels">Defaults</a>)
    )
  end

  def page(["channels", workspace_ref, channel_ref], params, options) do
    with {:ok, workspace_ref} <- PathRef.decode(workspace_ref),
         {:ok, channel_ref} <- PathRef.decode(channel_ref),
         {:ok, snapshot} <-
           options.projection.channel.(
             workspace_ref,
             channel_ref,
             Map.take(params, ChannelDetail.query_keys())
           ) do
      ok(
        SlackNames.name(workspace_ref, channel_ref),
        ChannelPage.description(snapshot),
        [
          Safe.to_iodata(
            ChannelPage.lead(%{__changed__: nil, view: snapshot, now: nil, editor: false})
          ),
          Safe.to_iodata(ChannelPage.render(%{__changed__: nil, view: snapshot, now: nil}))
        ]
      )
    else
      {:error, :path_ref} -> not_found("Channel")
      :not_found -> not_found("Channel")
      {:error, _reason} -> unavailable("Channel")
    end
  end

  def page(["repositories"], params, options) do
    view = RepositoriesPage.view(params)
    items = options.projection.repositories.(%{"q" => view.q})
    # Adding repositories needs a working GitHub App; until then the status
    # line above the list is the one way forward, not a second prompt.
    connected = match?({:ok, %{github_connection: :ready}}, settings(options))

    page =
      ok(
        "Repositories",
        "Code Ryker can read and work in.",
        RepositoriesPage.html(%{items: items, view: view, now: nil, connected: connected})
      )

    if connected,
      do:
        Map.put(
          page,
          :action,
          ~s(<a class="ui-button primary" href="#add-repositories">Add repositories</a>)
        ),
      else: page
  end

  def page(["memory"], params, options) do
    params = Map.take(params, FactsPage.query_keys())

    ok(
      "Facts",
      ConfigurationGuide.description(:memory),
      FactsPage.html(options.projection.memory.(params), params)
    )
  end

  def page(["memory", "learned"], params, options) do
    view = options.projection.learned.(Map.take(params, LearnedPage.query_keys()))

    ok(
      "Learned",
      ConfigurationGuide.description(:learned),
      LearnedPage.html(view, Map.get(options, :csrf_secret))
    )
  end

  # Background learning keeps its worker sessions in the same custody as
  # working copies; this page shows only its own.
  def page(["memory", "learning"], params, options) do
    activity = options.projection.learning.(Map.take(params, LearningPage.query_keys()))

    ok(
      "Learning",
      ConfigurationGuide.description(:learning),
      LearningPage.html(
        activity,
        options.projection.workspaces.(%{}),
        Map.get(options, :csrf_secret)
      )
    )
  end

  def page(["rules"], params, options) do
    snapshot =
      options.projection.behaviors.(
        :standing_assignment,
        Map.take(params, ["q", "status", "page"])
      )

    ok(
      "Rules",
      ConfigurationGuide.description(:rules),
      Safe.to_iodata(BehaviorPage.rules(%{__changed__: nil, view: snapshot}))
    )
  end

  def page(["usage"], params, options) do
    snapshot = options.projection.usage.(Map.take(params, ["window", "mode", "page"]))
    ok("Usage & cost", UsagePage.render(snapshot))
  end

  # A hundred failures a page, newest first; older ones are the next page,
  # never cut without a word.
  def page(["failures"], params, options) do
    page = FailureProjection.page_number(params)

    with {:ok, rows} <- options.projection.failures.(params),
         {:ok, older} <- older_failures(rows, page, params, options) do
      ok("Failures", FailuresPage.description(), [
        FailuresPage.list(rows),
        FailuresPage.pager(page, older)
      ])
    else
      {:error, _reason} -> unavailable("Failures")
    end
  end

  # One failure is read by its kind and reference, not found in the bounded
  # list, and titled by what stopped rather than a generic "Recovery".
  def page(["failures", kind, resource_ref], _params, options) do
    with true <- kind in @failure_kinds,
         {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, row} <- options.projection.failure.(kind, resource_ref) do
      explanation = FailureExplanation.explain(row)
      ok(explanation.title, explanation.lede, FailuresPage.detail(row))
    else
      {:error, :path_ref} -> not_found("Failure")
      {:error, _reason} -> unavailable("Failure")
      _not_found -> not_found("Failure")
    end
  end

  def page(["working-copies"], params, options) do
    ok(
      "Working copies",
      "Copies of repositories Ryker checks out while it works, and how it cleans them up.",
      WorkingCopiesPage.html(%{
        rows: options.projection.workspaces.(params),
        storage: options.projection.workspace_storage.(),
        now: nil
      })
    )
  end

  def page(["memory", "findings"], params, options) do
    ok(
      "Findings",
      ConfigurationGuide.description(:findings),
      FindingsPage.html(options.projection.findings.(Map.take(params, FindingsPage.query_keys())))
    )
  end

  def page(_segments, _params, _options), do: not_found("Page")

  defp settings(%{projection: %{settings: settings}}), do: settings.()
  defp settings(_options), do: {:error, :unavailable}

  # Only a full page can have older failures behind it, and asking for the
  # next page is how to know without counting every kind. The deepest page
  # says the rest exist rather than linking past what the list reads.
  defp older_failures(rows, page, params, options) do
    cond do
      length(rows) < FailureProjection.page_size() ->
        {:ok, :none}

      page == FailureProjection.maximum_page() ->
        {:ok, :unlisted}

      true ->
        case options.projection.failures.(Map.put(params, "page", Integer.to_string(page + 1))) do
          {:ok, []} -> {:ok, :none}
          {:ok, _older} -> {:ok, :next_page}
          {:error, _reason} = error -> error
        end
    end
  end

  defp ok(title, body), do: ok(title, nil, body)

  defp ok(title, description, body),
    do: %{status: 200, title: title, description: description, body: IO.iodata_to_binary(body)}

  defp not_found(subject),
    do: %{
      status: 404,
      title: "Not found",
      description: nil,
      body: IO.iodata_to_binary(HTML.not_found(subject))
    }

  # The shell never shows a 503 body: it keeps the last observed page and says
  # the refresh failed, so this only has to name what could not be read.
  defp unavailable(subject),
    do: %{
      status: 503,
      title: "Unavailable",
      description: nil,
      body: Plug.HTML.html_escape("#{subject} unavailable")
    }
end
