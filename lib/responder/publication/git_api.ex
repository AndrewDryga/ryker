defmodule Responder.Publication.GitAPI do
  @moduledoc false

  alias Responder.Publication.Request

  @callback publish_candidate(Request.t(), repository :: map(), binding :: map()) ::
              {:ok, %{branch_ref: String.t(), commit_sha: String.t()}} | {:error, term()}
end
