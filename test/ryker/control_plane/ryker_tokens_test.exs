defmodule Ryker.ControlPlane.RykerTokensTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, BrowserGuard, Layouts}

  # brand/ryker/README.md fixes the identity: graphite #111315, mint #36E6A5,
  # ivory #F2EEE5, with mint on graphite and never as body text on a light
  # surface. priv/static/ryker-tokens.css turns that into application roles and
  # the two stylesheets point their root variables at those roles. These tests
  # parse the shipped CSS and compute the WCAG ratios, so a token edit that
  # quietly drops secondary text under 4.5:1 or a focus ring under 3:1 fails
  # here instead of in an operator's browser.
  @identity %{graphite: "#111315", mint: "#36e6a5", ivory: "#f2eee5"}

  @text_pairs [
    {"ryker-text", "ryker-surface"},
    {"ryker-text", "ryker-surface-raised"},
    {"ryker-text", "ryker-surface-sunken"},
    {"ryker-text-secondary", "ryker-surface"},
    {"ryker-text-secondary", "ryker-surface-raised"},
    {"ryker-text-secondary", "ryker-surface-sunken"},
    {"ryker-text-inverse", "ryker-surface-inverse"},
    {"ryker-text-inverse-secondary", "ryker-surface-inverse"},
    {"ryker-accent-strong", "ryker-surface"},
    {"ryker-accent-strong", "ryker-surface-raised"},
    {"ryker-accent-strong", "ryker-surface-sunken"},
    {"ryker-accent-strong", "ryker-accent-soft"},
    {"ryker-control-text", "ryker-control-bg"},
    {"ryker-control-primary-text", "ryker-control-primary-bg"},
    {"ryker-control-primary-text", "ryker-control-primary-hover-bg"},
    {"ryker-selected-text", "ryker-selected-bg"},
    {"ryker-text", "ryker-hover-bg"},
    {"ryker-success", "ryker-success-soft"},
    {"ryker-success", "ryker-surface"},
    {"ryker-success", "ryker-surface-raised"},
    {"ryker-warning", "ryker-warning-soft"},
    {"ryker-warning", "ryker-surface"},
    {"ryker-warning", "ryker-surface-raised"},
    {"ryker-error", "ryker-error-soft"},
    {"ryker-error", "ryker-surface"},
    {"ryker-error", "ryker-surface-raised"}
  ]

  @ui_pairs [
    {"ryker-focus-ring", "ryker-surface"},
    {"ryker-focus-ring", "ryker-surface-raised"},
    {"ryker-focus-ring", "ryker-surface-sunken"},
    {"ryker-focus-inner", "ryker-focus-ring"},
    {"ryker-control-border", "ryker-surface"},
    {"ryker-control-border", "ryker-surface-raised"},
    {"ryker-control-border", "ryker-surface-sunken"},
    {"ryker-selected-accent", "ryker-selected-bg"},
    {"ryker-selected-bg", "ryker-surface-sunken"},
    {"ryker-surface-inverse", "ryker-surface-sunken"},
    {"ryker-control-primary-bg", "ryker-surface"},
    {"ryker-control-primary-bg", "ryker-surface-raised"}
  ]

  test "the tokens carry the supplied identity and every text pair clears 4.5:1" do
    tokens = tokens()
    assert tokens["ryker-graphite"] == @identity.graphite
    assert tokens["ryker-mint"] == @identity.mint
    assert tokens["ryker-ivory"] == @identity.ivory

    # The application surface stays light and ivory-based; graphite is the
    # inverse block that mint sits on.
    assert tokens["ryker-surface"] == @identity.ivory
    assert tokens["ryker-surface-inverse"] == @identity.graphite
    assert tokens["ryker-accent"] == @identity.mint

    for {foreground, background} <- @text_pairs do
      ratio = contrast(tokens, foreground, background)

      assert ratio >= 4.5,
             "--#{foreground} on --#{background} is #{ratio}:1, below 4.5:1 for text"
    end
  end

  test "focus rings, control boundaries and selected markers clear 3:1" do
    tokens = tokens()

    for {foreground, background} <- @ui_pairs do
      ratio = contrast(tokens, foreground, background)

      assert ratio >= 3.0,
             "--#{foreground} against --#{background} is #{ratio}:1, below 3:1 for a UI boundary"
    end
  end

  test "mint is only ever paired with graphite" do
    # Mint on ivory is 1.39:1 and on white 1.61:1: it cannot carry text or a
    # boundary on the light surface. Every token that resolves to mint must be
    # one whose documented background is graphite.
    tokens = tokens()
    mint = @identity.mint

    mint_roles =
      tokens
      |> Enum.filter(fn {_name, value} -> value == mint end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()

    assert mint_roles ==
             Enum.sort(
               ~w(ryker-mint ryker-accent ryker-control-primary-text ryker-selected-accent ryker-focus-inner)
             )

    for light <- ~w(ryker-surface ryker-surface-raised ryker-surface-sunken) do
      assert contrast(tokens, "ryker-mint", light) < 3.0
    end

    for text <-
          ~w(ryker-text ryker-text-secondary ryker-accent-strong ryker-success ryker-warning ryker-error) do
      refute tokens[text] == mint, "--#{text} would put mint body text on a light surface"
    end
  end

  test "IBM Plex is packaged through @font-face with swap and no network fonts" do
    css = tokens_css()

    faces =
      Regex.scan(~r/@font-face\s*\{([^}]*)\}/, css)
      |> Enum.map(fn [_, body] -> body end)

    expected = [
      {"IBM Plex Sans", "400", "/assets/brand/fonts/IBMPlexSans-Regular.woff2"},
      {"IBM Plex Sans", "600", "/assets/brand/fonts/IBMPlexSans-SemiBold.woff2"},
      {"IBM Plex Mono", "400", "/assets/brand/fonts/IBMPlexMono-Regular.woff2"}
    ]

    assert length(faces) == length(expected)

    for {family, weight, url} <- expected do
      face =
        Enum.find(faces, fn body ->
          body =~ ~s(font-family:"#{family}") and body =~ "font-weight:#{weight}"
        end)

      assert face, "no @font-face for #{family} #{weight}"
      assert face =~ ~s[url("#{url}") format("woff2")]
      assert face =~ "font-display:swap"
    end

    refute css =~ ~r/url\(\s*["']?https?:/
    refute css =~ "fonts.googleapis"
    assert css =~ ~s(--ryker-font-sans:"IBM Plex Sans",)
    assert css =~ ~s(--ryker-font-mono:"IBM Plex Mono",)
    assert css =~ "sans-serif;"
    assert css =~ "monospace;"

    # The font license ships beside the fonts and the stylesheet says where.
    assert css =~ "/assets/brand/fonts/LICENSE.txt"
  end

  test "the application font stacks resolve to the packaged families" do
    workspace = workspace_css()
    control_plane = control_plane_css()

    [_, root] = Regex.run(~r/\n\.ryker-app \{([^}]+)\}/, workspace)
    assert root =~ "font: 16px/1.5 var(--ryker-font-sans)"
    assert root =~ "letter-spacing:-.012em"

    assert workspace =~
             ~r/\.ryker-app pre, \.ryker-app code[^{]*\{[^}]*font-family:var\(--ryker-font-mono\)/

    for css <- [workspace, control_plane] do
      refute css =~ "Avenir", "a sans stack still bypasses --ryker-font-sans"
      refute css =~ "ui-monospace", "a mono stack still bypasses --ryker-font-mono"
    end
  end

  test "the stylesheets' root variables point at the Ryker roles" do
    tokens = tokens()
    workspace = workspace_css()
    control_plane = control_plane_css()

    roots = [
      {"workspace.css .ryker-app", Regex.run(~r/\n\.ryker-app \{([^}]+)\}/, workspace),
       ~w(ink secondary paper stroke green text muted line panel panel-raised accent cyan danger warning)},
      {"workspace.css .page-surface",
       Regex.run(~r/\.ryker-app \.page-surface \{([^}]+)\}/, workspace),
       ~w(text muted line accent panel panel-raised cyan bg)},
      {"control-plane.css .control-room",
       Regex.run(~r/\.control-room \{([^}]+)\}/, control_plane),
       ~w(bg panel panel-raised line text muted accent cyan)}
    ]

    for {name, [_, body], variables} <- roots do
      definitions =
        Regex.scan(~r/--([a-z-]+):\s*([^;]+);/, body)
        |> Map.new(fn [_, variable, value] -> {variable, String.trim(value)} end)

      for variable <- variables do
        value = Map.get(definitions, variable)
        assert value, "#{name} no longer defines --#{variable}"

        assert [_, role] = Regex.run(~r/^var\(--(ryker-[a-z-]+)\)$/, value),
               "#{name} --#{variable} is #{value}, not a Ryker role"

        assert Map.has_key?(tokens, role), "#{name} --#{variable} points at unknown --#{role}"
      end

      refute body =~ ~r/--[a-z-]+:\s*#[0-9a-fA-F]{3,6}/, "#{name} still hard-codes a color"
    end

    # Body text and the surface keep their meaning on the light surface.
    [_, room] = Regex.run(~r/\n\.control-room \{([^}]+)\}/, workspace)
    assert room =~ "background:var(--ryker-surface)"
    assert room =~ "color:var(--ryker-text)"
    assert room =~ "color-scheme:light"
  end

  test "mint-on-graphite drives the brand block, primary buttons, focus rings and selection" do
    workspace = workspace_css()

    [_, focus] = Regex.run(~r/\.ryker-app :focus-visible \{([^}]+)\}/, workspace)
    assert focus =~ "outline:2px solid var(--ryker-focus-ring)"
    assert focus =~ "box-shadow:0 0 0 2px var(--ryker-focus-inner)"

    [_, primary] = Regex.run(~r/\.ryker-app \.ui-button\.primary \{([^}]+)\}/, workspace)
    assert primary =~ "background:var(--ryker-control-primary-bg)"
    assert primary =~ "color:var(--ryker-control-primary-text)"

    [_, hover] = Regex.run(~r/\.ryker-app \.ui-button\.primary:hover \{([^}]+)\}/, workspace)
    assert hover =~ "background:var(--ryker-control-primary-hover-bg)"

    [_, selected] = Regex.run(~r/\.app-nav a\[aria-current=page\] \{([^}]+)\}/, workspace)
    assert selected =~ "background:var(--ryker-selected-bg)"
    assert selected =~ "color:var(--ryker-selected-text)"
    assert selected =~ "border-left-color:var(--ryker-selected-accent)"
    # Selection is also carried by weight and aria-current, never by color alone.
    assert selected =~ "font-weight:600"
  end

  test "the brand link is a 44px target showing the artwork at or above its minimum" do
    # brand/ryker/README.md: complete lockup at 160px or more, standalone mark
    # at 24px or more, clear space of a quarter of the lowercase height around
    # a lockup and an eighth of the symbol width around a mark. In
    # lockup-color.svg (viewBox 950x330) the visible artwork spans 878 units,
    # so the canvas must render at >= 173.2px; in mark-mint.svg (viewBox
    # -28 -44 780 680) the symbol spans 729 units, so the canvas must render
    # at >= 25.7px.
    workspace = workspace_css()

    [_, brand] = Regex.run(~r/\n\.app-brand \{([^}]+)\}/, workspace)
    assert brand =~ "min-height:44px"
    assert brand =~ "background:var(--ryker-surface-inverse)"
    assert brand =~ "padding:16px"

    [_, image] = Regex.run(~r/\n\.app-brand img \{([^}]+)\}/, workspace)
    [_, lockup_width] = Regex.run(~r/width:(\d+)px/, image)
    assert String.to_integer(lockup_width) * 878 / 950 >= 160
    assert image =~ "height:auto"

    [_, compact] =
      Regex.run(~r/@media \(max-width:800px\) \{[^\n]*\.app-brand img \{([^}]+)\}/, workspace)

    [_, mark_width] = Regex.run(~r/width:(\d+)px/, compact)
    assert String.to_integer(mark_width) * 729 / 780 >= 24

    # A graphite ring is invisible on the graphite block: the brand link gets
    # the mint ring inset instead, still on graphite.
    [_, brand_focus] = Regex.run(~r/\.app-brand:focus-visible \{([^}]+)\}/, workspace)
    assert brand_focus =~ "outline:2px solid var(--ryker-focus-inner)"
    assert brand_focus =~ "outline-offset:-4px"
    assert brand_focus =~ "box-shadow:none"
  end

  test "motion stays opt-in under prefers-reduced-motion" do
    # No ambient animation and nothing that moves unless the operator's system
    # allows it: every transition or animation must sit inside a
    # no-preference media block.
    for {name, css} <- [
          {"ryker-tokens.css", tokens_css()},
          {"workspace.css", workspace_css()},
          {"control-plane.css", control_plane_css()}
        ] do
      refute css =~ "@keyframes", "#{name} declares an animation"

      for line <- String.split(css, "\n"),
          [prefix | _] = Regex.split(~r/\b(transition|animation)\b/, line, parts: 2),
          prefix != line do
        assert prefix =~ "prefers-reduced-motion:no-preference",
               "#{name} moves outside a reduced-motion guard: #{String.slice(line, 0, 80)}"
      end
    end
  end

  test "the content security policy admits the packaged fonts and nothing remote" do
    # default-src 'none' covers font-src unless it is named: without this
    # directive every @font-face above is silently blocked and the interface
    # falls back to the system stack while the tests stay green.
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> BrowserGuard.call([])

    [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    directives = policy |> String.split(";") |> Enum.map(&String.trim/1)
    assert "font-src 'self'" in directives
    assert "default-src 'none'" in directives
    refute policy =~ "https:"
  end

  test "both shells load the same stylesheets, tokens first, from the asset allowlist" do
    # Until 2026-09-13 the confirmation shell skipped control-plane.css and both
    # shells linked a /static/app.css string the HTTP router assembled ahead of
    # the tokens; a rule that existed in one shell could be missing from the other.
    for html <- [
          render_component(&Layouts.static/1, title: "Retry delivery", body: ""),
          render_component(&Layouts.root/1, page_title: "Activity", inner_content: "")
        ] do
      hrefs =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("link[rel=stylesheet]")
        |> LazyHTML.attribute("href")

      assert hrefs == [
               "/assets/ryker-tokens.css",
               "/assets/control-plane.css",
               "/assets/workspace.css"
             ]

      assert hrefs == Layouts.stylesheets()
    end

    for "/assets/" <> file <- Layouts.stylesheets() do
      served = Assets.call(Plug.Test.conn(:get, "/" <> file), [])
      assert served.status == 200, file
      assert Plug.Conn.get_resp_header(served, "content-type") |> hd() =~ "text/css"
    end

    # The base rules /static/app.css used to carry open control-plane.css.
    assert control_plane_css() =~ ~r/\A(\/\*[^*]*\*\/\s*)?:root\{color-scheme:dark;/
    assert control_plane_css() =~ "font-family"
  end

  defp tokens do
    tokens_css()
    |> then(&Regex.scan(~r/--(ryker-[a-z0-9-]+):\s*(#[0-9a-fA-F]{6})\s*;/, &1))
    |> Map.new(fn [_, name, value] -> {name, String.downcase(value)} end)
  end

  defp tokens_css, do: Assets.call(Plug.Test.conn(:get, "/ryker-tokens.css"), []).resp_body
  defp workspace_css, do: Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

  defp control_plane_css,
    do: Assets.call(Plug.Test.conn(:get, "/control-plane.css"), []).resp_body

  defp contrast(tokens, foreground, background) do
    [low, high] =
      Enum.sort([
        luminance(Map.fetch!(tokens, foreground)),
        luminance(Map.fetch!(tokens, background))
      ])

    Float.round((high + 0.05) / (low + 0.05), 2)
  end

  defp luminance("#" <> hex) do
    hex
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn digits ->
      value = String.to_integer(Enum.join(digits), 16) / 255
      if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
    end)
    |> Enum.zip([0.2126, 0.7152, 0.0722])
    |> Enum.map(fn {channel, weight} -> channel * weight end)
    |> Enum.sum()
  end
end
