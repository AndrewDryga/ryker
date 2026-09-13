defmodule Ryker.ControlPlane.TranscriptCursor do
  @moduledoc """
  One deterministic total order over a conversation's merged transcript.

  Every transcript row has a sort key `{position, rank, identity}`:

    * `position` is the microsecond the row entered the transcript, taken from
      a column that never changes afterwards: the first revision of an input,
      the acceptance of a reply, the delivery of a platform message.
    * `rank` orders sources that share a microsecond: inputs, then replies,
      then platform messages, then publications.
    * `identity` names the logical row for the rest of its life. An input keeps
      its identity through every edit, delete and retention prune, so a page
      boundary drawn beside it can never move.

  A cursor is that key plus the conversation it belongs to, encoded opaquely.
  It is only ever compared with what the server already holds, but decoding
  still refuses any cursor that is malformed or names another conversation.
  """

  @version 1
  @ranks %{input: 0, reply: 1, action: 2, publication: 3}

  @type key :: {integer(), 0..3, String.t()}

  @spec rank(:input | :reply | :action | :publication) :: 0..3
  def rank(kind), do: Map.fetch!(@ranks, kind)

  @spec key(DateTime.t(), :input | :reply | :action | :publication, String.t()) :: key()
  def key(%DateTime{} = position, kind, identity) when is_binary(identity),
    do: {DateTime.to_unix(position, :microsecond), rank(kind), identity}

  @spec encode(String.t(), key()) :: String.t()
  def encode(conversation_id, {micros, rank, identity})
      when is_binary(conversation_id) and is_integer(micros) and rank in 0..3 and
             is_binary(identity) do
    %{"v" => @version, "c" => conversation_id, "t" => micros, "k" => rank, "i" => identity}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @spec decode(term(), String.t()) :: {:ok, key()} | :error
  def decode(cursor, conversation_id)
      when is_binary(cursor) and byte_size(cursor) in 1..2048 and is_binary(conversation_id) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"v" => @version, "c" => ^conversation_id, "t" => micros, "k" => rank, "i" => id}}
         when is_integer(micros) and rank in 0..3 and is_binary(id) and byte_size(id) in 1..512 <-
           Jason.decode(json) do
      {:ok, {micros, rank, id}}
    else
      _invalid -> :error
    end
  end

  def decode(_cursor, _conversation_id), do: :error
end
