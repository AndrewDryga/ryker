defmodule Ryker.ControlPlane.Navigation do
  @moduledoc "Shared navigation for live inspection and confirmed HTTP actions."
  use Phoenix.Component
  import Ryker.ControlPlane.Components

  @primary [
    {:chat, "Chat", "/conversations"},
    {:activity, "Activity", "/"},
    {:incident, "Incident rooms", "/incident-rooms"},
    {:incident, "Failures", "/failures"},
    {:usage, "Usage & cost", "/usage"}
  ]
  @secondary [
    {:grid, "Work environment",
     [
       {"Channels", "/channels"},
       {"Repositories", "/repositories"},
       {"Workspaces", "/workspaces"}
     ]},
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
    {:settings, "Settings",
     [
       {"Overview", "/settings"},
       {"Slack", "/settings/slack"},
       {"GitHub", "/settings/github"},
       {"Emisar", "/settings/emisar"},
       {"Webhooks", "/settings/webhooks"},
       {"Retention", "/settings/retention"},
       {"Token rates", "/settings/token-rates"},
       {"System", "/settings/system"}
     ]}
  ]

  attr(:path, :string, required: true)
  attr(:live, :boolean, default: true)
  attr(:setup_incomplete, :boolean, default: false)

  def sidebar(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <aside class="app-sidebar">
      <.link
        navigate={if @live, do: "/"}
        href={if !@live, do: "/"}
        class="app-brand"
        aria-label="Ryker"
      ><picture><source
        media="(max-width:800px)"
        type="image/svg+xml"
        srcset="/assets/brand/mark-mint.svg"
      /><img src="/assets/brand/lockup-color.svg" alt="Ryker" /></picture></.link>
      <.link
        :if={@setup_incomplete}
        navigate={if @live, do: "/settings"}
        href={if !@live, do: "/settings"}
        class="setup-shortcut"
      ><span><strong>Finish setup</strong><small>Continue the setup</small></span><.icon name={
        :chevron
      } /></.link>
      <nav class="app-nav primary-nav" aria-label="Main navigation">
        <.link
          :for={{icon, label, href} <- @primary}
          navigate={if @live, do: href}
          href={if !@live, do: href}
          aria-current={if selected?(@path, href), do: "page"}
        ><.icon name={icon} /><span>{label}</span></.link>
      </nav>
      <nav class="app-nav secondary-nav" aria-label="Workspace tools">
        <details
          :for={{icon, label, links} <- @secondary}
          id={"nav-#{icon}"}
          name="workspace-navigation"
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

  attr(:path, :string, required: true)
  attr(:live, :boolean, default: true)
  attr(:setup_incomplete, :boolean, default: false)

  def mobile(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        Enum.map(@secondary, fn {_icon, label, links} -> {label, links} end)
      )
      |> assign(
        :primary_overflow,
        Enum.map(Enum.drop(@primary, 2), fn {_icon, label, href} -> {label, href} end)
      )

    ~H"""
    <.link
      :if={@setup_incomplete}
      navigate={if @live, do: "/settings"}
      href={if !@live, do: "/settings"}
      class="mobile-setup-shortcut"
    >Finish setup</.link>
    <details class="mobile-manage" id="mobile-manage">
      <summary>More <.icon name={:chevron} /></summary>
      <nav aria-label="Mobile workspace tools">
        <section class="mobile-primary-overflow">
          <.link
            :for={{name, href} <- @primary_overflow}
            navigate={if @live, do: href}
            href={if !@live, do: href}
            aria-current={if selected?(@path, href), do: "page"}
          >{name}</.link>
        </section>
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

  defp selected?(path, href) do
    path == href or
      (href != "/settings" and String.starts_with?(path, href <> "/"))
  end
end
