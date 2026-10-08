defmodule Ryker.Work.CodeEditingSetup do
  @moduledoc "Read-only setup facts; connection support is not proof of worker readiness."
  alias Ryker.Adapter
  alias Ryker.Config

  def checkpoint_supported? do
    work = Config.get_env(:work) || %{}
    api = if is_map(work), do: work[:api], else: Keyword.get(work, :api)

    Adapter.implements?(api, checkpoint_workspace: 4)
  end
end
