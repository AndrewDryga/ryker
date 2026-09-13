defmodule Ryker.ControlPlane.BrandAssetsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, BrowserGuard, Layouts, Navigation}

  # The Ryker artwork and its supporting fonts are imported unchanged under
  # brand/ and fingerprinted by brand/source-manifest.sha256. The release cannot
  # read brand/ at runtime (ControlPlane.Assets serves an explicit allowlist from
  # priv/static), so the bytes are copied into priv/static/brand and this test
  # holds the copy to the manifest: a retouched, re-exported, or "optimised"
  # logo would fail here before it reached a sidebar.
  @manifest "brand/source-manifest.sha256"

  # Served path under /assets => supplied source path fingerprinted in the manifest.
  @packaged %{
    "brand/lockup-color.svg" => "brand/ryker/lockup-color.svg",
    "brand/lockup.svg" => "brand/ryker/lockup.svg",
    "brand/lockup-reverse.svg" => "brand/ryker/lockup-reverse.svg",
    "brand/mark-mint.svg" => "brand/ryker/mark-mint.svg",
    "brand/mark.svg" => "brand/ryker/mark.svg",
    "brand/mark-reverse.svg" => "brand/ryker/mark-reverse.svg",
    "brand/wordmark.svg" => "brand/ryker/wordmark.svg",
    "brand/avatar.png" => "brand/ryker/avatar.png",
    "brand/avatar.svg" => "brand/ryker/avatar.svg",
    "brand/banner.png" => "brand/ryker/banner.png",
    "brand/fonts/IBMPlexSans-Regular.woff2" => "brand/assets/fonts/IBMPlexSans-Regular.woff2",
    "brand/fonts/IBMPlexSans-SemiBold.woff2" => "brand/assets/fonts/IBMPlexSans-SemiBold.woff2",
    "brand/fonts/IBMPlexMono-Regular.woff2" => "brand/assets/fonts/IBMPlexMono-Regular.woff2",
    "brand/fonts/LICENSE.txt" => "brand/assets/fonts/LICENSE.txt"
  }

  @types %{
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".woff2" => "font/woff2",
    ".txt" => "text/plain"
  }

  test "every packaged brand file is the supplied artwork byte for byte" do
    manifest = manifest()

    for {served, source} <- @packaged do
      expected = Map.fetch!(manifest, source)

      assert sha256(File.read!("priv/static/" <> served)) == expected,
             "priv/static/#{served} no longer matches #{source} in #{@manifest}"

      # The source copy is the provenance record; it must not drift either.
      assert sha256(File.read!(source)) == expected, "#{source} no longer matches #{@manifest}"
    end
  end

  test "every brand asset is served from the release allowlist with its MIME type" do
    manifest = manifest()

    for {served, source} <- @packaged do
      conn = Assets.call(Plug.Test.conn(:get, "/" <> served), [])
      assert conn.status == 200, "#{served} is not allowlisted in ControlPlane.Assets"
      assert conn.halted

      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      expected_type = Map.fetch!(@types, Path.extname(served))

      assert String.starts_with?(content_type, expected_type),
             "#{served} is served as #{content_type}, expected #{expected_type}"

      # Binary formats must not be labelled with a text charset.
      if expected_type in ["image/png", "font/woff2"], do: refute(content_type =~ "charset")

      assert sha256(conn.resp_body) == Map.fetch!(manifest, source),
             "the bytes served for #{served} differ from #{source}"

      # Pinned bytes can sit in a browser cache for a long time.
      assert [cache] = Plug.Conn.get_resp_header(conn, "cache-control")
      assert cache =~ ~r/max-age=\d{6,}/
    end

    for path <- ["/brand/missing.svg", "/brand/fonts/../lockup.svg", "/brand/../workspace.css"] do
      assert Assets.call(Plug.Test.conn(:get, path), []).status == 404
    end

    # The endpoint's BrowserGuard stamps no-store on every response before the
    # router forwards to Assets; the pinned artwork must still leave cacheable.
    guarded =
      Plug.Test.conn(:get, "/brand/fonts/IBMPlexSans-Regular.woff2")
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> BrowserGuard.call([])
      |> Assets.call([])

    assert guarded.status == 200
    assert Plug.Conn.get_resp_header(guarded, "cache-control") == ["public, max-age=604800"]
    assert Plug.Conn.get_resp_header(guarded, "content-type") == ["font/woff2"]
  end

  test "nothing under priv/static/brand is unpackaged or unreferenced" do
    # A file copied in but never allowlisted is dead weight in every release;
    # an allowlisted path nothing renders is a logo variant waiting to drift.
    on_disk =
      Path.wildcard("priv/static/brand/**")
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&String.replace_prefix(&1, "priv/static/", ""))
      |> Enum.sort()

    assert on_disk == Enum.sort(Map.keys(@packaged))

    rendered =
      [
        render_component(&Layouts.static/1, title: "Retry delivery", body: ""),
        render_component(&Navigation.sidebar/1, path: "/", live: true),
        render_component(&Navigation.mobile/1, path: "/", live: true),
        Assets.call(Plug.Test.conn(:get, "/ryker-tokens.css"), []).resp_body
      ]
      |> Enum.join("\n")

    referenced =
      Regex.scan(~r{/assets/(brand/[A-Za-z0-9./_-]+)}, rendered)
      |> Enum.map(fn [_, path] -> path end)
      |> Enum.uniq()

    for path <- referenced do
      assert Map.has_key?(@packaged, path), "#{path} is referenced but not packaged"
    end

    # The interface uses the primary dark-surface lockup, the standalone mint
    # mark, the avatar composition and the three fonts. The remaining supplied
    # variants (light-surface and monochrome lockups, graphite and ivory marks,
    # the outlined wordmark, the PNG avatar and the banner) are packaged so
    # Slack, GitHub and documentation surfaces take them from the running
    # release rather than a developer checkout, and their license travels with
    # the fonts.
    for path <-
          ~w(brand/lockup-color.svg brand/mark-mint.svg brand/avatar.svg) ++
            Enum.filter(Map.keys(@packaged), &String.ends_with?(&1, ".woff2")) do
      assert path in referenced, "#{path} is packaged but nothing renders it"
    end
  end

  test "the favicon is the supplied mint-on-graphite composition, not an invented small variant" do
    # brand/ryker/README.md supplies no optical 16px symbol and the Ryker rule
    # forbids redrawing one or borrowing Protectorate's small mark. The browser
    # tab therefore shows the unmodified avatar composition (the mint mark on
    # its opaque graphite square) as an SVG icon. mark-mint.svg alone has a
    # transparent canvas, which would put mint on whatever the tab strip is;
    # the avatar keeps the mint on graphite regardless of browser theme. There
    # is deliberately no .ico or raster PNG icon: any 16px raster would be a
    # new, unapproved rendering of the logo.
    for html <- [
          render_component(&Layouts.static/1, title: "Retry delivery", body: ""),
          render_component(&Layouts.root/1, page_title: "Activity", inner_content: "")
        ] do
      document = LazyHTML.from_document(html)
      icons = LazyHTML.query(document, "link[rel=icon]")
      assert LazyHTML.attribute(icons, "href") == ["/assets/brand/avatar.svg"]
      assert LazyHTML.attribute(icons, "type") == ["image/svg+xml"]
      refute html =~ ".ico"
      refute html =~ "apple-touch-icon"
    end
  end

  test "the sidebar brand block carries the supplied lockup and the compact navigation the mark" do
    # The wordmark is supplied outlined lettering; typing "Ryker" in a font is
    # not the logo. The desktop rail shows lockup-color.svg on its graphite
    # block and the compact (<= 800px) rail swaps to the standalone mint mark
    # through one <picture>, so the accessible name is announced once.
    for live <- [true, false] do
      html = render_component(&Navigation.sidebar/1, path: "/", live: live)
      document = LazyHTML.from_fragment(html)

      brand = LazyHTML.query(document, "a.app-brand")
      assert LazyHTML.attribute(brand, "href") == ["/"]
      assert LazyHTML.attribute(brand, "aria-label") == ["Ryker"]

      assert brand |> LazyHTML.text() |> String.trim() == "",
             "the brand link must not retype the wordmark"

      image = LazyHTML.query(brand, "picture > img")
      assert LazyHTML.attribute(image, "src") == ["/assets/brand/lockup-color.svg"]
      assert LazyHTML.attribute(image, "alt") == ["Ryker"]

      compact = LazyHTML.query(brand, "picture > source")
      assert LazyHTML.attribute(compact, "srcset") == ["/assets/brand/mark-mint.svg"]
      assert LazyHTML.attribute(compact, "media") == ["(max-width:800px)"]
      assert LazyHTML.attribute(compact, "type") == ["image/svg+xml"]

      refute html =~ ~r/>\s*Ryker\s*</
    end
  end

  defp manifest do
    @manifest
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [sha, path] = String.split(line, ~r/\s+/, parts: 2)
      {path, sha}
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
