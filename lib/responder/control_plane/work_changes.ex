defmodule Responder.ControlPlane.WorkChanges do
  @moduledoc """
  Renders one snapshot-bound page of a Coop working copy for the web changes
  page.

  Diff reading is web-only: Slack links out to the exact retained snapshot and
  never pages a patch itself.
  """

  @path_groups ~w(committed staged unstaged untracked conflicts)
  @maximum_paths 20
  @maximum_patch_characters 2_200
  @maximum_path_characters 180
  @page_bytes 2_400
  @work_ref ~r/\A(?:(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}|record:task_offer:[A-Za-z0-9_.:-]{1,220})\z/

  @spec page_bytes() :: pos_integer()
  def page_bytes, do: @page_bytes

  @spec render(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def render(work_ref, %{} = changes)
      when is_binary(work_ref) and map_size(changes) <= 32 do
    with {:ok, patch} <- patch(changes),
         true <- Regex.match?(@work_ref, work_ref),
         :ok <- path_groups(changes),
         :ok <- metadata(changes, patch) do
      {:ok,
       %{
         "message" => message(work_ref, changes, patch),
         "patch_bytes" => changes["patch_bytes"],
         "patch_digest" => changes["patch_digest"],
         "patch_has_more" => changes["patch_has_more"],
         "patch_next_offset" => changes["patch_next_offset"],
         "patch_offset" => changes["patch_offset"]
       }}
    else
      false -> {:error, :work_diff_invalid}
      {:error, _reason} = error -> error
    end
  end

  def render(_work_ref, _changes), do: {:error, :work_diff_invalid}

  defp message(work_ref, changes, patch) do
    paths = path_lines(changes)
    total_paths = Enum.sum(Enum.map(@path_groups, &length(changes[&1])))

    header = [
      "Workspace diff for #{work_ref}",
      "Snapshot: #{changes["patch_digest"]}",
      "Patch bytes: #{changes["patch_offset"]}-#{changes["patch_next_offset"]} of #{changes["patch_bytes"]}",
      "Changed paths: #{total_paths}"
    ]

    body =
      cond do
        total_paths == 0 and changes["patch_bytes"] == 0 ->
          ["No repository changes are present in this isolated working copy."]

        patch == "" ->
          paths ++ ["This page contains path changes but no textual patch bytes."]

        true ->
          paths ++ ["Patch page:", compact_patch(patch)]
      end

    footer =
      if changes["patch_has_more"],
        do: ["More patch bytes remain on the next page."],
        else: ["This is the final patch page."]

    Enum.join(header ++ body ++ footer, "\n")
  end

  defp path_lines(changes) do
    entries =
      Enum.flat_map(@path_groups, fn group ->
        Enum.map(changes[group], fn entry ->
          path = entry["path"] || "[non-UTF-8 path #{entry["path_bytes"]}]"
          path = compact_text(path, @maximum_path_characters)
          "#{group}: #{path} (#{entry["status"]})"
        end)
      end)

    shown = Enum.take(entries, @maximum_paths)
    omitted = length(entries) - length(shown)

    if omitted > 0,
      do: shown ++ ["#{omitted} additional changed paths are omitted from this compact page."],
      else: shown
  end

  defp patch(changes) do
    case Base.decode64(changes["patch"] || "") do
      {:ok, patch} -> {:ok, patch}
      :error -> {:error, :work_diff_invalid}
    end
  end

  defp path_groups(changes) do
    if Enum.all?(@path_groups, &valid_path_group?(changes[&1])),
      do: :ok,
      else: {:error, :work_diff_invalid}
  end

  defp valid_path_group?(entries) when is_list(entries) and length(entries) <= 10_000 do
    Enum.all?(entries, fn
      %{"status" => status} = entry when is_binary(status) and byte_size(status) in 1..120 ->
        valid_path?(entry["path"], entry["path_bytes"])

      _entry ->
        false
    end)
  end

  defp valid_path_group?(_entries), do: false

  defp valid_path?(path, _bytes)
       when is_binary(path) and byte_size(path) in 1..4_096 and is_binary(path),
       do: String.valid?(path) and :binary.match(path, <<0>>) == :nomatch

  defp valid_path?(nil, bytes) when is_binary(bytes) do
    case Base.decode64(bytes) do
      {:ok, value} -> byte_size(value) in 1..4_096 and :binary.match(value, <<0>>) == :nomatch
      :error -> false
    end
  end

  defp valid_path?(_path, _bytes), do: false

  defp metadata(changes, patch) do
    digest = changes["patch_digest"]
    bytes = changes["patch_bytes"]
    offset = changes["patch_offset"]
    next = changes["patch_next_offset"]
    more = changes["patch_has_more"]

    valid =
      Enum.all?([
        valid_digest?(digest),
        valid_patch_size?(bytes),
        valid_offset?(offset, 0, bytes),
        valid_offset?(next, offset, bytes),
        is_boolean(more),
        byte_size(patch) == next - offset,
        more == next < bytes
      ])

    cond do
      not valid ->
        {:error, :work_diff_invalid}

      offset == 0 and not more and digest != sha256(patch) ->
        {:error, :work_diff_digest_mismatch}

      true ->
        :ok
    end
  end

  defp valid_digest?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_patch_size?(value), do: is_integer(value) and value in 0..1_073_741_824

  defp valid_offset?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp compact_patch(patch) do
    if String.valid?(patch) and :binary.match(patch, <<0>>) == :nomatch do
      compact_text(patch, @maximum_patch_characters)
    else
      "[binary patch page omitted; verify it from Coop using the snapshot digest]"
    end
  end

  defp compact_text(value, maximum) do
    graphemes = String.graphemes(value)

    if length(graphemes) <= maximum,
      do: value,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
