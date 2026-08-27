defmodule Responder.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @moduletag :database
      alias Responder.Repo
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(Responder.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(owner) end)
  end
end
