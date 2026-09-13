defmodule Responder.ControlPlane.Layouts do
  @moduledoc false
  use Phoenix.Component
  alias Responder.ControlPlane.{Components, Navigation}

  def static(assigns) do
    assigns = assign_new(assigns, :description, fn -> nil end)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>{@title} · Responder</title><link rel="stylesheet" href="/static/app.css" /><link
          rel="stylesheet"
          href="/assets/workspace.css"
        />
      </head><body class="control-room">
        <div class="responder-app">
          <Navigation.sidebar path="" live={false} />
          <div class="app-workspace">
            <div class="mobile-navigation">
              <Navigation.mobile path="" live={false} />
            </div>
            <main class="legacy-surface action-page">
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
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{@page_title || "Responder"} · Responder</title>
        <link rel="stylesheet" href="/static/app.css" />
        <link rel="stylesheet" href="/assets/control-plane.css" />
        <link rel="stylesheet" href="/assets/workspace.css" />
        <script type="module" src="/assets/control-plane.js">
        </script>
      </head>
      <body class="control-room">{@inner_content}</body>
    </html>
    """
  end
end
