defmodule Ryker.Work.CandidateResponse.Query do
  @moduledoc "Each result a Work turn returned, for every read of `work_candidate_responses`."
  import Ecto.Query
  alias Ryker.Work.{CandidateResponse, Turn}

  def all, do: from(responses in CandidateResponse, as: :work_candidate_responses)

  @doc "Result `attempt` of turn `turn_id`."
  def by_attempt(turn_id, attempt) do
    where(
      all(),
      [work_candidate_responses: r],
      r.turn_id == ^turn_id and r.candidate_attempt == ^attempt
    )
  end

  @doc """
  The latest `limit` results among `attempts`, a list of `{turn_id,
  candidate_attempts}`, of turns that keep their bodies.
  """
  def latest_of_attempts(attempts, limit) do
    chosen =
      Enum.reduce(attempts, dynamic(false), fn {turn_id, numbers}, chosen ->
        dynamic(
          [response],
          ^chosen or (response.turn_id == ^turn_id and response.candidate_attempt in ^numbers)
        )
      end)

    from(response in all(),
      join: owner in Turn,
      on: owner.id == response.turn_id,
      where: ^chosen,
      where: is_nil(owner.operational_pruned_at),
      order_by: [
        desc: response.recorded_at,
        desc: response.turn_id,
        desc: response.candidate_attempt
      ],
      limit: ^limit,
      select: response
    )
  end

  @doc "The result of `turn`'s current attempt."
  def current_attempt(turn), do: by_attempt(turn.id, turn.candidate_attempt)

  @doc "A turn's results that keep their bodies, in the order the turn returned them."
  def kept_for_turn(turn_id) do
    all()
    |> where(
      [work_candidate_responses: r],
      r.turn_id == ^turn_id and is_nil(r.operational_pruned_at)
    )
    |> order_by([work_candidate_responses: r], asc: r.candidate_attempt)
  end
end
