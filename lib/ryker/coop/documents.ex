defmodule Ryker.Coop.Documents do
  @moduledoc """
  Checks on the documents a Coop worker returns, shared by every lane that
  runs a model turn: whether a session is isolated, whether a turn is the one
  expected, and a candidate answer whose digest matches its message.
  """
  alias Ryker.Crypto

  @doc """
  Whether `session` is isolated: no Ryker tools, no workspace task and no
  companions, its repository read-only, and neither the project's environment
  nor its MCP servers loaded. Retained messages go only to such a session.
  """
  @spec isolated_session?(map()) :: boolean()
  def isolated_session?(session) do
    is_nil(session["controller_tools_digest"]) and is_nil(session["workspace_task"]) and
      session["repository_read_only"] == true and session["project_env"] == false and
      session["project_mcp"] == false and Map.get(session, "companions", []) == []
  end

  @doc """
  Whether `turn` is a turn of the session `session_id` with an id Ryker can
  keep, and the `expected` one when a turn is expected (nil when not).
  """
  @spec exact_turn?(term(), String.t(), String.t() | nil) :: boolean()
  def exact_turn?(%{"id" => id, "session_id" => session_id}, session_id, expected)
      when is_binary(id) and byte_size(id) in 1..1024 and (is_nil(expected) or expected == id),
      do: true

  def exact_turn?(_turn, _session_id, _expected), do: false

  @doc """
  The message, digest and attempt of a candidate answer whose SHA-256 matches
  its message: `{:ok, message, sha256, attempt}`, or a
  `{:coop_protocol_error, :candidate | :candidate_digest}` error.
  """
  @spec candidate(term()) ::
          {:ok, String.t(), String.t(), pos_integer()}
          | {:error, {:coop_protocol_error, :candidate | :candidate_digest}}
  def candidate(%{"attempt" => attempt, "message" => message, "sha256" => sha256})
      when is_integer(attempt) and attempt > 0 and is_binary(message) and is_binary(sha256) do
    if Crypto.sha256_hex(message) == sha256,
      do: {:ok, message, sha256, attempt},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  def candidate(_candidate), do: {:error, {:coop_protocol_error, :candidate}}
end
