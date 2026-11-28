defmodule Ryker.ControlPlane.SkillInstallPage do
  @moduledoc "Preview and install skills from GitHub or pasted Markdown."
  use Phoenix.Component
  alias Ryker.ControlPlane.SkillImport

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="skill-install-options">
        <.live_component
          :for={method <- ~w(github paste)}
          module={SkillImport}
          id={"install-skill-" <> method}
          method={method}
          view={@view}
          commands={@commands}
        />
      </div>
    </div>
    """
  end
end
