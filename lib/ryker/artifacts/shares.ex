defmodule Ryker.Artifacts.Shares do
  @moduledoc "Repository-authorized views of selected immutable turn outputs."
  alias Ryker.Artifacts.OutputArtifact
  alias Ryker.BrowserTests
  alias Ryker.Config
  alias Ryker.GitHubActions
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work

  def url(turn_id) do
    if GitHubActions.available?() do
      String.trim_trailing(Config.fetch_env!(:control_public_url), "/") <>
        "/github/actions/results/" <> turn_id
    end
  end

  def view(turn_id, token, options) do
    with {:ok, ^turn_id} <- Ecto.UUID.cast(turn_id),
         {:ok, turn} <- Repo.fetch(Work.Turn.Query.by_id(turn_id)),
         {:ok, session} <- Repo.fetch(Work.Session.Query.by_id(turn.session_id)),
         %{"source" => source} <- session.worker_job_document,
         {:ok, settings} <- Settings.fetch(),
         binding when not is_nil(binding) <-
           Enum.find(settings.github_bindings, fn binding ->
             binding.repository_ref == source["repository_ref"] and
               binding.repository_id == source["github_repository_id"]
           end),
         {:ok, access} <- GitHubActions.authorize_read(binding.name, token, options),
         true <-
           access.binding.repository_id == source["github_repository_id"] and
             access.repository.github_repository == source["github_repository"] do
      refs = selected_refs(turn)

      artifacts =
        turn_id
        |> OutputArtifact.Query.by_turn_id()
        |> OutputArtifact.Query.by_refs(refs)
        |> OutputArtifact.Query.ordered_by_name()
        |> Repo.all()

      {:ok,
       %{
         turn: turn,
         source: source,
         reports: BrowserTests.reports(turn_id),
         artifacts: artifacts,
         missing_images: length(refs) - length(artifacts),
         repository: access.repository.github_repository
       }}
    else
      _unavailable -> {:error, :shared_results_unavailable}
    end
  end

  @doc "The immutable selection, including a candidate whose reply waited for publication."
  def selected_refs(%Work.Turn{operational_pruned_at: nil} = turn) do
    document =
      case turn.delivery_document do
        %{} = document -> document
        nil -> accepted_document(turn)
      end

    get_in(document || %{}, ["outcome", "artifact_refs"]) || []
  end

  def selected_refs(_turn), do: []

  defp accepted_document(%Work.Turn{accepted_at: %DateTime{}} = turn) do
    case Work.ValidationIntent.result(turn.validation_intent) do
      {:ok, %Work.Result{delivery: :reply, delivery_document: document}} -> document
      _missing -> nil
    end
  end

  defp accepted_document(_turn), do: nil

  @doc "Batch projection for delivery and Chat. References retain their original turn ownership."
  def projections(turn_ids) do
    turn_ids
    |> Work.Turn.Query.by_ids()
    |> Work.Turn.Query.having_artifact_evidence()
    |> Work.Turn.Query.select_artifact_evidence()
    |> Repo.all()
    |> project()
  end

  defp project([]), do: %{}

  defp project(turns) do
    sources = Publication.Completion.report_sources(turns)
    all = Enum.uniq_by(turns ++ Map.values(sources), & &1.id)

    reports =
      all
      |> Enum.map(& &1.id)
      |> BrowserTests.Report.Query.by_turn_ids()
      |> BrowserTests.Report.Query.chronological()
      |> Repo.all()
      |> Enum.group_by(& &1.turn_id)

    sessions =
      all
      |> Enum.map(& &1.session_id)
      |> Work.Session.Query.by_ids()
      |> Work.Session.Query.select_artifact_source()
      |> Repo.all()
      |> Map.new()

    Map.new(turns, fn turn ->
      source = sources[turn.id]
      selected = if selected_refs(turn) == [] and source, do: source, else: turn

      suffix =
        [turn, source]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(&suffix(&1, Map.get(reports, &1.id, []), sessions[&1.session_id]))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      {turn.id, %{turn_id: selected.id, refs: selected_refs(selected), suffix: suffix}}
    end)
  end

  @doc "A hidden candidate is downloadable only through an accepted retained reply that exposes it."
  def exposed_by_reply?(%Work.Turn{} = source, ref) do
    replies =
      source.episode_id
      |> Work.Turn.Query.by_episode_id()
      |> Work.Turn.Query.reporting_candidate(source.id)
      |> Work.Turn.Query.select_artifact_evidence()
      |> Repo.all()

    sources = Publication.Completion.report_sources(replies)

    ref in selected_refs(source) and
      Enum.any?(replies, fn reply ->
        selected_refs(reply) == [] and
          match?(%Work.Turn{id: id} when id == source.id, sources[reply.id])
      end)
  end

  def append(message, ""), do: message
  def append(message, suffix), do: message <> "\n\n" <> suffix

  defp suffix(%Work.Turn{operational_pruned_at: pruned}, _reports, _source)
       when not is_nil(pruned), do: ""

  defp suffix(turn, reports, source) do
    summary =
      Enum.map_join(reports, "\n", fn report ->
        counts = Enum.frequencies_by(report.document["cases"], & &1["status"])

        "Browser checks (task-reported): " <>
          Enum.map_join(~w(passed failed blocked untested), ", ", &"#{counts[&1] || 0} #{&1}") <>
          "."
      end)

    link =
      if is_integer((source || %{})["github_repository_id"]) and
           (reports != [] or selected_refs(turn) != []),
         do: url(turn.id)

    link =
      if link, do: "[View retained results and screenshots](#{link}) · GitHub sign-in required."

    [summary, link] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
  end
end
