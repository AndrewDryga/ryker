defmodule Ryker.Publication.GateOutput do
  @moduledoc """
  The complete output of a failed review gate, for the task's fix round.

  Andrew, 2026-09-28: "Ryker should get full access to errors, warnings and all
  other output to work, like any llm model would, it's a sandbox!!" Coop serves
  a review gate's complete stdout and stderr page by page from the job's own
  logs, with no opt-in, and says plainly when it could not capture or keep
  them. The Coop API adapter reads it with the optional
  `read_review_gate_output/4` (`Ryker.Coop.API`); a worker without the
  endpoint leaves the output unread, and the fix round tells the agent to run
  the gate itself.

  After a failed gate's review, the publication executor reads every page and
  keeps the output as a text input artifact, the file the fix turn is handed,
  with the host remembering what it kept beside the review. A read is best
  effort, like session evidence: one that fails changes nothing about the
  review it follows.
  """
  alias Ryker.Adapter
  alias Ryker.Artifacts
  alias Ryker.Maps
  alias Ryker.Publication.Publication
  alias Ryker.Reference

  # The file a fix turn is handed keeps the end of a longer output, leaving
  # room under Coop's per-turn input limit for anything a person attaches.
  @file_bytes 4 * 1_024 * 1_024
  # A reader that never says it is done is not read forever.
  @maximum_pages 4_096
  @maximum_reason_bytes 1_024
  @name "gate-output.txt"
  @source_kind "publication-review"

  @doc """
  Reads and keeps a failed gate's output: `%{"status" => "read", "artifact" =>
  descriptor, "bytes" => total}`, `%{"status" => "lost", "reason" => reason}`
  when Coop could not capture or keep it, or nil when nothing could be read.
  """
  @spec capture(module(), term(), Publication.t(), map()) :: map() | nil
  def capture(api, client, %Publication{} = publication, review) do
    captured =
      with true <- reader?(api),
           {:ok, output, total, incomplete} <-
             read(api, client, review["session_id"], review["operation_id"], nil, "", 0, 0),
           {:ok, artifact} <- keep(publication, output) do
        %{"artifact" => descriptor(artifact), "bytes" => total, "status" => "read"}
        |> with_incomplete(incomplete)
      else
        {:lost, reason} -> %{"reason" => reason, "status" => "lost"}
        _unread -> nil
      end

    # Whatever came back, the review it follows is stored all the same.
    case prepare(captured) do
      {:ok, output} -> output
      {:error, _reason} -> nil
    end
  rescue
    error ->
      Ryker.Rescued.log("Gate output capture", error, __STACKTRACE__)
      nil
  catch
    :exit, _reason -> nil
  end

  @doc "What custody may store beside a review: nil or one of `capture/4`'s answers."
  @spec prepare(term()) :: {:ok, map() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}

  def prepare(%{"artifact" => artifact, "bytes" => total, "status" => "read"} = output)
      when is_integer(total) and total >= 0 do
    cond do
      not Maps.exact_keys?(output, ~w(artifact bytes status), ~w(incomplete)) ->
        {:error, {:invalid_publication_gate_output, :shape}}

      not descriptor?(artifact) ->
        {:error, {:invalid_publication_gate_output, :read}}

      Map.has_key?(output, "incomplete") and
          not Reference.valid?(output["incomplete"], @maximum_reason_bytes) ->
        {:error, {:invalid_publication_gate_output, :incomplete}}

      true ->
        {:ok, output}
    end
  end

  def prepare(%{"reason" => reason, "status" => "lost"} = output) when map_size(output) == 2 do
    if Reference.valid?(reason, @maximum_reason_bytes),
      do: {:ok, output},
      else: {:error, {:invalid_publication_gate_output, :lost}}
  end

  def prepare(_output), do: {:error, {:invalid_publication_gate_output, :shape}}

  @doc "The last `bytes` of a kept output, cut at a character boundary, or nil."
  @spec ending(map() | nil, pos_integer()) :: String.t() | nil
  def ending(%{"status" => "read", "artifact" => %{"artifact_ref" => ref}}, bytes) do
    case Artifacts.fetch_many([ref]) do
      {:ok, [artifact]} -> tail(artifact.data, bytes)
      {:error, _reason} -> nil
    end
  end

  def ending(_output, _bytes), do: nil

  defp reader?(api),
    do: Adapter.implements?(api, read_review_gate_output: 4)

  defp read(_api, _client, _session, _operation, _cursor, _kept, _total, @maximum_pages),
    do: {:error, :gate_output_unfinished}

  defp read(api, client, session, operation, cursor, kept, total, pages) do
    case api.read_review_gate_output(client, session, operation, cursor) do
      {:ok, %{"output" => chunk, "next_cursor" => next} = page}
      when is_binary(chunk) and (is_nil(next) or is_binary(next)) ->
        kept = raw_tail(kept <> chunk, @file_bytes)
        total = total + byte_size(chunk)

        if is_nil(next),
          do: {:ok, kept, total, incomplete(page)},
          else: read(api, client, session, operation, next, kept, total, pages + 1)

      {:ok, %{"lost" => reason}} when is_binary(reason) ->
        reason = reason |> readable() |> String.byte_slice(0, @maximum_reason_bytes)
        {:lost, if(String.trim(reason) == "", do: "Coop gave no reason.", else: reason)}

      _unreadable ->
        {:error, :gate_output_unreadable}
    end
  end

  # Coop keeps the first 64 MiB of a gate that prints without end and says so
  # on every page; its last page's word is what the fix turn hears.
  defp incomplete(%{"complete" => false} = page) do
    reason =
      case page["incomplete"] do
        reason when is_binary(reason) ->
          reason |> readable() |> String.byte_slice(0, @maximum_reason_bytes) |> String.trim()

        _missing ->
          ""
      end

    if reason == "", do: "Coop kept only part of what the gate printed.", else: reason
  end

  defp incomplete(_page), do: nil

  defp with_incomplete(output, nil), do: output
  defp with_incomplete(output, reason), do: Map.put(output, "incomplete", reason)

  # One file per review generation: a retried read keeps the same file.
  defp keep(publication, output) do
    Artifacts.put(%{
      data: if(output == "", do: "(the gate printed nothing)\n", else: readable(output)),
      media_type: "text/plain",
      name: @name,
      source_kind: @source_kind,
      source_ref: "#{publication.ref}:g#{publication.review_generation}"
    })
  end

  defp descriptor(artifact) do
    %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }
  end

  defp descriptor?(%{"artifact_ref" => ref, "bytes" => bytes, "name" => @name} = descriptor) do
    map_size(descriptor) == 6 and is_binary(ref) and is_integer(bytes) and bytes > 0 and
      descriptor["media_type"] == "text/plain" and descriptor["status"] == "available" and
      is_binary(descriptor["sha256"])
  end

  defp descriptor?(_artifact), do: false

  # Terminal output is bytes: a NUL or an invalid sequence would make the whole
  # file unreadable as text, so neither is kept.
  defp readable(output),
    do: output |> String.replace(<<0>>, "") |> String.replace_invalid() |> tail(@file_bytes)

  defp tail(text, bytes) when byte_size(text) <= bytes, do: text

  defp tail(text, bytes),
    do: String.byte_slice(text, byte_size(text) - bytes, bytes)

  # While paging the bytes may split a character; `readable/1` mends it once.
  defp raw_tail(bytes, maximum) when byte_size(bytes) <= maximum, do: bytes
  defp raw_tail(bytes, maximum), do: binary_part(bytes, byte_size(bytes) - maximum, maximum)
end
