defmodule Responder.Coop.API do
  @moduledoc """
  Small Coop session API used by admission execution.

  The behavior keeps deterministic orchestration tests independent of sockets;
  `Responder.Coop.Client` is the production Unix-socket implementation.
  """

  @callback operation_by_key(client :: term(), key :: String.t()) ::
              {:ok, map()} | :not_found | {:error, term()}
  @doc """
  Reports the versioned repository capabilities of the worker that runs, or will
  run, a session: `repository_freshness_receipt_versions` (freshness receipt
  version 2) and `repository_source_selector_versions` (selector contract
  version 1). Selector-bound work is never created on a worker missing either.
  """
  @callback capabilities(client :: term()) :: {:ok, map()} | {:error, term()}
  @callback capabilities(client :: term(), session :: term()) ::
              {:ok, map()} | {:error, term()}
  @typedoc """
  The authorized source a new repository-backed session starts from.

  `nil` means workspace-free work. Create and fence carry the identical value so
  a fence request hashes exactly what create would have sent.
  """
  @type repository_source :: map() | nil

  @callback create_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}
  @callback create_bound_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              responder_binding :: map(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}
  @callback fence_create_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}
  @callback fence_bound_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              responder_binding :: map(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks create_bound_session: 6,
                      fence_bound_session: 6,
                      capabilities: 1,
                      capabilities: 2
  @callback get_session(client :: term(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  # Optional: a worker whose daemon predates the inspection export does not serve
  # it, and an adapter that cannot ask must leave the evidence unknown rather
  # than record an absence as an observation.
  @callback get_session_evidence(client :: term(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback list_events(
              client :: term(),
              session_id :: String.t(),
              after_sequence :: non_neg_integer(),
              limit :: pos_integer()
            ) :: {:ok, [map()]} | {:error, term()}
  @callback get_changes(client :: term(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback get_changes_page(
              client :: term(),
              session_id :: String.t(),
              patch_offset :: non_neg_integer(),
              patch_limit :: pos_integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback run_review(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_review_patch(
              client :: term(),
              artifact_id :: String.t(),
              expected_sha256 :: String.t(),
              expected_bytes :: pos_integer()
            ) :: {:ok, binary()} | {:error, term()}
  @callback get_session_review_patch(
              client :: term(),
              session_id :: String.t(),
              artifact_id :: String.t(),
              expected_sha256 :: String.t(),
              expected_bytes :: pos_integer()
            ) :: {:ok, binary()} | {:error, term()}
  @callback close_session(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback plan_discard(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              accept_dirty :: boolean(),
              accept_unmerged :: boolean()
            ) :: {:ok, map()} | {:error, term()}
  @callback discard_session(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              plan_operation_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback submit_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              prompt :: String.t(),
              schema :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback fence_submit_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              prompt :: String.t(),
              schema :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback submit_turn_with_artifacts(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              prompt :: String.t(),
              schema :: map(),
              artifacts :: [map()]
            ) :: {:ok, map()} | {:error, term()}
  @callback fence_submit_turn_with_artifacts(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              prompt :: String.t(),
              schema :: map(),
              artifacts :: [map()]
            ) :: {:ok, map()} | {:error, term()}
  @callback get_turn(client :: term(), session_id :: String.t(), turn_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback get_output_artifact(
              client :: term(),
              session_id :: String.t(),
              turn_id :: String.t(),
              artifact_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback cancel_turn(
              client :: term(),
              session_id :: String.t(),
              turn_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback validate_candidate(
              client :: term(),
              session_id :: String.t(),
              turn_id :: String.t(),
              key :: String.t(),
              candidate_sha256 :: String.t(),
              verdict :: :accept | {:reject, [String.t()]}
            ) :: {:ok, map()} | {:error, term()}

  @callback checkpoint_workspace(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: pos_integer()
            ) :: {:ok, map()} | {:error, term()}

  @callback submit_frozen_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              submission :: map(),
              responder_binding :: map() | nil,
              artifacts :: [map()]
            ) :: {:ok, map()} | {:error, term()}

  @callback fence_frozen_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              submission :: map(),
              responder_binding :: map() | nil,
              artifacts :: [map()]
            ) :: {:ok, map()} | {:error, term()}

  @callback validate_frozen_candidate(
              client :: term(),
              session_id :: String.t(),
              turn_id :: String.t(),
              key :: String.t(),
              attempt :: pos_integer(),
              candidate_sha256 :: String.t(),
              verdict :: :accept | {:reject, [String.t()]}
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks submit_turn_with_artifacts: 7,
                      fence_submit_turn_with_artifacts: 7,
                      list_events: 4,
                      get_changes: 2,
                      get_changes_page: 4,
                      get_session_review_patch: 5,
                      run_review: 4,
                      get_review_patch: 4,
                      plan_discard: 6,
                      discard_session: 4,
                      submit_frozen_turn: 7,
                      fence_frozen_turn: 7,
                      validate_frozen_candidate: 7,
                      checkpoint_workspace: 4,
                      get_session_evidence: 2
end
