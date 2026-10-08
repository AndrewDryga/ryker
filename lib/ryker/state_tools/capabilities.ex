defmodule Ryker.StateTools.Capabilities do
  @moduledoc """
  The groups of state tools a Work turn may be given beyond the fixed ones,
  and the groups it gets when its configuration names none.

  The executor, the Work runtime, the briefing, the MCP router and the fixed
  tools each kept their own copy of both lists (2026-10-04 review); they read
  them here.
  """

  @known [:emisar_approvals, :event_waits, :publication, :schedules]
  @default [:event_waits, :publication, :schedules]

  @doc "Every group but Emisar approvals, which a turn gets only with an Emisar account."
  @spec default() :: [atom()]
  def default, do: @default

  @doc "Whether `capabilities` is a list of known groups, each named once."
  @spec valid?(term()) :: boolean()
  def valid?(capabilities) when is_list(capabilities),
    do: capabilities == Enum.uniq(capabilities) and Enum.all?(capabilities, &(&1 in @known))

  def valid?(_capabilities), do: false
end
