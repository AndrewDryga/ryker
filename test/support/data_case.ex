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
    options = [shared: not tags[:async]]

    options =
      if isolation = tags[:isolation], do: [{:isolation, isolation} | options], else: options

    # A long accelerated simulation owns one connection for its whole run.
    options =
      if timeout = tags[:ownership_timeout],
        do: [{:ownership_timeout, timeout} | options],
        else: options

    owner = Sandbox.start_owner!(Responder.Repo, options)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
  end
end
