defmodule Ryker.Records.Response.Query do
  @moduledoc "Answers to questions Ryker asked, for every read of `episode_state_record_responses`."
  use Ryker, :query
  alias Ryker.Records.Response

  def all, do: from(responses in Response, as: :episode_state_record_responses)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_state_record_responses: r], r.record_id == ^record_id)

  @doc "The option the latest answer to question `record_id` chose: its index, or its words."
  def latest_choice(record_id) do
    from(r in by_record_id(record_id),
      order_by: [desc: r.inserted_at],
      limit: 1,
      select: {r.choice_index, r.choice}
    )
  end
end
