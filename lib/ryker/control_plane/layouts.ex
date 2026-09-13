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
  def static(assigns) do
    assigns =
      assigns
      |> assign_new(:description, fn -> nil end)
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
                <Components.page_header title={@title} description={@description} />{Phoenix.HTML.raw(
                  @body
                )}
              </div>
            </main>
          </div>
        </div>
      </body>
    </html>
    """
  end

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
        <script type="module" src="/assets/control-plane.js">
        </script>
      </head>
      <body class="control-room">{@inner_content}</body>
    </html>
    """
  end
end
