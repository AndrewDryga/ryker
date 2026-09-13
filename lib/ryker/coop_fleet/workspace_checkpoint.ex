defmodule Ryker.CoopFleet.WorkspaceCheckpoint do
  @moduledoc """
  Portable identity for one bounded remote writable-work checkpoint.

  The referenced artifact carries the tracked binary patch, selected untracked
  files, and exact Coop task projection. This document deliberately excludes
  worker-local paths, provider state, credentials, and transcript content.
  """

  alias Ryker.CoopFleet.Protocol

  @version 1
  @bundle_media_type "application/vnd.coop.workspace-checkpoint.v1+tar"
  @maximum_bundle_bytes 64 * 1_024 * 1_024
  @maximum_subtasks 64
  @maximum_manifest_bytes 1_024 * 1_024
  @maximum_checkpoint_files 4_096
  @maximum_task_files 128
  @maximum_path_bytes 1_024
  @maximum_encoded_path_bytes 1_368
  @fields ~w(version checkpoint_ref session_ref placement_generation repository_ref base_revision branch_ref committed_revision candidate_tree_sha256 task gate bundle created_at)
  @task_fields ~w(queue_id task_id id state subtasks state_sha256)
  @bundle_fields ~w(media_type sha256 byte_size)
  @manifest_fields ~w(version checkpoint_ref repository_ref base_revision branch_ref committed_revision candidate_tree_sha256 tracked_patch untracked_files task_projection gate_receipt)
  @manifest_entry_fields ~w(entry sha256 byte_size)
  @manifest_file_fields ~w(path_b64 entry mode sha256 byte_size)
  @task_projection_fields ~w(queue_id task_id id state state_sha256 files)
  @task_states ~w(todo in_progress blocked done)
  @gate_states ~w(not_run passed failed startup_error)
  @identity ~r/\A[0-9a-f]{32}\z/
  @revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @spec bundle_media_type() :: String.t()
  def bundle_media_type, do: @bundle_media_type

  @spec maximum_bundle_bytes() :: pos_integer()
  def maximum_bundle_bytes, do: @maximum_bundle_bytes

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(document) when is_binary(document) and byte_size(document) <= 1_048_576 do
    case Jason.decode(document) do
      {:ok, value} -> validate(value)
      {:error, _reason} -> {:error, {:invalid_workspace_checkpoint, :json}}
    end
  end

  def decode(_document), do: {:error, {:invalid_workspace_checkpoint, :document}}

  @spec decode_bundle_manifest(binary()) :: {:ok, map()} | {:error, term()}
  def decode_bundle_manifest(document)
      when is_binary(document) and byte_size(document) in 1..@maximum_manifest_bytes do
    case Jason.decode(document) do
      {:ok, value} -> validate_bundle_manifest(value)
      {:error, _reason} -> bundle_error(:json)
    end
  end

  def decode_bundle_manifest(_document), do: bundle_error(:document)

  @spec validate_bundle_manifest(term()) :: {:ok, map()} | {:error, term()}
  def validate_bundle_manifest(%{} = manifest) do
    with :ok <- manifest_exact_fields(manifest, @manifest_fields, :fields),
         true <- manifest["version"] == @version,
         :ok <- manifest_reference(manifest["checkpoint_ref"]),
         :ok <- manifest_reference(manifest["repository_ref"]),
         :ok <- manifest_revision(manifest["base_revision"]),
         :ok <- manifest_branch_ref(manifest["branch_ref"]),
         :ok <- manifest_revision(manifest["committed_revision"]),
         :ok <- manifest_digest(manifest["candidate_tree_sha256"]),
         {:ok, tracked_patch} <-
           manifest_entry(manifest["tracked_patch"], "workspace.patch", true),
         {:ok, untracked_files, entries, total} <-
           manifest_files(
             manifest["untracked_files"],
             "untracked",
             @maximum_checkpoint_files,
             MapSet.new(["manifest.json", "workspace.patch"]),
             tracked_patch["byte_size"]
           ),
         {:ok, task_projection, entries, total} <-
           task_projection(manifest["task_projection"], entries, total),
         {:ok, gate_receipt, _entries, total} <-
           gate_receipt(manifest["gate_receipt"], entries, total),
         true <- total <= @maximum_bundle_bytes do
      {:ok,
       manifest
       |> Map.put("tracked_patch", tracked_patch)
       |> Map.put("untracked_files", untracked_files)
       |> Map.put("task_projection", task_projection)
       |> Map.put("gate_receipt", gate_receipt)}
    else
      false -> bundle_error(:metadata)
      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error -> error
    end
  end

  def validate_bundle_manifest(_manifest), do: bundle_error(:document)

  @spec validate_pair(map(), map()) :: :ok | {:error, term()}
  def validate_pair(%{} = checkpoint, %{} = manifest) do
    identity =
      ~w(version checkpoint_ref repository_ref base_revision branch_ref committed_revision candidate_tree_sha256)

    cond do
      Enum.any?(identity, &(checkpoint[&1] != manifest[&1])) ->
        pair_error(:identity)

      Enum.any?(~w(queue_id task_id id state state_sha256), fn field ->
        checkpoint["task"][field] != manifest["task_projection"][field]
      end) ->
        pair_error(:task)

      checkpoint["gate"]["status"] == "not_run" and not is_nil(manifest["gate_receipt"]) ->
        pair_error(:gate)

      checkpoint["gate"]["status"] != "not_run" and
          (checkpoint["gate"]["revision"] != checkpoint["committed_revision"] or
             is_nil(manifest["gate_receipt"])) ->
        pair_error(:gate)

      true ->
        :ok
    end
  rescue
    _invalid -> pair_error(:document)
  end

  def validate_pair(_checkpoint, _manifest), do: pair_error(:document)

  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{} = checkpoint) do
    with :ok <- exact_fields(checkpoint, @fields, :fields),
         true <- checkpoint["version"] == @version,
         :ok <- reference(checkpoint["checkpoint_ref"], :checkpoint_ref),
         :ok <- reference(checkpoint["session_ref"], :session_ref),
         :ok <- positive(checkpoint["placement_generation"], :placement_generation),
         :ok <- reference(checkpoint["repository_ref"], :repository_ref),
         :ok <- revision(checkpoint["base_revision"], :base_revision),
         :ok <- branch_ref(checkpoint["branch_ref"], :branch_ref),
         :ok <- revision(checkpoint["committed_revision"], :committed_revision),
         :ok <- digest(checkpoint["candidate_tree_sha256"], :candidate_tree_sha256),
         :ok <- task(checkpoint["task"]),
         :ok <- gate(checkpoint["gate"]),
         :ok <- bundle(checkpoint["bundle"]),
         :ok <- timestamp(checkpoint["created_at"], :created_at) do
      {:ok, checkpoint}
    else
      false -> {:error, {:invalid_workspace_checkpoint, :version}}
      {:error, _reason} = error -> error
    end
  end

  def validate(_checkpoint), do: {:error, {:invalid_workspace_checkpoint, :document}}

  defp task(%{} = task) do
    with :ok <- exact_fields(task, @task_fields, :task),
         true <- is_binary(task["queue_id"]) and Regex.match?(@identity, task["queue_id"]),
         true <- is_binary(task["task_id"]) and Regex.match?(@identity, task["task_id"]),
         :ok <- reference(task["id"], :task_id),
         true <- task["state"] in @task_states,
         true <- is_list(task["subtasks"]) and length(task["subtasks"]) in 1..@maximum_subtasks,
         true <- Enum.all?(task["subtasks"], &is_boolean/1),
         :ok <- digest(task["state_sha256"], :task_state_sha256) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_workspace_checkpoint, :task}}
    end
  end

  defp task(_task), do: {:error, {:invalid_workspace_checkpoint, :task}}

  defp gate(%{"status" => "not_run"} = gate) do
    exact_fields(gate, ["status"], :gate)
  end

  defp gate(%{} = gate) do
    with :ok <- exact_fields(gate, ~w(status revision receipt_ref), :gate),
         true <- gate["status"] in (@gate_states -- ["not_run"]),
         :ok <- revision(gate["revision"], :gate_revision),
         :ok <- reference(gate["receipt_ref"], :gate_receipt_ref) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_workspace_checkpoint, :gate}}
    end
  end

  defp gate(_gate), do: {:error, {:invalid_workspace_checkpoint, :gate}}

  defp bundle(%{} = bundle) do
    with :ok <- exact_fields(bundle, @bundle_fields, :bundle),
         true <- bundle["media_type"] == @bundle_media_type,
         :ok <- digest(bundle["sha256"], :bundle_sha256),
         true <-
           is_integer(bundle["byte_size"]) and
             bundle["byte_size"] in 1..@maximum_bundle_bytes do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_workspace_checkpoint, :bundle}}
    end
  end

  defp bundle(_bundle), do: {:error, {:invalid_workspace_checkpoint, :bundle}}

  defp exact_fields(document, fields, field) do
    if Map.keys(document) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, {:invalid_workspace_checkpoint, field}}
  end

  defp reference(value, field) do
    if Protocol.reference?(value),
      do: :ok,
      else: {:error, {:invalid_workspace_checkpoint, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_workspace_checkpoint, field}}

  defp revision(value, field) do
    if is_binary(value) and Regex.match?(@revision, value),
      do: :ok,
      else: {:error, {:invalid_workspace_checkpoint, field}}
  end

  defp branch_ref(value, field) do
    if valid_branch_ref?(value),
      do: :ok,
      else: {:error, {:invalid_workspace_checkpoint, field}}
  end

  defp digest(value, field) do
    if Protocol.digest?(value),
      do: :ok,
      else: {:error, {:invalid_workspace_checkpoint, field}}
  end

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, {:invalid_workspace_checkpoint, field}}
    end
  end

  defp timestamp(_value, field), do: {:error, {:invalid_workspace_checkpoint, field}}

  defp task_projection(%{} = task, entries, total) do
    with :ok <- manifest_exact_fields(task, @task_projection_fields, :task_projection),
         true <- is_binary(task["queue_id"]) and Regex.match?(@identity, task["queue_id"]),
         true <- is_binary(task["task_id"]) and Regex.match?(@identity, task["task_id"]),
         :ok <- manifest_reference(task["id"]),
         true <- task["state"] in @task_states,
         :ok <- manifest_digest(task["state_sha256"]),
         true <- is_list(task["files"]) and length(task["files"]) in 1..@maximum_task_files,
         {:ok, files, entries, total} <-
           manifest_files(task["files"], "task", @maximum_task_files, entries, total) do
      {:ok, Map.put(task, "files", files), entries, total}
    else
      false -> bundle_error(:task_projection)
      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error -> error
    end
  end

  defp task_projection(_task, _entries, _total), do: bundle_error(:task_projection)

  defp gate_receipt(nil, entries, total), do: {:ok, nil, entries, total}

  defp gate_receipt(receipt, entries, total) do
    with {:ok, receipt} <- manifest_entry(receipt, "gate/receipt.json", false),
         false <- MapSet.member?(entries, receipt["entry"]) do
      {:ok, receipt, MapSet.put(entries, receipt["entry"]), total + receipt["byte_size"]}
    else
      true -> bundle_error(:duplicate_entry)
      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error -> error
    end
  end

  defp manifest_files(files, prefix, maximum, entries, total)
       when is_list(files) and length(files) <= maximum do
    files
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, [], entries, MapSet.new(), total},
      &reduce_manifest_file(&1, &2, prefix)
    )
    |> case do
      {:ok, normalized, entries, _paths, total} ->
        {:ok, Enum.reverse(normalized), entries, total}

      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error ->
        error
    end
  end

  defp manifest_files(_files, _prefix, _maximum, _entries, _total),
    do: bundle_error(:file_count)

  defp reduce_manifest_file(
         {file, index},
         {:ok, normalized, entries, paths, total},
         prefix
       ) do
    expected_entry = prefix <> "/" <> String.pad_leading(Integer.to_string(index), 6, "0")

    case manifest_file(file, expected_entry, entries, paths) do
      {:ok, file, entries, paths} ->
        continue_manifest_file(file, normalized, entries, paths, total)

      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error ->
        {:halt, error}
    end
  end

  defp continue_manifest_file(file, normalized, entries, paths, total) do
    next_total = total + file["byte_size"]

    if next_total <= @maximum_bundle_bytes,
      do: {:cont, {:ok, [file | normalized], entries, paths, next_total}},
      else: {:halt, bundle_error(:byte_size)}
  end

  defp manifest_file(%{} = file, expected_entry, entries, paths) do
    with :ok <- manifest_exact_fields(file, @manifest_file_fields, :file),
         true <- file["entry"] == expected_entry,
         false <- MapSet.member?(entries, expected_entry),
         true <- file["mode"] in [0o644, 0o755],
         :ok <- manifest_digest(file["sha256"]),
         true <-
           is_integer(file["byte_size"]) and file["byte_size"] in 0..@maximum_bundle_bytes,
         {:ok, path_bytes} <- manifest_path(file["path_b64"]),
         false <- MapSet.member?(paths, path_bytes) do
      {:ok, Map.put(file, "path_bytes", path_bytes), MapSet.put(entries, expected_entry),
       MapSet.put(paths, path_bytes)}
    else
      true -> bundle_error(:file)
      false -> bundle_error(:file)
      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error -> error
    end
  end

  defp manifest_file(_file, _expected_entry, _entries, _paths), do: bundle_error(:file)

  defp manifest_entry(%{} = entry, expected_entry, empty_allowed?) do
    with :ok <- manifest_exact_fields(entry, @manifest_entry_fields, :entry),
         true <- entry["entry"] == expected_entry,
         :ok <- manifest_digest(entry["sha256"]),
         true <- is_integer(entry["byte_size"]),
         true <- entry["byte_size"] in 0..@maximum_bundle_bytes,
         true <- empty_allowed? or entry["byte_size"] > 0 do
      {:ok, entry}
    else
      false -> bundle_error(:entry)
      {:error, {:invalid_workspace_checkpoint_bundle, _reason}} = error -> error
    end
  end

  defp manifest_entry(_entry, _expected_entry, _empty_allowed?), do: bundle_error(:entry)

  defp manifest_path(value) when is_binary(value) do
    with true <- byte_size(value) <= @maximum_encoded_path_bytes,
         {:ok, path_bytes} <- Base.decode64(value),
         true <- Base.encode64(path_bytes) == value,
         true <- byte_size(path_bytes) in 1..@maximum_path_bytes,
         :nomatch <- :binary.match(path_bytes, <<0>>),
         false <- :binary.first(path_bytes) == ?/,
         parts <- :binary.split(path_bytes, "/", [:global]),
         true <- Enum.all?(parts, &safe_path_part?/1) do
      {:ok, path_bytes}
    else
      _invalid -> bundle_error(:path)
    end
  end

  defp manifest_path(_value), do: bundle_error(:path)

  defp safe_path_part?(part), do: part not in [<<>>, ".", ".."]

  defp manifest_exact_fields(document, fields, reason) do
    if Map.keys(document) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: bundle_error(reason)
  end

  defp manifest_reference(value) do
    if Protocol.reference?(value),
      do: :ok,
      else: bundle_error(:reference)
  end

  defp manifest_revision(value) do
    if is_binary(value) and Regex.match?(@revision, value),
      do: :ok,
      else: bundle_error(:revision)
  end

  defp manifest_branch_ref(value) do
    if valid_branch_ref?(value), do: :ok, else: bundle_error(:branch_ref)
  end

  defp valid_branch_ref?(value) when is_binary(value) and byte_size(value) in 1..256 do
    parts = :binary.split(value, "/", [:global])

    valid_branch_name?(value) and Enum.all?(parts, &valid_branch_part?/1)
  end

  defp valid_branch_ref?(_value), do: false

  defp valid_branch_name?(value) do
    String.valid?(value) and value != "@" and not String.starts_with?(value, ["-", "/"]) and
      not String.ends_with?(value, ["/", "."]) and not String.contains?(value, ["..", "@{"]) and
      not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[\\]/u, value)
  end

  defp valid_branch_part?(part) do
    part != "" and not String.starts_with?(part, ".") and not String.ends_with?(part, ".lock")
  end

  defp manifest_digest(value) do
    if Protocol.digest?(value),
      do: :ok,
      else: bundle_error(:digest)
  end

  defp bundle_error(reason), do: {:error, {:invalid_workspace_checkpoint_bundle, reason}}
  defp pair_error(reason), do: {:error, {:invalid_workspace_checkpoint_pair, reason}}
end
