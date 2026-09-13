defmodule Ryker.Publication.GitCommandAPI do
  @moduledoc false

  @callback run(Path.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, term()}
end
