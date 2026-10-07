defmodule Ryker.Work.CandidateResponseQuery do
  @moduledoc "Each result a Work turn returned, for every read of `work_candidate_responses`."
  import Ecto.Query
  alias Ryker.Work.CandidateResponse

  def all, do: from(responses in CandidateResponse, as: :work_candidate_responses)

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
