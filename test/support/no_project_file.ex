defmodule Ryker.TestSupport.NoProjectFile do
  @moduledoc """
  The project setup reader every test gets unless it names one (config/test.exs): the
  repository has no `.agent/project.yaml`, so a working copy's job carries no
  check, and no test reaches GitHub for it.
  """

  def read(_binding, _repository, _path, _ref), do: {:ok, :not_found}
end
