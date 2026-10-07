defmodule Ryker.Records.ResponseQuery do
  @moduledoc "Answers to questions Ryker asked, for every read of `episode_state_record_responses`."
  import Ecto.Query
  alias Ryker.Records.Response

  def all, do: from(responses in Response, as: :episode_state_record_responses)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_state_record_responses: r], r.record_id == ^record_id)
end
