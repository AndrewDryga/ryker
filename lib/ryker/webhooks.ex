defmodule Ryker.Webhooks do
  @moduledoc """
  What the console asks of the webhooks context: the recorded sample payload
  of each adapter kind, which the webhook page previews. Forwards to
  `Ryker.Webhooks.Presets`, so the console never reaches below this one
  (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.Webhooks.Presets

  @doc "The recorded sample payload for one adapter kind."
  @spec preset_sample(atom() | String.t()) :: String.t()
  defdelegate preset_sample(kind), to: Presets, as: :sample
end
