defmodule Ryker.PublicSiteBrandTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]

  # The public site in site/ is hand-written HTML and CSS that must render from
  # file:// or any static host. Until 2026-09-26 it still wore the pre-rename
  # look: Inter and Space Grotesk on a zinc palette, a status dot and the typed
  # name as its footer signature, a mint square with a typed "R" as Ryker's
  # Slack avatar, and a header lockup whose visible artwork measured 148px,
  # under the brand's 160px minimum. Andrew asked for the site to follow the
  # Ryker design (brand/ryker/README.md, .agent/kb/rules/ryker-brand.md); these
  # tests hold every page and stylesheet to it, so the next page added in a
  # hurry cannot quietly bring its own colours, fonts or logo back.

  @repo_root Path.expand("../..", __DIR__)
  @site Path.join(@repo_root, "site")
  @manifest "brand/source-manifest.sha256"

  # The Ryker palette is the product's token set: the three supplied identity
  # colours and the surface, text, accent and status roles derived from them.
  @tokens "priv/static/ryker-tokens.css"
  @identity %{graphite: "#111315", mint: "#36e6a5", ivory: "#f2eee5"}
  @mint_text ~w(#36e6a5 #6df0bd)

  @named_colours ~w(white black red green blue orange yellow purple pink gray grey silver
                    maroon navy teal olive lime aqua fuchsia brown gold)

  @plex %{
    "fonts/IBMPlexSans-Regular.woff2" => {"IBM Plex Sans", "400"},
    "fonts/IBMPlexSans-SemiBold.woff2" => {"IBM Plex Sans", "600"},
    "fonts/IBMPlexMono-Regular.woff2" => {"IBM Plex Mono", "400"}
  }
  @families [~s("IBM Plex Sans"), ~s("IBM Plex Mono"), "sans-serif", "monospace"]

  # lockup-color.svg is a 950-unit canvas whose visible artwork spans 878
  # units, so the complete lockup reaches its 160px minimum at a 173.2px canvas.
  @lockup_min_canvas 174

  test "every colour in the site's stylesheets is a Ryker palette colour" do
    palette = palette()
    for {_role, hex} <- @identity, do: assert(hex in palette)

    for {path, css} <- stylesheets(), {property, value} <- declarations(css) do
      for [literal] <- Regex.scan(~r/#[0-9a-fA-F]{3,8}\b/, value) do
        assert normalize(literal) in palette,
               "#{path}: `#{property}: #{value}` uses #{literal}, which is not a Ryker colour"
      end

      refute value =~ ~r/\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/i,
             "#{path}: `#{property}: #{value}` builds a colour outside the palette"

      for name <- @named_colours do
        refute value =~ ~r/(?<![\w-])#{name}(?![\w-])/i,
               "#{path}: `#{property}: #{value}` uses the named colour #{name}"
      end
    end

    # Paper is the only light surface the site has. Mint belongs on graphite,
    # so no role may resolve to mint or its text tint once the page is printed.
    for {path, css} <- stylesheets(), print <- blocks(css, "@media print") do
      for [literal] <- Regex.scan(~r/#[0-9a-fA-F]{6}\b/, print) do
        refute normalize(literal) in @mint_text, "#{path} prints mint on paper"
      end
    end
  end

  test "the site sets type only in the packaged IBM Plex faces" do
    manifest = manifest()

    for {path, css} <- stylesheets() do
      for face <- blocks(css, "@font-face") do
        [_, url] = Regex.run(~r/url\("([^"]+)"\)/, face)
        assert Map.has_key?(@plex, url), "#{path} packages #{url}, not a supplied Plex face"
        {family, weight} = Map.fetch!(@plex, url)
        assert face =~ ~s(font-family: "#{family}"), "#{path}: #{url} is not #{family}"
        assert face =~ "font-weight: #{weight}", "#{path}: #{url} is not weight #{weight}"
        assert face =~ "font-display: swap"
      end

      for {property, value} <- declarations(css) do
        for [_, quoted] <- Regex.scan(~r/"([^"]*)"/, value),
            property == "font-family" or property == "font" or stack?(value) do
          assert quoted in ["IBM Plex Sans", "IBM Plex Mono"],
                 "#{path}: `#{property}: #{value}` names the font #{quoted}"
        end

        if property == "font-family" or stack?(value) do
          for family <- value |> String.split(",") |> Enum.map(&String.trim/1) do
            assert family in @families or family in ~w(var(--sans\) var(--mono\) inherit),
                   "#{path}: `#{property}: #{value}` falls back to #{family}"
          end
        end

        if property == "font" do
          assert value =~ ~r/(var\(--(sans|mono)\)|inherit)\s*$/,
                 "#{path}: `font: #{value}` does not use the Plex stacks"
        end

        # Only Regular and SemiBold are supplied; any other weight is a
        # substituted or synthesised face.
        for weight <- declared_weights(property, value) do
          assert weight in ["400", "600"], "#{path}: `#{property}: #{value}`"
        end
      end

      refute css =~ ~r/url\(\s*["']?(https?:)?\/\//, "#{path} loads something remote"
    end

    # The packaged faces are the supplied bytes, and their licence ships with them.
    for file <- ["LICENSE.txt" | Enum.map(Map.keys(@plex), &Path.basename/1)] do
      source = "brand/assets/fonts/" <> file

      assert sha256(Path.join([@site, "assets/fonts", file])) == Map.fetch!(manifest, source),
             "site/assets/fonts/#{file} is not #{source}"
    end

    assert Enum.sort(File.ls!(Path.join(@site, "assets/fonts"))) ==
             Enum.sort(["LICENSE.txt" | Enum.map(Map.keys(@plex), &Path.basename/1)])

    for {page, document} <- pages(),
        href <- document |> LazyHTML.query(~s(link[as="font"])) |> LazyHTML.attribute("href") do
      assert Map.has_key?(@plex, String.replace(href, ~r{^(\.\./)?assets/}, "")),
             "#{page} preloads #{href}"
    end
  end

  test "every page shows the supplied artwork at its size and never retypes the logo" do
    manifest = manifest()

    for file <- File.ls!(Path.join(@site, "assets/brand")) do
      assert sha256(Path.join([@site, "assets/brand", file])) ==
               Map.fetch!(manifest, "brand/ryker/" <> file),
             "site/assets/brand/#{file} is not the supplied brand/ryker/#{file}"
    end

    for {page, document} <- pages(), region <- ["header", "footer"] do
      # The site is graphite, so both signatures are the dark-surface lockup.
      lockup = LazyHTML.query(document, region <> " img")
      assert [src] = LazyHTML.attribute(lockup, "src"), "#{page} #{region} has no lockup"
      assert String.ends_with?(src, "assets/brand/lockup-color.svg"), "#{page} #{region}"
      assert LazyHTML.attribute(lockup, "alt") == ["Ryker"]
      [width] = LazyHTML.attribute(lockup, "width")

      assert String.to_integer(width) >= @lockup_min_canvas,
             "#{page} #{region} lockup is too small"

      text = document |> LazyHTML.query(region) |> LazyHTML.text()
      refute text =~ ~r/(^|\s)Ryker(\s|$)/, "#{page} types the name in its #{region}"
    end

    # Ryker's Slack avatar is the supplied composition, never a letter in a square.
    for {page, document} <- pages(), message <- LazyHTML.query(document, ".slack-msg") do
      if message |> LazyHTML.query(".slack-who") |> LazyHTML.text() == "Ryker" do
        avatar = LazyHTML.query(message, ".slack-av")
        assert LazyHTML.tag(avatar) == ["img"], "#{page} retypes Ryker's avatar"
        assert [src] = LazyHTML.attribute(avatar, "src")
        assert String.ends_with?(src, "assets/brand/avatar.svg")
      end
    end

    # The stylesheet sizes the lockup, so it has to agree with the markup, and
    # the header link keeps a quarter of the lowercase height (6.4px at this
    # size) clear around the canvas.
    [{_, css}] = Enum.filter(stylesheets(), fn {path, _} -> path =~ "site.css" end)

    for selector <- [".wordmark img", ".foot-lockup"] do
      widths =
        for rule <- rules(css, selector),
            [_, width] <- Regex.scan(~r/(?<![\w-])width:\s*(\d+)px/, rule) do
          assert rule =~ "height: auto", "#{selector} can distort the lockup"
          String.to_integer(width)
        end

      assert widths != [], "site.css does not size #{selector}"

      assert Enum.all?(widths, &(&1 >= @lockup_min_canvas)),
             "#{selector} renders the lockup at #{inspect(widths)}px"
    end

    assert [_ | _] = links = rules(css, ".wordmark")

    for rule <- links,
        [_, padding] <- Regex.scan(~r/(?<![\w-])padding:\s*([^;]+)/, rule),
        [px] <- Regex.scan(~r/\d+/, padding) do
      assert String.to_integer(px) >= 7, "the header lockup has #{px}px of clear space"
    end
  end

  defp stylesheets do
    @site
    |> Path.join("**/*.css")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      {Path.relative_to(path, @repo_root), Regex.replace(~r{/\*.*?\*/}s, File.read!(path), "")}
    end)
  end

  defp pages do
    @site
    |> Path.join("**/*.html")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, @repo_root), LazyHTML.from_document(File.read!(&1))})
  end

  # `property: value` pairs; a selector such as `a:hover {` never ends in `;` or `}`.
  defp declarations(css) do
    ~r/([a-zA-Z0-9-]+)\s*:\s*([^;{}]+)(?=[;}])/
    |> Regex.scan(css)
    |> Enum.map(fn [_, property, value] -> {property, String.trim(value)} end)
  end

  # The body of every block opened by `at`, nested braces and all.
  defp blocks(css, at) do
    ~r/#{Regex.escape(at)}[^{]*(\{(?:[^{}]++|(?1))*\})/
    |> Regex.scan(css, capture: :all_but_first)
    |> Enum.map(fn [block] -> String.slice(block, 1..-2//1) end)
  end

  defp rules(css, selector) do
    ~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/
    |> Regex.scan(css)
    |> Enum.map(fn [_, body] -> body end)
  end

  defp stack?(value), do: value =~ ~r/(^|,)\s*(sans-serif|monospace)\s*$/

  defp declared_weights("font-weight", value), do: [value]

  defp declared_weights("font", value) do
    case Regex.run(~r/^(?:normal\s+|italic\s+)?(\d{3})\s/, value) do
      [_, weight] -> [weight]
      nil -> []
    end
  end

  defp declared_weights(_property, _value), do: []

  defp palette do
    ~r/--ryker-[a-z0-9-]+:\s*(#[0-9a-fA-F]{6})\s*;/
    |> Regex.scan(File.read!(Path.join(@repo_root, @tokens)))
    |> MapSet.new(fn [_, hex] -> String.downcase(hex) end)
  end

  defp normalize("#" <> <<r, g, b>>), do: String.downcase(<<?#, r, r, g, g, b, b>>)
  defp normalize(hex), do: String.downcase(hex)

  defp manifest do
    @repo_root
    |> Path.join(@manifest)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [sha, path] = String.split(line, ~r/\s+/, parts: 2)
      {path, sha}
    end)
  end

  defp sha256(path),
    do: digest(File.read!(path))
end
