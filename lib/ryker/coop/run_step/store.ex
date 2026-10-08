defmodule Ryker.Coop.RunStep.Store do
  @moduledoc """
  The custody a run keeps for `Ryker.Coop.RunStep`: the run as it is now, its
  lease, the keys its remote effects are made under, and a record of each way
  it can go. Self-analysis keeps it in `Ryker.Improvement.Analyses`, repository
  reading in `Ryker.RepositoryKnowledge.Custody`. Every write is made under
  the claim's lease and answers `{:ok, value}` or why not.
  """

  @typedoc "A worker's claim on one run's lease."
  @type claim :: map()
  @typedoc "A write's answer under the lease."
  @type result :: {:ok, term()} | {:error, term()}

  @doc "The run as the database holds it now."
  @callback current(run_id :: Ecto.UUID.t()) :: struct()

  @doc "Extends the claim's lease by `seconds`."
  @callback renew(claim(), seconds :: pos_integer()) :: result()

  @doc "Runs `callback` in a transaction that holds the claim's lease."
  @callback with_lease(claim(), callback :: (-> result())) :: result()

  @doc "The row the claim owns, locked, inside `with_lease/2`'s transaction."
  @callback fetch_and_lock_owned_in_transaction!(claim()) :: struct()

  @doc "The key a remote effect of `run` is made under, so a repeat finds it."
  @callback operation_key(run :: struct(), phase :: :create | :submit | :cancel) :: String.t()

  @doc "Freezes the session revision a turn is submitted against, before it is sent."
  @callback freeze_submit(claim(), run_id :: Ecto.UUID.t(), revision :: pos_integer()) ::
              result()

  @doc "Binds the run to the turn Coop made for it."
  @callback bind_turn(
              claim(),
              run_id :: Ecto.UUID.t(),
              session_id :: String.t(),
              turn_id :: String.t()
            ) :: result()

  @doc "Keeps the answer a turn offers, or refuses it."
  @callback record_candidate(claim(), run_id :: Ecto.UUID.t(), turn :: map(), producer :: map()) ::
              result()

  @doc "Confirms the kept answer is the one the finished turn accepted."
  @callback confirm_candidate(claim(), run_id :: Ecto.UUID.t(), turn :: map()) :: result()

  @doc "Applies the accepted answer with the finished turn as its stop proof."
  @callback apply_result(claim(), run_id :: Ecto.UUID.t(), turn :: map()) :: result()

  @doc "Records a turn that ended without an answer, as its stop proof."
  @callback fail(claim(), run_id :: Ecto.UUID.t(), reason :: atom(), turn :: map()) :: result()

  @doc "Ends the attempt for `reason`, without mistaking it for one that answered."
  @callback end_attempt(claim(), run_id :: Ecto.UUID.t(), reason :: atom()) :: result()

  @doc "Keeps a finished turn's terminal state as the run's stop proof."
  @callback record_stop(claim(), run_id :: Ecto.UUID.t(), turn :: map()) :: result()

  @doc "Stops a run whose turn Coop never received."
  @callback record_unsubmitted_stop(claim(), run_id :: Ecto.UUID.t(), session_id :: String.t()) ::
              result()

  @doc "Stops a run whose session it can no longer use, before a turn existed."
  @callback record_unaddressable_stop(claim(), run_id :: Ecto.UUID.t(), code :: String.t()) ::
              result()

  @doc "Stops a run that ended before its session was asked for."
  @callback record_uncreated_stop(claim(), run_id :: Ecto.UUID.t()) :: result()

  @doc "Stops a run whose create or submit Coop reports failed."
  @callback record_failed_operation(
              claim(),
              run_id :: Ecto.UUID.t(),
              phase :: :create | :submit,
              operation :: map()
            ) :: result()

  @doc "Stops a run past every window a Coop turn could still answer in."
  @callback record_expired_stop(claim(), run_id :: Ecto.UUID.t(), seconds :: pos_integer()) ::
              result()
end
