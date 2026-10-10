defmodule Ryker.ControlPlane.WorkChanges do
  @moduledoc """
  Renders one snapshot-bound page of a Coop working copy for the web changes
  page.

  Diff reading is web-only: Slack links out to the exact retained snapshot and
  never pages a patch itself.
  """
  alias Ryker.Crypto
  alias Ryker.Text
  alias Ryker.Wording

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
         "message" => message(changes, patch),
         "patch_bytes" => changes["patch_bytes"],
         "patch_digest" => changes["patch_digest"],
         "patch_has_more" => changes["patch_has_more"],
         "patch_next_offset" => changes["patch_next_offset"],
         "patch_offset" => changes["patch_offset"]
       }}
    else
      false -> {:error, :work_diff_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def render(_work_ref, _changes), do: {:error, :work_diff_invalid}

  # What changed, in words: Ryker's own reference, the patch digest and its byte counts are
  # bookkeeping for the page's paging and checks, not for the person reading the change.
  defp message(changes, patch) do
    paths = path_lines(changes)
    total_paths = Enum.sum(Enum.map(@path_groups, &length(changes[&1])))

    continued =
      if changes["patch_offset"] > 0, do: ["Continued from the previous page."], else: []

    body =
      cond do
        total_paths == 0 and changes["patch_bytes"] == 0 ->
          ["No changes in this working copy."]

        patch == "" ->
          [count_line(total_paths) | continued] ++
            paths ++ ["These files changed, but there is no text change to show."]

        true ->
          [count_line(total_paths) | continued] ++ paths ++ ["", compact_patch(patch)]
      end

    footer =
      if changes["patch_has_more"],
        do: ["The rest of the changes is on the next page."],
        else: []

    Enum.join(body ++ footer, "\n")
  end

  defp count_line(total_paths),
    do: Wording.count(total_paths, "changed file") <> " in this working copy."

  defp path_lines(changes) do
    entries =
      Enum.flat_map(@path_groups, fn group ->
        Enum.map(changes[group], fn entry ->
          path = entry["path"] || "[non-UTF-8 path #{entry["path_bytes"]}]"
          path = Text.shorten(path, @maximum_path_characters)
          "#{group}: #{path} (#{entry["status"]})"
        end)
      end)

    shown = Enum.take(entries, @maximum_paths)
    omitted = length(entries) - length(shown)

    if omitted > 0,
      do: shown ++ [Wording.count(omitted, "more changed file") <> " not listed here."],
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

    # The types first, so the arithmetic only meets numbers: an offset Coop sent
    # as text raised and crashed the page (2026-10-04 review).
    valid =
      typed?(digest, bytes, offset, next, more) and byte_size(patch) == next - offset and
        more == next < bytes

    cond do
      not valid ->
        {:error, :work_diff_invalid}

      offset == 0 and not more and digest != Crypto.sha256_hex(patch) ->
        {:error, :work_diff_digest_mismatch}

      true ->
        :ok
    end
  end

  defp typed?(digest, bytes, offset, next, more) do
    Crypto.sha256_hex?(digest) and valid_patch_size?(bytes) and offset in 0..bytes//1 and
      next in offset..bytes//1 and is_boolean(more)
  end

  defp valid_patch_size?(value), do: is_integer(value) and value in 0..1_073_741_824

  defp compact_patch(patch) do
    if String.valid?(patch) and :binary.match(patch, <<0>>) == :nomatch do
      Text.shorten(patch, @maximum_patch_characters)
    else
      "This part of the changes is binary and is not shown."
    end
  end
end
