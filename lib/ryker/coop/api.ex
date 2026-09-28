defmodule Ryker.Coop.API do
  @moduledoc """
  The Coop session API admission, Work, learning and cleanup execute through.

  The behaviour keeps deterministic orchestration tests independent of
  transports. `Ryker.CoopFleet.Client`, the only product transport, speaks it
  through durable commands to enrolled remote workers; the eval-only
  `Ryker.Coop.Client` in `evals/` speaks it over the owner-only Unix socket of
  the dedicated evaluation daemon. Callbacks a transport may lack are optional,
  and every caller checks `function_exported?/3` before relying on one.
  """

  @callback operation_by_key(client :: term(), key :: String.t()) ::
              {:ok, map()} | :not_found | {:error, term()}
  @doc """
  Reports the versioned repository capabilities of the worker that runs, or will
  run, a session: `repository_freshness_receipt_versions` (receipt version 2).
  Exact source selection is part of the frozen job, not a separate worker catalog.
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

  @doc "Prepare source authority before the caller rechecks its execution lease; never launches work."
  @callback prepare_create_session(
              term(),
              String.t(),
              String.t(),
              String.t(),
              repository_source()
            ) ::
              :ok | {:error, term()}
  @optional_callbacks prepare_create_session: 5

  def prepare_create_session(api, client, key, policy, task, source) do
    if function_exported?(api, :prepare_create_session, 5),
      do: api.prepare_create_session(client, key, policy, task, source),
      else: :ok
  end

  @callback create_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}
  @callback fence_create_session(
              client :: term(),
              key :: String.t(),
              policy :: String.t(),
              task :: String.t(),
              repository_source :: repository_source()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks capabilities: 1, capabilities: 2

  @doc """
  Whether some worker would take this new session now, asked without taking a
  slot. Optional: a transport to one fixed daemon has no placement to ask
  about, and its callers go ahead.
  """
  @callback accepts_session?(client :: term(), session :: term()) :: boolean()
  @optional_callbacks accepts_session?: 2

  @doc """
  Has Coop start an open, idle session's agent ahead of its first turn, so
  that turn starts on a running agent. Coop keeps it running for the job's
  `warm_idle_timeout_ms`.

  `{:error, :coop_worker_busy}` means the worker has other work that a
  prepare would hold up, and nothing was sent; ask again later. A key already
  sent is answered from its record. Optional: a transport without it leaves
  every session to start its agent on its first turn.
  """
  @callback prepare_session(client :: term(), session_id :: String.t(), key :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @optional_callbacks prepare_session: 3
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
  # Optional: one page of a review gate's complete stdout and stderr, from
  # `cursor` (nil for the first page), as `%{"output" => text, "next_cursor" =>
  # cursor | nil}`, or `%{"lost" => reason}` when Coop could not capture or keep
  # it. `Ryker.Publication.GateOutput` reads every page and hands the whole
  # output to the fix round.
  #
  # Waiting on Coop (2026-09-28): no Coop endpoint serves this read yet. Coop is
  # designing a paged or streamed read of the review gate's output from the
  # job's own logs, with no opt-in and explicit capture and retention failures.
  # When it ships, implement this callback in `Ryker.CoopFleet.Client` against
  # it; until then no output is read and a fix round tells the agent to run the
  # gate itself.
  @callback read_review_gate_output(
              client :: term(),
              session_id :: String.t(),
              review_operation_id :: String.t(),
              cursor :: String.t() | nil
            ) :: {:ok, map()} | {:error, term()}
  @callback publish_review(
              client :: term(),
              session_id :: String.t(),
              review_key :: String.t(),
              review_operation_id :: String.t(),
              publish_key :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, term()}
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
              controller_tools :: map() | nil,
              artifacts :: [map()]
            ) :: {:ok, map()} | {:error, term()}

  @callback fence_frozen_turn(
              client :: term(),
              session_id :: String.t(),
              key :: String.t(),
              expected_revision :: integer(),
              submission :: map(),
              controller_tools :: map() | nil,
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

  @optional_callbacks list_events: 4,
                      get_changes: 2,
                      get_changes_page: 4,
                      run_review: 4,
                      read_review_gate_output: 4,
                      publish_review: 6,
                      plan_discard: 6,
                      discard_session: 4,
                      submit_frozen_turn: 7,
                      fence_frozen_turn: 7,
                      validate_frozen_candidate: 7,
                      checkpoint_workspace: 4,
                      get_session_evidence: 2
end
