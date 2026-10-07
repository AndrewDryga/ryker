defmodule Ryker.ControlPlane.Pages do
  @moduledoc """
  The secondary operator pages: one prepared title, description and body per
  path, built from the projection callbacks and nothing else.

  `WorkbenchLive` renders these inside the live shell; there is no HTTP route
  for them. The status tells the shell what it holds: 200 is a page, 404 a
  path or record that does not exist, and 503 a projection that could not
  answer, which the shell reports instead of showing a stale page as current.

  Each page also declares what it listens to (`subscriptions/2`), so the
  shell redraws an open page when, and only when, something it shows changes.
  """

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{BehaviorPage, CasesPage, ChannelDetail, ChannelPage, ChannelsPage}
  alias Ryker.ControlPlane.{ConfigurationGuide, FactsPage, FailureExplanation, FailureProjection}
  alias Ryker.ControlPlane.{FailuresPage, FeedbackPage, FeedbackProjection, FindingsPage, HTML}
  alias Ryker.ControlPlane.{ImprovementPage, ImprovementProjection, IncidentProjection}
  alias Ryker.ControlPlane.{IncidentRoomsPage, LearnedPage, LearningPage, LocalRoutingPage}
  alias Ryker.ControlPlane.{PathRef, PeoplePage, RepositoriesPage, SchedulesPage, SettingsView}
  alias Ryker.ControlPlane.{SubscriptionsPage, UsagePage, UsageProjection, WorkingCopiesPage}

  @type page :: %{
          required(:status) => 200 | 404 | 503,
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:body) => binary(),
          optional(:action) => binary(),
          optional(:back) => {String.t(), String.t()}
        }

  # Every kind the failures page can list, because it links each row it lists
  # and a kind missing here answers 404 to its own link. Publications were
  # listed and unreachable in production for exactly that reason.
  @doc """
  The page at `segments`, the request path split as the browser sent it, for
  the decoded query `params`.

  A reference segment is percent-decoded once here, so a ref carrying a literal
  percent sign survives; the shell must not decode the path before splitting it.
  """
  @spec page([String.t()], %{optional(String.t()) => term()}, map()) :: page()
  def page(["incident-rooms"], params, options) do
    snapshot = options.projection.incidents.(Map.take(params, ["q", "status", "page"]))

    ok(
      "Incident rooms",
      IncidentRoomsPage.description(),
      IncidentRoomsPage.list(snapshot, params)
    )
  end

  # A room that can still close keeps Close opposite its title.
  def page(["incident-rooms", slug], _params, options) do
    with {:ok, incident_ref} <- PathRef.reference("slack_incident", slug),
         {:ok, snapshot} <- options.projection.incident.(incident_ref) do
      page =
        snapshot.room.title
        |> ok(IncidentRoomsPage.summary(snapshot.room), IncidentRoomsPage.detail(snapshot))
        |> Map.put(:back, {"All incident rooms", "/incident-rooms"})

      case IncidentRoomsPage.actions(snapshot.room) do
        nil -> page
        action -> Map.put(page, :action, action)
      end
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
  def page(["schedules", id], _params, options) do
    with {:ok, schedule_ref} <- PathRef.reference("schedule", id),
         {:ok, snapshot} <- options.projection.schedule.(schedule_ref) do
      page =
        snapshot.schedule.title
        |> ok(SchedulesPage.detail(snapshot))
        |> Map.put(:back, {"All schedules", "/schedules"})

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
    channels = options.projection.channels.(ChannelsPage.query(view))

    ok(
      "Channels",
      "Slack channels Ryker is in, and how it takes part in each one.",
      ChannelsPage.html(%{channels: channels, view: view, now: nil})
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
      snapshot
      |> ChannelPage.title()
      |> ok(ChannelPage.description(snapshot), [
        Safe.to_iodata(
          ChannelPage.lead(%{__changed__: nil, view: snapshot, now: nil, editor: false})
        ),
        Safe.to_iodata(ChannelPage.render(%{__changed__: nil, view: snapshot, now: nil}))
      ])
      |> Map.merge(%{
        back: {"All channels", "/channels"},
        state: ChannelPage.header_state(snapshot),
        title_href: ChannelPage.slack_url(snapshot)
      })
    else
      {:error, :path_ref} -> not_found("Channel")
      :not_found -> not_found("Channel")
      {:error, _reason} -> unavailable("Channel")
    end
  end

  def page(["repositories"], params, options) do
    view = RepositoriesPage.view(params)
    %{items: items, total: total} = options.projection.repositories.(%{"q" => view.q})
    # Adding repositories needs a working GitHub App; until then the status
    # line above the list is the one way forward, not a second prompt.
    connected = SettingsView.github_ready?(settings(options))

    page =
      ok(
        "Repositories",
        "Code Ryker can read and work in.",
        RepositoriesPage.html(%{
          items: items,
          total: total,
          view: view,
          now: nil,
          connected: connected
        })
      )

    if connected do
      Map.put(
        page,
        :action,
        ~s(<a class="ui-button primary" href="/repositories/new" data-phx-link="patch" ) <>
          ~s(data-phx-link-state="push">Add repositories</a>)
      )
    else
      page
    end
  end

  # Adding repositories is a page of its own, its form in one card under the
  # shell's header (`Ryker.ControlPlane.RepositoryImport`), with the list it
  # adds to above the title.
  def page(["repositories", "new"], _params, _options) do
    "Add repositories"
    |> ok(
      "Import repositories the connected GitHub App can reach. Work uses one once you " <>
        "choose it in an environment.",
      ""
    )
    |> Map.put(:back, {"All repositories", "/repositories"})
  end

  # One repository's page, under its name. A repository no longer added has
  # no page; its past requests stay in Activity.
  def page(["repositories", repository_ref], _params, options) do
    with {:ok, repository_ref} <- PathRef.decode(repository_ref),
         {:ok, item} <-
           options.projection.repository_detail.(
             repository_ref,
             Map.get(options, :disclosed, MapSet.new())
           ) do
      item
      |> RepositoriesPage.name()
      |> ok(RepositoriesPage.detail_html(item))
      |> Map.put(:back, {"All repositories", "/repositories"})
    else
      {:error, :path_ref} -> not_found("Repository")
      :error -> not_found("Repository")
    end
  end

  def page(["memory"], params, options) do
    params = Map.take(params, FactsPage.query_keys())

    ok(
      "Facts",
      ConfigurationGuide.description(:memory),
      FactsPage.html(options.projection.memory.(params), params)
    )
  end

  # One topic, or the messages behind a record, is a sub-page with its own
  # heading; the lists keep the page's.
  def page(["memory", "learned"], params, options) do
    view = options.projection.learned.(Map.take(params, LearnedPage.query_keys()))
    body = LearnedPage.html(view, Map.get(options, :csrf_secret))

    case LearnedPage.heading(view) do
      nil -> ok("Learned", ConfigurationGuide.description(:learned), body)
      :not_found -> not_found("Topic")
      heading -> sub_page(heading, body)
    end
  end

  # Background learning keeps its worker sessions in the same custody as
  # working copies; this page shows only its own. One batch is a sub-page with
  # its own heading.
  def page(["memory", "learning"], params, options) do
    params = Map.take(params, LearningPage.query_keys())
    activity = options.projection.learning.(params)

    body =
      LearningPage.html(
        activity,
        options.projection.learning_sessions.(),
        Map.get(options, :csrf_secret)
      )

    case LearningPage.heading(activity, params) do
      nil -> ok("Learning", ConfigurationGuide.description(:learning), body)
      :not_found -> not_found("Learning batch")
      heading -> sub_page(heading, body)
    end
  end

  def page(["rules"], params, options) do
    snapshot =
      options.projection.behaviors.(
        :standing_assignment,
        Map.take(params, ["q", "view", "page"])
      )

    ok(
      "Rules",
      ConfigurationGuide.description(:rules),
      Safe.to_iodata(BehaviorPage.rules(%{__changed__: nil, view: snapshot}))
    )
  end

  def page(["usage"], params, options) do
    snapshot = options.projection.usage.(Map.take(params, ["window", "mode", "by"]))
    ok("Usage & cost", UsagePage.render(snapshot))
  end

  # How the local routing model compares on live routing, beside its setting:
  # Andrew, 2026-10-03, of it on Usage & cost: "why the fuck you added Local
  # routing model and Where it decided differently to usage and costs?!"
  def page(["settings", "models", "local-routing"], params, options) do
    window = UsageProjection.window(params["window"])
    summary = options.projection.local_routing.(UsageProjection.since(window), "live")

    "Local routing model"
    |> ok(LocalRoutingPage.description(), LocalRoutingPage.render(summary, window))
    |> Map.put(:back, {"Models", "/settings/models"})
  end

  # A hundred failures a page, newest first; older ones are the next page,
  # never cut without a word.
  def page(["failures"], params, options) do
    page = FailureProjection.page_number(params)

    case options.projection.failures.(params) do
      {:ok, %{rows: rows, older: older}} ->
        ok("Failures", FailuresPage.description(), [
          FailuresPage.list(rows, DateTime.utc_now(), page_only: page > 1 or older != :none),
          FailuresPage.pager(page, older)
        ])

      {:error, _reason} ->
        unavailable("Failures")
    end
  end

  # One failure is read by its kind and the record's id, not found in the
  # bounded list, and titled by what stopped rather than a generic "Recovery".
  def page(["failures", kind, id], _params, options) do
    with true <- kind in FailureProjection.kinds(),
         {:ok, resource_ref} <- PathRef.reference(kind, id, options.projection.request_key),
         {:ok, row} <- options.projection.failure.(kind, resource_ref) do
      explanation = FailureExplanation.explain(row)

      explanation.title
      |> ok(explanation.lede, FailuresPage.detail(row))
      |> Map.put(:back, {"All failures", "/failures"})
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
        copies: options.projection.working_copies.(params),
        storage: options.projection.workspace_storage.(),
        now: nil,
        view: params["view"]
      })
    )
  end

  # What people said about Ryker's answers; one category is a sub-page with
  # its own heading and the way back to all feedback.
  def page(["feedback"], params, options) do
    view = options.projection.feedback.(Map.take(params, FeedbackProjection.query_keys()))
    body = FeedbackPage.html(view)

    case FeedbackPage.heading(view) do
      nil -> ok("Feedback", FeedbackPage.description(), body)
      heading -> sub_page(heading, body)
    end
  end

  # Requests people were unhappy with, with Ryker's own diagnosis: a
  # sub-page of Feedback with the way back to it.
  def page(["feedback", "fix"], params, options) do
    view = options.projection.improvement.(Map.take(params, ImprovementProjection.query_keys()))
    view |> ImprovementPage.heading() |> sub_page(ImprovementPage.html(view))
  end

  # One case is a sub-page of its own, with the way back to all of them.
  def page(["memory", "cases"], %{"case" => id}, options) when is_binary(id) do
    case options.projection.case.(id) do
      {:ok, item} -> sub_page(CasesPage.heading(item), CasesPage.case_html(item))
      :error -> not_found("Case")
    end
  end

  def page(["memory", "cases"], params, options) do
    ok(
      "Cases",
      ConfigurationGuide.description(:cases),
      CasesPage.html(options.projection.cases.(Map.take(params, CasesPage.query_keys())))
    )
  end

  # One finding is a sub-page of its own, with the way back to all of them.
  def page(["memory", "findings"], %{"finding" => id}, options) when is_binary(id) do
    case options.projection.finding.(id) do
      {:ok, finding} ->
        sub_page(FindingsPage.heading(finding), FindingsPage.finding_html(finding))

      :error ->
        not_found("Finding")
    end
  end

  def page(["memory", "findings"], params, options) do
    ok(
      "Findings",
      ConfigurationGuide.description(:findings),
      FindingsPage.html(options.projection.findings.(Map.take(params, FindingsPage.query_keys())))
    )
  end

  # One person is a sub-page of their own, with the way back to everyone.
  def page(["memory", "people"], %{"person" => person_ref}, options)
      when is_binary(person_ref) do
    case options.projection.person.(person_ref) do
      {:ok, person} -> sub_page(PeoplePage.heading(person), PeoplePage.person_html(person))
      :error -> not_found("Person")
    end
  end

  def page(["memory", "people"], _params, options) do
    ok(
      "People",
      ConfigurationGuide.description(:people),
      PeoplePage.html(options.projection.people.())
    )
  end

  def page(_segments, _params, _options), do: not_found("Page")

  @doc """
  The topics the page at `segments` listens to, as the context functions that
  subscribe to them: `{module, subscribe_function, arguments}`, each with its
  `unsubscribe_` twin. Each page declares its own; a page that does not exist
  listens to nothing.
  """
  @spec subscriptions([String.t()], map()) :: [{module(), atom(), list()}]
  def subscriptions(["incident-rooms"], _params), do: IncidentRoomsPage.subscriptions()

  def subscriptions(["incident-rooms", slug], _params) do
    case PathRef.reference("slack_incident", slug) do
      {:ok, incident_ref} -> IncidentProjection.subscriptions(incident_ref)
      _not_an_address -> []
    end
  end

  def subscriptions(["schedules"], _params), do: SchedulesPage.subscriptions(nil)

  def subscriptions(["schedules", id], _params) do
    case PathRef.reference("schedule", id) do
      {:ok, schedule_ref} -> SchedulesPage.subscriptions(schedule_ref)
      _not_an_address -> []
    end
  end

  def subscriptions(["follow-ups"], _params), do: SubscriptionsPage.subscriptions()
  def subscriptions(["channels"], _params), do: ChannelsPage.subscriptions()
  def subscriptions(["repositories"], _params), do: RepositoriesPage.subscriptions()
  def subscriptions(["repositories", _ref], _params), do: RepositoriesPage.subscriptions()
  def subscriptions(["memory"], _params), do: FactsPage.subscriptions()
  def subscriptions(["memory", "learned"], _params), do: LearnedPage.subscriptions()
  def subscriptions(["memory", "learning"], _params), do: LearningPage.subscriptions()
  def subscriptions(["memory", "findings"], _params), do: FindingsPage.subscriptions()
  def subscriptions(["memory", "cases"], _params), do: CasesPage.subscriptions()
  def subscriptions(["memory", "people"], _params), do: PeoplePage.subscriptions()
  def subscriptions(["feedback"], _params), do: FeedbackPage.subscriptions()
  def subscriptions(["feedback", "fix"], _params), do: ImprovementPage.subscriptions()

  def subscriptions(["rules"], _params), do: BehaviorPage.subscriptions(:rules)
  def subscriptions(["usage"], _params), do: UsagePage.subscriptions()

  def subscriptions(["settings", "models", "local-routing"], _params),
    do: LocalRoutingPage.subscriptions()

  def subscriptions(["failures" | _failure], _params), do: FailuresPage.subscriptions()
  def subscriptions(["working-copies"], _params), do: WorkingCopiesPage.subscriptions()
  def subscriptions(_segments, _params), do: []

  defp settings(%{projection: %{settings: settings}}), do: settings.()
  defp settings(_options), do: {:error, :unavailable}

  defp ok(title, body), do: ok(title, nil, body)

  # A sub-page's heading: its title and description, the way back to the page
  # it belongs to, and the action opposite its title when it has one.
  defp sub_page(heading, body) do
    heading.title
    |> ok(heading.description, body)
    |> Map.merge(
      Map.reject(Map.take(heading, [:back, :action]), fn {_key, value} -> is_nil(value) end)
    )
  end

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
