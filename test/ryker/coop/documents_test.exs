defmodule Ryker.Coop.DocumentsTest do
  # Self-analysis, learning and repository reading each held these checks
  # until 2026-10-08, and admission and Work each held the candidate's.
  use ExUnit.Case, async: true
  alias Ryker.Coop.Documents
  alias Ryker.Crypto

  @isolated %{
    "controller_tools_digest" => nil,
    "workspace_task" => nil,
    "repository_read_only" => true,
    "project_env" => false,
    "project_mcp" => false,
    "companions" => []
  }

  test "a session is isolated only with nothing of Ryker's or the project's loaded" do
    assert Documents.isolated_session?(@isolated)
    assert Documents.isolated_session?(Map.delete(@isolated, "companions"))

    for {field, value} <- [
          {"controller_tools_digest", "sha256:abc"},
          {"workspace_task", %{}},
          {"repository_read_only", false},
          {"project_env", true},
          {"project_mcp", nil},
          {"companions", [%{"repository" => "other"}]}
        ] do
      refute Documents.isolated_session?(Map.put(@isolated, field, value)), field
    end
  end

  test "a turn is exact when it is the session's, with a keepable id, and the one expected" do
    turn = %{"id" => "turn-1", "session_id" => "session-1"}

    assert Documents.exact_turn?(turn, "session-1", nil)
    assert Documents.exact_turn?(turn, "session-1", "turn-1")
    refute Documents.exact_turn?(turn, "session-1", "turn-2")
    refute Documents.exact_turn?(turn, "session-2", nil)
    refute Documents.exact_turn?(%{turn | "id" => ""}, "session-1", nil)
    refute Documents.exact_turn?(%{turn | "id" => String.duplicate("t", 1025)}, "session-1", nil)
  end

  test "a candidate answer is kept only when its digest matches its message" do
    message = ~s({"answer":"yes"})
    sha256 = Crypto.sha256_hex(message)

    assert Documents.candidate(%{"attempt" => 2, "message" => message, "sha256" => sha256}) ==
             {:ok, message, sha256, 2}

    assert Documents.candidate(%{"attempt" => 2, "message" => message <> " ", "sha256" => sha256}) ==
             {:error, {:coop_protocol_error, :candidate_digest}}

    assert Documents.candidate(%{"attempt" => 0, "message" => message, "sha256" => sha256}) ==
             {:error, {:coop_protocol_error, :candidate}}

    assert Documents.candidate(nil) == {:error, {:coop_protocol_error, :candidate}}
  end
end
