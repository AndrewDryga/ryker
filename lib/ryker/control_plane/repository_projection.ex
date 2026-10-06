defmodule Ryker.ControlPlane.RepositoryProjection do
  @moduledoc """
  The repository directory: every repository added to Ryker, with the
  environments it is in, its counts, its configured work, the freshness
  receipt of its last recorded work, and where its knowledge stands
  (`Ryker.RepositoryKnowledge`).

  Channels choose environments, not repositories, so a repository's channels
  are the channels whose environment holds it.
  """

  import Ecto.Query
  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{CallRun, Environments, Search}
  alias Ryker.GitHub.Events
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Publication.Publication
  alias Ryker.{Repo, RepositoryKnowledge}
  alias Ryker.Schedules.Schedule
  alias Ryker.Settings
  alias Ryker.Work.{Session, Turn}

  @list_limit 100

  @doc """
  The first hundred repositories added to Ryker, by name, with their
  environments, counts, configured work and freshness, and how many there
  are in all: past a hundred, the list called the hundred it showed the
  total. Only the rows shown are read; their counts, receipts and knowledge
  were read for every repository before the cut (2026-10-04 review).
  """
  def list(params) when is_map(params) do
    settings = settings()
    configured = configured_repositories(settings)

    refs =
      configured
      |> Map.keys()
      |> filter_repository_search(Search.term(params["q"]), configured)
      |> Enum.sort()

    %{items: rows(settings, configured, Enum.take(refs, @list_limit)), total: length(refs)}
  end

  def list(_params), do: list(%{})

  @doc """
  One repository's row as `list/1` shows it, read for its exact ref alone, or
  `:error` when it is not added. The questions a row's buttons ask read it
  this way, so a repository past the list's first hundred is still found.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(ref) when is_binary(ref) do
    settings = settings()
    configured = configured_repositories(settings)

    if Map.has_key?(configured, ref),
      do: {:ok, hd(rows(settings, configured, [ref]))},
      else: :error
  end

  @doc """
  One repository's page: its row as `fetch/1` reads it, GitHub's deliveries
  for it, and the model runs that wrote its knowledge. A run's prompt and
  answer are read once the reader opens them (`disclosed`, the artifact ids
  opened on the page).
  """
  @spec detail(String.t(), MapSet.t()) :: {:ok, map()} | :error
  def detail(ref, disclosed \\ MapSet.new()) when is_binary(ref) do
    with {:ok, row} <- fetch(ref) do
      {:ok,
       row
       |> Map.update!(:configured, &with_github_health(&1, ref))
       |> Map.put(:knowledge_runs, knowledge_runs(ref, disclosed))}
    end
  end

  # Only the page shows GitHub's side, so only the page reads it: five queries
  # a repository read it for every row of the list (2026-10-04 review).
  defp with_github_health(%{github_bound: true} = configured, ref),
    do: Map.put(configured, :github_health, Events.repository_health(ref))

  defp with_github_health(configured, _ref), do: configured

  @knowledge_runs 5
  # What a run's card reads before its prompt and answer are opened: every
  # column but the large ones.
  @run_fields RepositoryKnowledge.Run.__schema__(:fields) -- [:prompt, :result, :document]

  # The model runs that wrote this repository's knowledge, newest first, with
  # what each cost from the execution ledger and exactly what it was sent and
  # answered (Andrew, 2026-09-28: every model call shows the prompt it was
  # sent; the knowledge runs were shown nowhere). A prompt or answer is read
  # and redacted once it is opened: every read redacted all of them, up to
  # five 2 MB prompts, on every change to any request (2026-10-04 review).
  defp knowledge_runs(ref, disclosed) do
    runs =
      Repo.all(
        from(run in RepositoryKnowledge.Run,
          where: run.repository_ref == ^ref,
          order_by: [desc: run.inserted_at, desc: run.id],
          limit: @knowledge_runs,
          select:
            {struct(run, ^@run_fields), fragment("octet_length(?)", run.prompt),
             fragment("octet_length(?)", run.result)}
        )
      )

    ids = Enum.map(runs, fn {run, _prompt, _result} -> run.id end)

    executions =
      Repo.all(from(e in Execution, where: e.kind == "knowledge" and e.source_id in ^ids))
      |> Map.new(&{&1.source_id, &1})

    texts = opened_texts(runs, disclosed)

    Enum.map(runs, fn {run, prompt_bytes, result_bytes} ->
      %{
        id: run.id,
        at: run.started_at || run.inserted_at,
        status: run.status,
        commit: run.source_commit,
        call: CallRun.from_background(run, executions[run.id]),
        error_code: run.error_code,
        dropped: run.dropped_count,
        prompt: part(run.id, "prompt", prompt_bytes, texts),
        result: part(run.id, "answer", result_bytes, texts)
      }
    end)
  end

  # The prompts and answers the reader opened, read and redacted alone.
  defp opened_texts(runs, disclosed) do
    opened =
      for {run, _prompt, _result} <- runs,
          part <- ["prompt", "answer"],
          MapSet.member?(disclosed, part_id(run.id, part)),
          do: {run.id, part}

    if opened == [] do
      %{}
    else
      secrets = Redactor.configured_secrets()

      from(run in RepositoryKnowledge.Run,
        where: run.id in ^Enum.map(opened, &elem(&1, 0)),
        select: {run.id, run.prompt, run.result}
      )
      |> Repo.all()
      |> Enum.flat_map(fn {id, prompt, result} ->
        [{{id, "prompt"}, prompt}, {{id, "answer"}, result}]
      end)
      |> Enum.filter(fn {key, _text} -> key in opened end)
      |> Map.new(fn {key, text} -> {key, exact(text, secrets)} end)
    end
  end

  defp part(_id, _part, nil, _texts), do: nil

  defp part(id, part, bytes, texts),
    do: %{artifact_id: part_id(id, part), bytes: bytes, text: Map.get(texts, {id, part})}

  defp part_id(id, part), do: "knowledge-run-#{id}-#{part}"

  # The bytes as they were sent or answered. Re-encoding the JSON would
  # reorder it into something never sent; the redactor keeps the format.
  defp exact(nil, _secrets), do: nil

  defp exact(text, secrets) do
    case Redactor.artifact(text, secrets: secrets, preserve_format: true, max_bytes: 2_097_152) do
      %{state: :retained, text: text} -> text
      _unavailable -> nil
    end
  end

  # The rows for `refs`, each part read for those repositories alone.
  defp rows(_settings, _configured, []), do: []

  defp rows(settings, configured, refs) do
    channel_counts = Environments.channel_counts()
    freshness = repository_freshness(refs)
    knowledge = RepositoryKnowledge.entries(refs)
    publications = grouped_count(Publication, :repository, refs)
    schedules = grouped_count(Schedule, :repository, refs)
    # The tasks people asked for: a session that read the repository for its
    # RYKER.md is none of them.
    sessions =
      grouped_count(
        from(session in Session, where: session.execution_kind == :work),
        :repository_ref,
        refs
      )

    Enum.map(refs, fn ref ->
      environments = Environments.containing(settings, ref)

      %{
        channels: Enum.sum_by(environments, &Map.get(channel_counts, &1.ref, 0)),
        configured: Map.fetch!(configured, ref),
        environments: Enum.map(environments, & &1.display_name),
        in_environments: Enum.map(environments, &%{ref: &1.ref, name: &1.display_name}),
        freshness: Map.get(freshness, ref),
        knowledge: knowledge_view(Map.get(knowledge, ref)),
        publications: Map.get(publications, ref, 0),
        ref: ref,
        schedules: Map.get(schedules, ref, 0),
        sessions: Map.get(sessions, ref, 0)
      }
    end)
  end

  # What a row says of the repository's knowledge: what is under way, the
  # document Ryker keeps and who wrote it, why the last step failed, and when
  # the next check is due. Ryker is the only place the document can be read.
  defp knowledge_view(nil), do: nil

  defp knowledge_view(entry) do
    Map.take(entry, [
      :phase,
      :reason,
      :document,
      :document_by,
      :document_commit,
      :document_at,
      :checked_at,
      :next_check_at,
      :error
    ])
  end

  defp filter_repository_search(names, nil, _configured), do: names

  defp filter_repository_search(names, search, configured) do
    search = String.downcase(search)

    Enum.filter(names, fn ref ->
      Enum.any?(
        [ref, get_in(configured, [ref, :github_repository])],
        &(is_binary(&1) and String.contains?(String.downcase(&1), search))
      )
    end)
  end

  defp grouped_count(schema, field, refs) do
    from(row in schema,
      where: field(row, ^field) in ^refs,
      group_by: field(row, ^field),
      select: {field(row, ^field), count(row.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp settings do
    case Settings.fetch() do
      {:ok, snapshot} -> snapshot
      _error -> nil
    end
  end

  # The repositories Ryker has, by ref, as their rows show what was saved
  # for them. One removed from Ryker leaves the list, and its tasks keep their
  # history (Andrew, 2026-09-28).
  defp configured_repositories(nil), do: %{}

  defp configured_repositories(snapshot) do
    bindings = Map.new(snapshot.github_bindings, &{&1.repository_ref, &1})

    Map.new(snapshot.repositories, fn repository ->
      binding = Map.get(bindings, repository.ref)

      {repository.ref,
       %{
         action_grants: binding && binding.action_grants,
         approvals_allowed: binding && binding.approvals_allowed,
         # Saved without it, a repository is not fully added: nothing
         # can set it up or work in it (`RepositoriesPage`).
         github_bound: not is_nil(binding),
         github_permissions: binding && binding.granted_permissions,
         github_access: repository.github_access,
         github_repository: repository.github_repository,
         onboarding_error: repository.onboarding_error,
         onboarding_state: repository.onboarding_state,
         ref: repository.ref,
         source_commit: repository.source_commit,
         updated_at: repository.updated_at
       }}
    end)
  end

  # The primary repository's receipt in a task's frozen prompt, when Coop
  # recorded one.
  @primary_receipt ~s|$.context.workspace.freshness ? (@.owner == "coop" && @.status == "recorded").repositories[*] ? (@.name == "primary")|

  # The receipt of the code each repository's tasks last recorded: its tasks
  # newest first, read until a prompt that recorded one. The list read the 500
  # newest tasks' whole prompts, up to 640 KB each, to find these, on every
  # change to any request (2026-10-04 review).
  defp repository_freshness(refs) do
    # OFFSET 0 keeps the receipt check above the ordering, so it reads each
    # prompt in turn and stops at the first with a receipt, instead of
    # reading every prompt before ordering them.
    newest_first =
      from(turn in Turn,
        join: session in Session,
        on: session.id == turn.session_id,
        where:
          session.repository_ref == parent_as(:repository).ref and not is_nil(turn.submission),
        order_by: [desc: turn.updated_at, desc: turn.id],
        offset: 0,
        select: %{recorded_at: turn.updated_at, submission: turn.submission}
      )

    last_receipt =
      from(task in subquery(newest_first),
        where:
          fragment(
            "jsonb_path_exists(?::jsonb, ?::text::jsonpath)",
            task.submission,
            ^@primary_receipt
          ),
        limit: 1,
        select: %{
          recorded_at: task.recorded_at,
          receipt:
            fragment(
              "jsonb_path_query_first(?::jsonb, ?::text::jsonpath)",
              task.submission,
              ^@primary_receipt
            )
        }
      )

    from(repository in fragment("SELECT unnest(?::text[]) AS ref", ^refs),
      as: :repository,
      inner_lateral_join: freshness in subquery(last_receipt),
      on: true,
      select: {repository.ref, freshness.recorded_at, freshness.receipt}
    )
    |> Repo.all()
    |> Map.new(fn {ref, recorded_at, receipt} -> {ref, receipt_view(receipt, recorded_at)} end)
  end

  defp receipt_view(receipt, recorded_at) do
    %{
      fetched_at: receipt["fetched_at"],
      recorded_at: recorded_at,
      remote_identity: receipt["remote_identity"],
      requested_revision: receipt["requested_revision"],
      resolved_revision: receipt["resolved_revision"],
      stale_base_revision: receipt["stale_base_revision"],
      stale_base_status: receipt["stale_base_status"],
      version: receipt["version"],
      workspace_base_revision: receipt["workspace_base_revision"]
    }
  end
end
