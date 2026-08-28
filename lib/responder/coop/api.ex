defmodule Responder.Coop.API do
  @moduledoc """
  Small Coop session API used by admission execution.

  The behavior keeps deterministic orchestration tests independent of sockets;
  `Responder.Coop.Client` is the production Unix-socket implementation.
  """

  @callback operation_by_key(client :: term(), key :: String.t()) ::
              {:ok, map()} | :not_found | {:error, term()}
  @callback create_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_session(client :: term(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback close_session(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback submit_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              prompt :: String.t(),
              schema :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_turn(client :: term(), session_id :: String.t(), turn_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback validate_candidate(
              client :: term(),
              session_id :: String.t(),
              turn_id :: String.t(),
              key :: String.t(),
              candidate_sha256 :: String.t(),
              verdict :: :accept | {:reject, [String.t()]}
            ) :: {:ok, map()} | {:error, term()}
end
