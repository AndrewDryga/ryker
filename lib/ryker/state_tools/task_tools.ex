defmodule Ryker.StateTools.TaskTools do
  @moduledoc false

  alias Ryker.State.{Record, Records}
  alias Ryker.StateTools.RecordWriter
  alias Ryker.Work.RepositorySource

  @spec request_task(map(), map()) :: {:ok, map()} | {:error, term()}
  def request_task(arguments, binding) do
    kind = Map.get(arguments, "kind", "engineering")
    arguments = Map.put(arguments, "kind", kind)

    with :ok <- task_repository(kind, arguments["repository"]),
         {:ok, repository_source} <-
           task_repository_source(arguments["repository"], arguments["repository_source"]),
         {:ok, instruction_ref} <- task_instruction_ref(arguments, binding) do
      payload = %{
        "authority_limits" => arguments["authority_limits"],
        "instruction_ref" => instruction_ref,
        "kind" => kind,
        "prompt" => task_prompt(arguments, instruction_ref),
        "repository" => arguments["repository"],
        "repository_source" => repository_source,
        "source_refs" => arguments["source_refs"],
        "success_checks" => arguments["success_checks"],
        "title" => arguments["title"]
      }

      RecordWriter.create_record(binding, "request_task", arguments, "task_offer", payload)
    end
  end

  @spec plan_goal(map(), map()) :: {:ok, map()} | {:error, term()}
  def plan_goal(arguments, binding) do
    with :ok <- goal_repository_scope(arguments, binding.session) do
      RecordWriter.create_record(binding, "plan_goal", arguments, "goal", arguments)
    end
  end

  @spec update_goal(map(), map()) :: {:ok, map()} | {:error, term()}
  def update_goal(arguments, binding) do
    RecordWriter.create_record(binding, "update_goal", arguments, "goal_state", arguments)
  end

  # Feedback may name the one open task offer it is refining. Keep the original
  # trusted instruction as the task identity so the new record supersedes the
  # pending proposal instead of creating a second task. Cross-episode,
  # cross-repository, terminal, and non-task refs never grant this authority.
  defp task_instruction_ref(
         %{
           "instruction_ref" => "record:task_offer:" <> _suffix = record_ref,
           "kind" => requested_kind,
           "repository" => requested_repository
         },
         binding
       ) do
    case Records.fetch_for_episode(binding.episode.id, [record_ref]) do
      {:ok,
       [
         %Record{
           kind: "task_offer",
           payload: %{
             "instruction_ref" => instruction_ref,
             "kind" => kind,
             "repository" => repository
           },
           status: :open
         }
       ]}
      when kind == requested_kind and repository == requested_repository and
             is_binary(instruction_ref) and
             byte_size(instruction_ref) > 0 ->
        {:ok, instruction_ref}

      _invalid ->
        {:error, {:invalid_state_record, :instruction_ref}}
    end
  end

  defp task_instruction_ref(%{"instruction_ref" => instruction_ref}, _binding),
    do: {:ok, instruction_ref}

  defp task_repository("engineering", value) when is_binary(value), do: :ok
  defp task_repository("engineering", nil), do: {:error, :task_repository_required}
  defp task_repository("incident", value) when is_nil(value) or is_binary(value), do: :ok
  defp task_repository(_kind, _repository), do: {:error, {:invalid_state_record, :repository}}

  # The selector names a source inside the proposed task's own repository. It is
  # carried into the new linked session after confirmation; it never rebinds the
  # current workspace and never turns a read-only companion into a writable one.
  defp task_repository_source(_repository, nil), do: {:ok, nil}
  defp task_repository_source(nil, _source), do: {:error, :task_repository_source_unscoped}

  defp task_repository_source(_repository, source) do
    case RepositorySource.parse(source) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp goal_repository_scope(arguments, session) do
    writable = arguments["writable_repository"]
    read_only = arguments["read_only_repositories"]

    expected_read_only =
      case session.repository_context do
        %{"read_only_repositories" => repositories} when is_list(repositories) -> repositories
        _none -> []
      end

    expected_read_only = [session.repository_ref | expected_read_only] |> Enum.reject(&is_nil/1)

    writable_valid =
      arguments["authority"] != "repository_write" or writable == session.repository_ref

    read_only_valid =
      is_list(read_only) and Enum.all?(read_only, &(&1 in expected_read_only))

    if writable_valid and read_only_valid,
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp task_prompt(arguments, instruction_ref) do
    [
      arguments["prompt"],
      "Success checks: " <> Enum.join(arguments["success_checks"], "; "),
      "Authority limits: " <> Enum.join(arguments["authority_limits"], "; "),
      "Instruction: " <> instruction_ref,
      "Sources: " <> Enum.join(arguments["source_refs"], ", ")
    ]
    |> Enum.join("\n\n")
  end
end
