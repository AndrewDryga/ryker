defmodule Ryker.Work.Executor.Workspace do
  @moduledoc """
  Proves the remote workspace matches the frozen session before a submission
  is built.

  `session_workspace/2` reads the remote session and checks its primary and
  companion workspaces, the repository context, the configured workspace
  requirements, the repository source binding, and the version-2 freshness
  receipts against what the session persisted. The result is the workspace
  document the submission builder receives.
  """

  alias Ryker.Work.Executor.Remote
  alias Ryker.Work.RepositorySource

  @companion_name_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @doc false
  def session_workspace(claim, settings) do
    with {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           Remote.exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ),
         {:ok, primary} <- primary_workspace(claim.session, remote_session),
         {:ok, companions} <- companion_workspaces(Map.get(remote_session, "companions", [])),
         :ok <- repository_context_workspace(claim.session, companions),
         :ok <- required_workspaces(companions, settings.workspace_requirements),
         {:ok, source} <- repository_source_binding(claim.session, remote_session, primary),
         {:ok, freshness} <- repository_freshness(remote_session, source, primary, companions) do
      workspace =
        %{"companions" => companions, "freshness" => freshness, "primary" => primary}
        |> maybe_put_repository_context(claim.session.repository_context)
        |> maybe_put_repository_source(source)

      {:ok, workspace}
    end
  end

  # The binding must answer the exact request this session persisted, and the
  # workspace must actually start at the commit that binding pinned. A
  # workspace-free session has no persisted request, so a binding it reports is
  # only checked for internal consistency; it is never re-resolved.
  #
  # An intentionally local policy has no remote identity to bind: Coop refuses
  # every selector but its own default there and returns no binding, and the
  # primary freshness receipt already proves that workspace head.
  defp repository_source_binding(%{repository_source: %{"kind" => "default"}}, remote, _primary)
       when not is_map_key(remote, "source"),
       do: {:ok, nil}

  defp repository_source_binding(session, remote_session, primary) do
    case RepositorySource.reconcile(
           Map.get(remote_session, "source"),
           session.repository_source
         ) do
      {:ok, nil} -> {:ok, nil}
      {:ok, binding} -> exact_source_workspace(binding, primary)
      {:error, _reason} -> {:error, {:coop_protocol_error, :repository_source}}
    end
  end

  # The session's base commit is the creation base every later comparison is
  # measured from: the merge base of the pinned default head and the selected
  # head. The workspace itself starts at the binding's selected commit.
  defp exact_source_workspace(binding, primary) do
    if binding["base_commit"] == primary["base_commit"],
      do: {:ok, binding},
      else: {:error, {:coop_protocol_error, :repository_source}}
  end

  defp maybe_put_repository_source(workspace, nil), do: workspace
  defp maybe_put_repository_source(workspace, source), do: Map.put(workspace, "source", source)

  defp primary_workspace(session, %{
         "base_commit" => base_commit,
         "repository_read_only" => read_only
       })
       when is_boolean(read_only) do
    name = session.repository_ref || "primary"

    if Remote.reference?(name) and Remote.git_commit?(base_commit) do
      {:ok,
       %{
         "base_commit" => base_commit,
         "name" => name,
         "path" => ".",
         "read_only" => read_only
       }}
    else
      {:error, {:coop_protocol_error, :session_workspace}}
    end
  end

  defp primary_workspace(_session, _remote_session),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp companion_workspaces(companions) when is_list(companions) and length(companions) <= 32 do
    result =
      Enum.reduce_while(companions, {:ok, []}, fn companion, {:ok, prepared} ->
        case companion_workspace(companion) do
          {:ok, value} -> {:cont, {:ok, [value | prepared]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, prepared} ->
        sorted = Enum.sort_by(prepared, & &1["name"])
        names = Enum.map(sorted, & &1["name"])

        if names == Enum.uniq(names),
          do: {:ok, sorted},
          else: {:error, {:coop_protocol_error, :session_workspace}}

      {:error, _reason} = error ->
        error
    end
  end

  defp companion_workspaces(_companions),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp repository_context_workspace(%{repository_context: nil}, _companions), do: :ok

  defp repository_context_workspace(
         %{
           repository_ref: repository_ref,
           repository_context: %{
             "primary_repository" => repository_ref,
             "read_only_repositories" => expected
           }
         },
         companions
       )
       when is_list(expected) do
    actual = Enum.map(companions, & &1["name"])

    if Enum.sort(expected) == actual,
      do: :ok,
      else: {:error, {:coop_protocol_error, :repository_context}}
  end

  defp repository_context_workspace(_session, _companions),
    do: {:error, {:coop_protocol_error, :repository_context}}

  defp maybe_put_repository_context(workspace, nil), do: workspace

  defp maybe_put_repository_context(workspace, context) do
    workspace
    |> Map.put("context_ref", context["context_ref"])
    |> Map.put("parallel_goal_limit", context["parallel_goal_limit"])
  end

  defp companion_workspace(
         %{
           "base_commit" => base_commit,
           "name" => name,
           "path" => path
         } = companion
       )
       when map_size(companion) == 3 do
    if is_binary(name) and Regex.match?(@companion_name_regex, name) and
         path == "/coop/repositories/#{name}" and Remote.git_commit?(base_commit) do
      {:ok,
       %{
         "base_commit" => base_commit,
         "name" => name,
         "path" => path,
         "read_only" => true
       }}
    else
      {:error, {:coop_protocol_error, :session_workspace}}
    end
  end

  defp companion_workspace(_companion),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp required_workspaces(_companions, []), do: :ok

  defp required_workspaces(companions, requirements) do
    available = Map.new(companions, &{&1["name"], &1["base_commit"]})

    if Enum.all?(requirements, fn %{"base_commit" => base_commit, "name" => name} ->
         Map.get(available, name) == base_commit
       end),
       do: :ok,
       else: {:error, {:coop_protocol_error, :session_workspace}}
  end

  defp repository_freshness(remote_session, source, primary, companions) do
    case {
      Map.get(remote_session, "repository_freshness_status"),
      Map.get(remote_session, "repository_freshness")
    } do
      {"recorded", receipts} when is_list(receipts) and length(receipts) in 1..34 ->
        with {:ok, receipts} <- repository_freshness_receipts(receipts),
             :ok <- exact_repository_receipts(receipts, source, primary, companions) do
          {:ok, %{"owner" => "coop", "repositories" => receipts, "status" => "recorded"}}
        end

      _invalid ->
        {:error, {:coop_protocol_error, :repository_freshness}}
    end
  end

  defp repository_freshness_receipts(receipts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, prepared} ->
      case repository_freshness_receipt(receipt) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)
        names = Enum.map(prepared, & &1["name"])

        if names == Enum.uniq(names),
          do: {:ok, prepared},
          else: {:error, {:coop_protocol_error, :repository_freshness}}

      {:error, _reason} = error ->
        error
    end
  end

  defp repository_freshness_receipt(
         %{
           "fetched_at" => fetched_at,
           "name" => name,
           "remote_identity" => remote_identity,
           "requested_revision" => requested_revision,
           "resolved_revision" => resolved_revision,
           "stale_base_status" => stale_base_status,
           "version" => 2
         } = receipt
       )
       when map_size(receipt) in 7..9 and
              stale_base_status in ~w(current stale unknown not_applicable) do
    stale_base_revision = Map.get(receipt, "stale_base_revision")
    workspace_base_revision = Map.get(receipt, "workspace_base_revision")

    with true <- repository_name?(name),
         true <- bounded_text?(remote_identity, 256),
         true <- bounded_text?(requested_revision, 512),
         true <- Remote.git_commit?(resolved_revision),
         true <- is_nil(workspace_base_revision) or Remote.git_commit?(workspace_base_revision),
         {:ok, fetched_at} <- repository_timestamp(fetched_at),
         :ok <- stale_base_receipt(stale_base_status, stale_base_revision, resolved_revision) do
      {:ok,
       %{
         "fetched_at" => fetched_at,
         "name" => name,
         "remote_identity" => remote_identity,
         "requested_revision" => requested_revision,
         "resolved_revision" => resolved_revision,
         "stale_base_revision" => stale_base_revision,
         "stale_base_status" => stale_base_status,
         "version" => 2,
         "workspace_base_revision" => workspace_base_revision
       }}
    else
      _invalid -> {:error, {:coop_protocol_error, :repository_freshness}}
    end
  end

  defp repository_freshness_receipt(_receipt),
    do: {:error, {:coop_protocol_error, :repository_freshness}}

  defp exact_repository_receipts(receipts, source, primary, companions) do
    by_name = Map.new(receipts, &{&1["name"], &1})

    expected_names =
      ["primary" | Enum.map(companions, & &1["name"])] ++ source_receipt_names(source)

    valid =
      Map.keys(by_name) |> Enum.sort() == Enum.sort(expected_names) and
        primary_receipt_matches?(by_name["primary"], source, primary) and
        Enum.all?(companions, fn companion ->
          receipt = by_name[companion["name"]]

          receipt["resolved_revision"] == companion["base_commit"] and
            is_nil(receipt["workspace_base_revision"])
        end) and source_receipt_matches?(by_name, source)

    if valid, do: :ok, else: {:error, {:coop_protocol_error, :repository_freshness}}
  end

  # A default selection starts at the configured default head, so the primary
  # receipt already proves it. Every other selection needs its own remote proof,
  # including an exact object id: a cached object is not evidence the configured
  # remote still serves it.
  defp source_receipt_names(nil), do: []
  defp source_receipt_names(%{"kind" => "default"}), do: []
  defp source_receipt_names(_source), do: ["source"]

  defp primary_receipt_matches?(receipt, source, primary) when is_map(receipt) do
    receipt["workspace_base_revision"] == primary["base_commit"] and
      primary_revision_matches?(receipt, source, primary)
  end

  defp primary_receipt_matches?(_receipt, _source, _primary), do: false

  defp primary_revision_matches?(receipt, nil, primary),
    do: receipt["resolved_revision"] == primary["base_commit"]

  # The binding names the pinned default head; how Coop phrased that request is
  # its own business, but the identity it contacted and the commit it resolved
  # must be the ones the binding claims.
  defp primary_revision_matches?(receipt, source, _primary) do
    receipt["resolved_revision"] == source["default_commit"] and
      receipt["remote_identity"] == source["remote_identity"]
  end

  defp source_receipt_matches?(by_name, source) do
    case source_receipt_names(source) do
      [] -> true
      ["source"] -> exact_source_receipt?(by_name["source"], source)
    end
  end

  defp exact_source_receipt?(receipt, source) when is_map(receipt) do
    receipt["resolved_revision"] == source["selected_commit"] and
      is_nil(receipt["workspace_base_revision"]) and
      receipt["remote_identity"] == source["remote_identity"] and
      receipt["requested_revision"] == source_requested_revision(source)
  end

  defp exact_source_receipt?(_receipt, _source), do: false

  defp source_requested_revision(%{"kind" => "commit", "requested" => %{"sha" => sha}}), do: sha
  defp source_requested_revision(%{"selected_ref" => selected_ref}), do: selected_ref

  defp repository_name?(name),
    do: name in ["primary", "source"] or companion_name?(name)

  @doc false
  def companion_name?(name),
    do: is_binary(name) and Regex.match?(@companion_name_regex, name)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp repository_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  defp repository_timestamp(_value), do: {:error, :invalid_timestamp}

  defp stale_base_receipt("current", revision, resolved_revision)
       when revision == resolved_revision,
       do: :ok

  defp stale_base_receipt("stale", revision, resolved_revision)
       when revision != resolved_revision,
       do: if(Remote.git_commit?(revision), do: :ok, else: :error)

  defp stale_base_receipt(status, nil, _resolved_revision)
       when status in ~w(unknown not_applicable),
       do: :ok

  defp stale_base_receipt(_status, _revision, _resolved_revision), do: :error
end
