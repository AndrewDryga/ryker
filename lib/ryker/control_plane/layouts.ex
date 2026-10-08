defmodule Ryker.ControlPlane.Layouts do
  @moduledoc false
  use Phoenix.Component
  alias Ryker.ControlPlane.{Components, Navigation}

  # The stylesheets both shells load, in cascade order: the tokens declare
  # the roles, control-plane.css the base rules and application chrome, and
  # workspace.css the operator workspace on top of them.
  @stylesheets ~w(/assets/ryker-tokens.css /assets/control-plane.css /assets/workspace.css)

  def stylesheets, do: @stylesheets

  # The shell for a confirmed action, a record view or an HTTP error: the same
  # sidebar and stylesheets as the live shell, without a socket.
  # `@body` is markup the console's builders made for `HTML.page/5`, escaping every value.
  # sobelow_skip ["XSS.Raw"]
  def static(assigns) do
    assigns =
      assigns
      |> assign_new(:description, fn -> nil end)
      |> assign_new(:back, fn -> nil end)
      |> assign_new(:status, fn -> nil end)
      |> assign_new(:title_href, fn -> nil end)
      |> assign(:stylesheets, @stylesheets)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>{@title} · Ryker</title><link
          :for={href <- @stylesheets}
          rel="stylesheet"
          href={href}
        /><link rel="icon" type="image/svg+xml" href="/assets/brand/avatar.svg" />
      </head><body class="control-room">
        <div class="ryker-app">
          <Navigation.sidebar path="" live={false} />
          <div class="app-workspace">
            <div class="mobile-navigation">
              <Navigation.mobile path="" live={false} />
            </div>
            <main class="page-surface action-page">
              <div class="secondary-page">
                <Components.page_header
                  title={@title}
                  description={@description}
                  back={@back}
                  status={@status}
                  title_href={@title_href}
                />{Phoenix.HTML.raw(@body)}
              </div>
            </main>
          </div>
        </div>
      </body>
    </html>
    """
  end

  # The live shell. page-help-early.js is a classic script so it runs here,
  # before the body is parsed: it shows or hides the page's help as this
  # browser chose before anything paints. The module runs after parsing.
  def root(assigns) do
    assigns = assign(assigns, :stylesheets, @stylesheets)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{@page_title || "Ryker"} · Ryker</title>
        <link :for={href <- @stylesheets} rel="stylesheet" href={href} />
        <link rel="icon" type="image/svg+xml" href="/assets/brand/avatar.svg" />
        <script src="/assets/page-help-early.js">
        </script>
        <script type="module" src="/assets/control-plane.js">
        </script>
      </head>
      <body class="control-room">{@inner_content}</body>
    </html>
    """
  end
end
