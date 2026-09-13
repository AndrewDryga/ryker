defmodule Ryker.Publication.Publisher do
  @moduledoc """
  Trusted draft-publication boundary.

  Implementations receive one exact reviewed request and a host-owned binding.
  They may create or update a draft pull request, but never merge or deploy it.
  """

  alias Ryker.Publication.Request

  @callback publish(Request.t(), binding :: term()) :: {:ok, map()} | {:error, term()}
end
