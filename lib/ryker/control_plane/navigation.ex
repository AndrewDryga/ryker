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
  # The places people manage Ryker, each named for what it holds. A place with
  # several pages folds open in the sidebar; a single page is a plain link.
  @secondary [
    {:grid, "Work",
     [
       {"Environments", "/environments"},
       {"Channels", "/channels"},
       {"Repositories", "/repositories"},
       {"Working copies", "/working-copies"}
     ]},
    {:bolt, "Automations",
     [
       {"Rules", "/rules"},
       {"Schedules", "/schedules"},
       {"Follow-ups", "/follow-ups"}
     ]},
    {:pen, "Instructions", "/instructions"},
    {:book, "Memory",
     [
       {"Facts", "/memory"},
       {"Learned", "/memory/learned"},
       {"Findings", "/memory/findings"},
       {"Learning", "/memory/learning"}
     ]}
  ]
  # At the bottom, apart from the everyday places: the services Ryker is
  # connected to, then how Ryker itself runs.
  @system [
    {:plug, "Integrations",
     [
       {"Overview", "/integrations"},
       {"Slack", "/integrations/slack"},
       {"GitHub", "/integrations/github"},
       {"Emisar", "/integrations/emisar"},
       {"Webhooks", "/integrations/webhooks"}
     ]},
    {:settings, "Settings",
     [
       {"Models", "/settings/models"},
       {"Data retention", "/settings/retention"},
       {"Model prices", "/settings/prices"},
       {"Advanced", "/settings/advanced"}
     ]}
  ]
  # An overview page is selected on its own address only, never under its
  # siblings' addresses.
  @overviews ["/integrations", "/memory"]

  attr(:path, :string, required: true)
  attr(:live, :boolean, default: true)

  attr(:setup, :map,
    default: nil,
    doc: "While required setup steps are open, %{done: count or nil, total: count}"
  )

  def sidebar(assigns) do
    assigns =
      assign(assigns,
        primary: @primary,
        groups: [{"Manage Ryker", @secondary}, {"Integrations and settings", @system}]
      )

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
        :if={@setup}
        navigate={if @live, do: "/setup"}
        href={if !@live, do: "/setup"}
        class="setup-shortcut"
        aria-current={if @path == "/setup", do: "page"}
      ><span><strong>Finish setup</strong> <small>{progress(@setup)}</small></span><.icon name={
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
      <nav :for={{group, places} <- @groups} class="app-nav secondary-nav" aria-label={group}>
        <%= for {icon, label, target} <- places do %>
          <.link
            :if={is_binary(target)}
            navigate={if @live, do: target}
            href={if !@live, do: target}
            aria-current={if selected?(@path, target), do: "page"}
          ><.icon name={icon} /><span>{label}</span></.link>
          <details
            :if={is_list(target)}
            id={"nav-#{icon}"}
            name="workspace-navigation"
            open={Enum.any?(target, fn {_name, href} -> selected?(@path, href) end)}
          >
            <summary><.icon name={icon} /><span>{label}</span><.icon name={:chevron} /></summary><.link
              :for={{name, href} <- target}
              navigate={if @live, do: href}
              href={if !@live, do: href}
              aria-current={if selected?(@path, href), do: "page"}
            >{name}</.link>
          </details>
        <% end %>
      </nav>
    </aside>
    """
  end

  attr(:path, :string, required: true)
  attr(:live, :boolean, default: true)
  attr(:setup, :map, default: nil)

  def mobile(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        Enum.map(@secondary ++ @system, fn
          {_icon, label, href} when is_binary(href) -> {label, [{label, href}]}
          {_icon, label, links} -> {label, links}
        end)
      )
      |> assign(
        :primary_overflow,
        Enum.map(Enum.drop(@primary, 2), fn {_icon, label, href} -> {label, href} end)
      )

    ~H"""
    <.link
      :if={@setup}
      navigate={if @live, do: "/setup"}
      href={if !@live, do: "/setup"}
      class="mobile-setup-shortcut"
      aria-current={if @path == "/setup", do: "page"}
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

  # "2 of 6 steps done" when the count is known; a database that could not be
  # read still offers the way back into setup, without inventing a count.
  defp progress(%{done: done, total: total}) when is_integer(done),
    do: "#{done} of #{total} steps done"

  defp progress(_setup), do: "Continue the setup"

  defp selected?(path, "/"),
    do:
      path in ["/", "/activity"] or String.starts_with?(path, "/activity?") or
        String.starts_with?(path, "/timeline")

  defp selected?(path, href) do
    path == href or (href not in @overviews and String.starts_with?(path, href <> "/"))
  end
end
