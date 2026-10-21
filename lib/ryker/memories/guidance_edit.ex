defmodule Ryker.Memories.GuidanceEdit do
  @moduledoc "Editing guidance cannot silently preserve checks for words a person replaced."

  @notice "Changing the guidance removes its required checks. Give Ryker a new explicit correction to require outputs again. Changing only the subject keeps the checks."

  def notice(%{"requirements" => [_ | _]}), do: @notice
  def notice(_entry), do: nil

  def clear_changed_requirements(payload, original, replacement) when original != replacement,
    do: Map.put(payload, "requirements", [])

  def clear_changed_requirements(payload, _original, _replacement), do: payload
end
