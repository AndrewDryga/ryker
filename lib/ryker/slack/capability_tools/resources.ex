defmodule Ryker.Slack.CapabilityTools.Resources do
  @moduledoc """
  Bookmarks, canvases and files as the model may see them: bounded, typed and
  addressed by server-issued source refs.
  """

  alias Ryker.Slack.CapabilityTools.Arguments
  alias Ryker.Slack.SourceRef

  @spec normalize_bookmarks(term(), String.t(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def normalize_bookmarks(bookmarks, workspace_ref, channel_ref)
      when is_list(bookmarks) and length(bookmarks) <= 100 do
    bookmarks
    |> Enum.reduce_while({:ok, []}, fn bookmark, {:ok, normalized} ->
      case normalize_bookmark(bookmark, workspace_ref, channel_ref) do
        {:ok, resource} -> {:cont, {:ok, [resource | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_bookmarks(_bookmarks, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  @spec normalize_bookmark(term(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def normalize_bookmark(
        %{
          "channel_id" => channel_ref,
          "id" => bookmark_ref,
          "title" => title,
          "type" => type
        } = bookmark,
        workspace_ref,
        channel_ref
      )
      when is_binary(bookmark_ref) and is_binary(title) and is_binary(type) do
    {:ok,
     %{
       "kind" => "bookmark",
       "link" => optional_resource_text(bookmark["link"], 8_192),
       "resource_type" => type,
       "source_ref" => SourceRef.bookmark(workspace_ref, channel_ref, bookmark_ref),
       "target_source_ref" => bookmark_target(bookmark, workspace_ref, channel_ref),
       "title" => bounded_resource_text(title, 1_024)
     }
     |> drop_nil_values()}
  rescue
    _error -> {:error, :slack_protocol_error}
  end

  def normalize_bookmark(_bookmark, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp bookmark_target(%{"entity_id" => entity_ref, "type" => "file"}, workspace_ref, channel_ref)
       when is_binary(entity_ref),
       do: SourceRef.file(workspace_ref, channel_ref, entity_ref)

  defp bookmark_target(
         %{"entity_id" => entity_ref, "type" => "canvas"},
         workspace_ref,
         channel_ref
       )
       when is_binary(entity_ref),
       do: SourceRef.canvas(workspace_ref, channel_ref, entity_ref)

  defp bookmark_target(_bookmark, _workspace_ref, _channel_ref), do: nil

  @spec exact_bookmark(term(), map()) :: {:ok, map()} | {:error, atom()}
  def exact_bookmark(bookmarks, source) when is_list(bookmarks) do
    case Enum.find(bookmarks, fn
           %{"channel_id" => channel_ref, "id" => bookmark_ref} ->
             channel_ref == source.channel_ref and bookmark_ref == source.resource_ref

           _bookmark ->
             false
         end) do
      %{} = bookmark -> {:ok, bookmark}
      nil -> {:error, :slack_source_not_found}
    end
  end

  def exact_bookmark(_bookmarks, _source), do: {:error, :slack_protocol_error}

  # A file is readable through a channel it is actually shared in; a canvas
  # only through the channel it is linked to.
  @spec file_authorized(term(), map()) :: :ok | {:error, atom()}
  def file_authorized(%{} = file, %{channel_ref: channel_ref, kind: kind, resource_ref: file_ref}) do
    refs = file_channel_refs(file)

    authorized =
      file["id"] == file_ref and channel_ref in refs and
        (kind != :canvas or Map.get(file, "linked_channel_id", channel_ref) == channel_ref)

    if authorized, do: :ok, else: {:error, :unauthorized}
  end

  def file_authorized(_file, _source), do: {:error, :slack_protocol_error}

  @doc "Every channel Slack says this file is shared or linked in."
  @spec file_channel_refs(map()) :: [String.t()]
  def file_channel_refs(file) do
    direct =
      ~w(channels groups ims mpims)
      |> Enum.flat_map(fn field ->
        case file[field] do
          values when is_list(values) -> Enum.filter(values, &is_binary/1)
          _value -> []
        end
      end)

    shared =
      case file["shares"] do
        %{} = shares ->
          shares
          |> Map.values()
          |> Enum.filter(&is_map/1)
          |> Enum.flat_map(&Map.keys/1)

        _shares ->
          []
      end

    [file["linked_channel_id"] | direct ++ shared]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @spec file_document(term(), map()) :: {:ok, map()} | {:error, atom()}
  def file_document(%{"id" => file_ref} = file, %{kind: kind} = source)
      when is_binary(file_ref) and kind in [:canvas, :file] do
    title = file["title"] || file["name"] || file_ref
    {content, content_complete} = file_content(file)

    try do
      {:ok,
       %{
         "content" => content,
         "content_complete" => content_complete,
         "created" => optional_nonnegative_integer(file["created"]),
         "filetype" => optional_resource_text(file["filetype"], 128),
         "kind" => Atom.to_string(kind),
         "media_type" => optional_resource_text(file["mimetype"], 128),
         "permalink" => optional_resource_text(file["permalink"], 8_192),
         "size" => optional_nonnegative_integer(file["size"]),
         "source_context" => file_source_context(file, source),
         "title" => bounded_resource_text(title, 1_024),
         "updated" => optional_nonnegative_integer(file["updated"])
       }
       |> drop_nil_values()}
    rescue
      _error -> {:error, :slack_protocol_error}
    end
  end

  def file_document(_file, _source), do: {:error, :slack_protocol_error}

  defp file_source_context(file, source) do
    shares = file["shares"] || %{}

    originals =
      ~w(public private)
      |> Enum.flat_map(&(get_in(shares, [&1, source.channel_ref]) || []))
      |> Enum.filter(&(Map.get(&1, "team_id", source.workspace_ref) == source.workspace_ref))
      |> Enum.uniq_by(& &1["ts"])
      |> Enum.take(4)
      |> Enum.map(&file_share(&1, source))

    %{
      "channel_source_ref" => SourceRef.channel(source.workspace_ref, source.channel_ref),
      "origin" => "not_established",
      "shares" => originals,
      "coverage" => %{
        "basis" => "known_shares_in_requested_channel",
        "status" => "partial",
        "limit" => 4
      }
    }
  end

  defp file_share(share, source) do
    original =
      %{
        "source_ref" => SourceRef.message(source.workspace_ref, source.channel_ref, share["ts"]),
        "thread_source_ref" =>
          if(share["thread_ts"],
            do: SourceRef.thread(source.workspace_ref, source.channel_ref, share["thread_ts"])
          )
      }
      |> drop_nil_values()

    arguments = original |> Arguments.source_read_arguments(%{}) |> Map.put("limit", 20)
    Map.put(original, "source_read", %{"tool" => "read_slack_source", "arguments" => arguments})
  end

  defp file_content(file) do
    value = file["plain_text"] || file["preview_plain_text"] || file["preview"]

    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..(128 * 1_024) and
         :binary.match(value, <<0>>) == :nomatch do
      {value, is_binary(file["plain_text"]) and file["preview_is_truncated"] != true}
    else
      {nil, false}
    end
  end

  defp bounded_resource_text(value, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: value,
       else: raise(ArgumentError, "invalid Slack resource text")
  end

  defp optional_resource_text(nil, _maximum), do: nil
  defp optional_resource_text(value, maximum), do: bounded_resource_text(value, maximum)

  defp optional_nonnegative_integer(nil), do: nil
  defp optional_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp optional_nonnegative_integer(_value),
    do: raise(ArgumentError, "invalid Slack resource size")

  defp drop_nil_values(document),
    do: Map.reject(document, fn {_key, value} -> is_nil(value) end)
end
