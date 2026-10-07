defmodule Ryker.Work do
  @moduledoc """
  What the console asks of the Work context: how a model target and its
  parts read, and the path facts a worker reported. Each forwards to the
  module that owns it (`Ryker.Work.ExecutionTarget`, `Ryker.Work.ActivityPaths`),
  so the console never reaches below this one
  (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.Work.{ActivityPaths, ExecutionTarget}

  @doc "A saved model target, or a kind of work's list of them, as the console shows it."
  defdelegate present_target(target), to: ExecutionTarget, as: :present

  @doc "A model target's model, effort, provider and account, or nil for a shape Ryker does not know."
  @spec target_parts(String.t() | nil) :: map() | nil
  defdelegate target_parts(target), to: ExecutionTarget, as: :parts

  @doc "A reasoning effort in words."
  @spec effort_name(String.t()) :: String.t()
  defdelegate effort_name(effort), to: ExecutionTarget

  @doc "A model provider's name."
  @spec provider_name(String.t()) :: String.t()
  defdelegate provider_name(provider), to: ExecutionTarget

  @doc "The bounded path facts a worker reported for a tool call, or nil."
  defdelegate activity_paths(context), to: ActivityPaths, as: :sanitize
end
