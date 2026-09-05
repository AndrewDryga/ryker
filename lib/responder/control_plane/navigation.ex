defmodule Responder.ControlPlane.Navigation do
  @moduledoc "Shared navigation for live inspection and confirmed HTTP actions."
  use Phoenix.Component
  import Responder.ControlPlane.Components

  @primary [
    {:activity, "Activity", "/"},
    {:incident, "Incidents", "/incidents"},
    {:chat, "Conversation Lab", "/lab"},
    {:cards, "Slack Card Lab", "/card-lab"},
    {:usage, "Usage & cost", "/usage"}
  ]
  @secondary [
    {:clock, "Automation", [{"Schedules", "/schedules"}, {"Subscriptions", "/subscriptions"}]},
    {:book, "Intelligence",
     [
       {"Memory", "/memory"},
       {"Decisions", "/decisions"},
       {"Findings", "/findings"},
       {"Model calibration", "/calibration"}
     ]},
    {:settings, "Workspace",
     [
       {"Configuration", "/configuration"},
       {"Channels", "/channels"},
       {"Repositories", "/repositories"},
       {"Workspaces", "/workspaces"}
     ]},
    {:grid, "Diagnostics",
     [{"Failures", "/failures"}, {"Audit trail", "/audit"}, {"Test journeys", "/manual-tests"}]}
  ]

  def sidebar(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <aside class="app-sidebar">
      <.link
        navigate={if @live, do: "/"}
        href={if !@live, do: "/"}
        class="app-brand"
        aria-label="Responder control plane"
      ><span
        class="brand-mark"
        aria-hidden="true"
      >r<span>.</span></span><span>responder<span class="brand-edition">OPERATOR WORKSPACE</span></span></.link>
      <div class="workspace-identity">
        <span class="workspace-avatar">R</span><div>
          <strong>Local workspace</strong><span>Connected to your runtime</span>
        </div>
      </div>
      <nav class="app-nav" aria-label="Main navigation">
        <p class="nav-caption">WORKBENCH</p>
        <.link
          :for={{icon, label, href} <- @primary}
          navigate={if @live, do: href}
          href={if !@live, do: href}
          aria-current={if selected?(@path, href), do: "page"}
        ><.icon name={icon} /><span>{label}</span><span
          :if={selected?(@path, href)}
          class="nav-selected"
          aria-hidden="true"
        ></span></.link>
      </nav>
      <nav class="app-nav secondary-nav" aria-label="Workspace tools">
        <p class="nav-caption">MANAGE</p>
        <details
          :for={{icon, label, links} <- @secondary}
          id={"nav-#{icon}"}
          open={Enum.any?(links, fn {_name, href} -> selected?(@path, href) end)}
        >
          <summary><.icon name={icon} /><span>{label}</span><.icon name={:chevron} /></summary><.link
            :for={{name, href} <- links}
            navigate={if @live, do: href}
            href={if !@live, do: href}
            aria-current={if selected?(@path, href), do: "page"}
          >{name}</.link>
        </details>
      </nav>
      <div class="sidebar-bottom">
        <a href="/manual-tests"><.icon name={:book} />Testing guide <.icon name={:arrow} /></a><div class="operator-identity">
          <span>LO</span><div>
            <strong>Local operator</strong><small>Loopback access only</small>
          </div><i aria-hidden="true"></i>
        </div>
      </div>
    </aside>
    """
  end

  def mobile(assigns) do
    assigns = assign(assigns, :secondary, @secondary)

    ~H"""
    <details class="mobile-manage" id="mobile-manage">
      <summary>Manage <.icon name={:chevron} /></summary>
      <nav aria-label="Mobile workspace tools">
        <section :for={{_icon, label, links} <- @secondary}>
          <strong>{label}</strong><.link
            :for={{name, href} <- links}
            navigate={if @live, do: href}
            href={if !@live, do: href}
            aria-current={if selected?(@path, href), do: "page"}
          >{name}</.link>
        </section>
      </nav>
    </details>
    """
  end

  defp selected?(path, "/"),
    do:
      path == "/" or String.starts_with?(path, "/episodes") or
        String.starts_with?(path, "/admission")

  defp selected?(path, href), do: path == href or String.starts_with?(path, href <> "/")
end
