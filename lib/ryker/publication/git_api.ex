defmodule Ryker.Publication.GitAPI do
  @moduledoc false

  alias Ryker.Publication.Request

  @callback publish_candidate(Request.t(), repository :: map(), binding :: map()) ::
              {:ok, %{branch_ref: String.t(), commit_sha: String.t()}} | {:error, term()}
end
