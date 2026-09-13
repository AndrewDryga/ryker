defmodule Ryker.ControlPlane.Navigation do
  @moduledoc "Shared navigation for live inspection and confirmed HTTP actions."
  use Phoenix.Component
  import Ryker.ControlPlane.Components

  @primary [
    {:activity, "Activity", "/"},
    {:chat, "Conversations", "/conversations"},
    {:incident, "Incident rooms", "/incident-rooms"},
    {:incident, "Failures", "/failures"},
    {:usage, "Usage & cost", "/usage"}
  ]
  @secondary [
    {:clock, "Automation",
     [
       {"Standing rules", "/rules"},
       {"Schedules", "/schedules"},
       {"Waits", "/subscriptions"}
     ]},
    {:book, "Memory & learning",
     [
       {"Memory", "/memory"},
       {"Preferences", "/preferences"},
       {"Guidance", "/guidance"},
       {"Instructions", "/instructions"},
       {"Findings", "/findings"}
     ]},
    {:settings, "Connections & setup",
     [
       {"Settings", "/configuration"},
       {"Channels", "/channels"},
       {"Repositories", "/repositories"},
       {"Workspaces", "/workspaces"}
     ]}
  ]

  def sidebar(assigns) do
    assigns = assign(assigns, groups: [{"Execution", @primary}], secondary: @secondary)

    ~H"""
    <aside class="app-sidebar">
      <.link
        navigate={if @live, do: "/"}
        href={if !@live, do: "/"}
        class="app-brand"
        aria-label="Ryker control plane"
      >Ryker</.link>
      <nav :for={{group, links} <- @groups} class="app-nav" aria-label="Main navigation">
        <p class="nav-caption">{group}</p>
        <.link
          :for={{icon, label, href} <- links}
          navigate={if @live, do: href}
          href={if !@live, do: href}
          aria-current={if selected?(@path, href), do: "page"}
        ><.icon name={icon} /><span>{label}</span></.link>
      </nav>
      <nav class="app-nav secondary-nav" aria-label="Workspace tools">
        <p class="nav-caption">Configuration</p>
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
    </aside>
    """
  end

  def mobile(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        Enum.map(@secondary, fn {_icon, label, links} -> {label, links} end)
      )

    ~H"""
    <details class="mobile-manage" id="mobile-manage">
      <summary>More <.icon name={:chevron} /></summary>
      <nav aria-label="Mobile workspace tools">
        <section :for={{label, links} <- @groups}>
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
      path in ["/", "/activity"] or String.starts_with?(path, "/activity?") or
        String.starts_with?(path, "/timeline")

  defp selected?(path, href), do: path == href or String.starts_with?(path, href <> "/")
end
