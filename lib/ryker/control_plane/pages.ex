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
    BehaviorLibrary,
    BehaviorPage,
    ChannelDetail,
    ChannelPage,
    ConfigurationGuide,
    HTML,
    PathRef,
    SlackNames
  }

  @type page :: %{
          status: 200 | 404 | 503,
          title: String.t(),
          description: String.t() | nil,
          body: binary()
        }

  # Every kind the failures page can list, because it links each row it lists
  # and a kind missing here answers 404 to its own link. Publications were
  # listed and unreachable in production for exactly that reason.
  @failure_kinds ~w(admission delivery emisar publication retention slack_incident slack_interaction work)

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
      "Track Slack incident rooms from setup through closure, with channel status and linked investigation work.",
      HTML.incidents(snapshot, params)
    )
  end

  def page(["incident-rooms", incident_ref], _params, options) do
    with {:ok, incident_ref} <- PathRef.decode(incident_ref),
         {:ok, snapshot} <- options.projection.incident.(incident_ref) do
      ok(snapshot.room.title, HTML.incident(snapshot))
    else
      {:error, :path_ref} -> not_found("Incident room")
      :not_found -> not_found("Incident room")
      {:error, _reason} -> unavailable("Incident room")
    end
  end

  def page(["schedules"], params, options) do
    snapshot = options.projection.schedules.(Map.take(params, ["q", "status"]))

    ok(
      "Schedules",
      ConfigurationGuide.description(:schedules),
      HTML.schedules(snapshot, params)
    )
  end

  def page(["schedules", schedule_ref], _params, options) do
    with {:ok, schedule_ref} <- PathRef.decode(schedule_ref),
         {:ok, snapshot} <- options.projection.schedule.(schedule_ref) do
      ok(snapshot.schedule.title, HTML.schedule(snapshot))
    else
      {:error, :path_ref} -> not_found("Schedule")
      :not_found -> not_found("Schedule")
      {:error, _reason} -> unavailable("Schedule")
    end
  end

  def page(["subscriptions"], params, options) do
    snapshot = options.projection.subscriptions.(Map.take(params, ["q", "status"]))

    ok(
      "Waits",
      ConfigurationGuide.description(:subscriptions),
      HTML.subscriptions(snapshot, params)
    )
  end

  def page(["channels"], params, options) do
    snapshot = options.projection.channels.(Map.take(params, ["q"]))

    ok(
      "Channels",
      "Slack channels Ryker knows about: configuration, membership, repository and recorded work.",
      HTML.channels(snapshot, params)
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
          Safe.to_iodata(ChannelPage.lead(%{__changed__: nil, view: snapshot})),
          Safe.to_iodata(ChannelPage.render(%{__changed__: nil, view: snapshot}))
        ]
      )
    else
      {:error, :path_ref} -> not_found("Channel")
      :not_found -> not_found("Channel")
      {:error, _reason} -> unavailable("Channel")
    end
  end

  def page(["repositories"], params, options) do
    snapshot = options.projection.repositories.(Map.take(params, ["q"]))

    ok(
      "Repositories",
      "Connected repositories, the work they receive, and the code revision last used.",
      HTML.repositories(snapshot, params)
    )
  end

  def page(["memory"], params, options) do
    ok(
      "Memory",
      ConfigurationGuide.description(:memory),
      HTML.memory(options.projection.memory.(params), options.csrf_secret)
    )
  end

  def page([page], params, options) when page in ~w(rules preferences guidance) do
    kind = BehaviorLibrary.kind(page)
    snapshot = options.projection.behaviors.(kind, params)

    ok(
      BehaviorPage.title(kind),
      BehaviorPage.description(kind),
      Safe.to_iodata(BehaviorPage.render(%{__changed__: nil, view: snapshot}))
    )
  end

  def page(["usage"], params, options) do
    snapshot = options.projection.usage.(Map.take(params, ["window", "mode", "page"]))
    ok("Usage & cost", HTML.usage(snapshot))
  end

  def page(["failures"], params, options) do
    case options.projection.failures.(params) do
      {:ok, rows} -> ok("Failures", HTML.failures(rows))
      {:error, _reason} -> unavailable("Failures")
    end
  end

  def page(["failures", kind, resource_ref], _params, options) do
    with true <- kind in @failure_kinds,
         {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, failures} <- options.projection.failures.(%{}),
         %{} = row <- Enum.find(failures, &(&1.kind == kind and &1.ref == resource_ref)) do
      ok("Recovery", HTML.failure(row))
    else
      {:error, :path_ref} -> not_found("Failure")
      {:error, _reason} -> unavailable("Failure")
      _not_found -> not_found("Failure")
    end
  end

  def page(["workspaces"], params, options) do
    ok(
      "Workspaces",
      "Repository checkouts used by tasks, not Slack workspaces: what each one holds, what cleanup will do next, and the storage workers report.",
      HTML.workspaces(
        options.projection.workspaces.(params),
        options.projection.workspace_storage.()
      )
    )
  end

  def page(["findings"], params, options) do
    ok(
      "Findings",
      ConfigurationGuide.description(:findings),
      HTML.findings(options.projection.findings.(params))
    )
  end

  def page(_segments, _params, _options), do: not_found("Page")

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
