defmodule Ryker.ControlPlane.AssetsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, BrowserGuard, Layouts}

  test "a deployment cannot combine current HTML with cached older styles or module imports" do
    # The CDN changed no-cache to a four-hour browser cache. A successful
    # deployment then rendered new plan markup with old CSS and command hooks.
    # A content-addressed directory must cover the entire module graph.
    paths = Layouts.stylesheets()
    assert Enum.all?(paths, &Regex.match?(~r|\A/assets/[a-f0-9]{32}/[^/]+\.css\z|, &1))
    prefix = paths |> hd() |> Path.dirname()

    html = render_component(&Layouts.root/1, page_title: "Activity", inner_content: "")

    scripts =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("script[src]")
      |> LazyHTML.attribute("src")

    assert length(scripts) == 2
    assert Enum.all?(scripts, &(Path.dirname(&1) == prefix))
    assert_imports_served(scripts, MapSet.new())

    assert Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).status == 404
    assert get("/" <> String.duplicate("0", 32) <> "/workspace.css").status == 404
  end

  defp assert_imports_served([], _visited), do: :ok

  defp assert_imports_served([path | rest], visited) do
    if MapSet.member?(visited, path) do
      assert_imports_served(rest, visited)
    else
      response = get(String.replace_prefix(path, "/assets", ""))
      assert response.status == 200, path

      imports =
        for [_, relative] <- Regex.scan(~r/^import .* from "([^"\s]+)"/m, response.resp_body) do
          assert String.starts_with?(relative, "./"), "unversioned import #{relative}"
          Path.join(Path.dirname(path), String.trim_leading(relative, "./"))
        end

      assert_imports_served(rest ++ imports, MapSet.put(visited, path))
    end
  end

  # Every page load downloaded the console's scripts and stylesheets again, about 650 KB
  # uncompressed, because every response leaves BrowserGuard marked no-store (2026-10-04). A
  # script or stylesheet now carries an ETag of its bytes: the browser keeps it, asks whether it
  # changed, and a deploy that changed it answers with the new bytes.
  test "a script is kept by the browser until its bytes change" do
    first = get("/workspace.css")
    assert first.status == 200
    assert [etag] = Plug.Conn.get_resp_header(first, "etag")
    assert Plug.Conn.get_resp_header(first, "cache-control") == ["no-cache"]
    assert first.resp_body == File.read!("priv/static/workspace.css")

    again = get("/workspace.css", [{"if-none-match", etag}])
    assert again.status == 304
    assert again.resp_body == ""

    # Another file's tag, or none, gets the bytes.
    assert get("/workspace.css", [{"if-none-match", ~s("other")}]).status == 200
    assert [other] = Plug.Conn.get_resp_header(get("/phoenix.mjs"), "etag")
    refute other == etag
  end

  test "text is sent compressed to a browser that accepts it, and never a font" do
    plain = File.read!("priv/static/workspace.css")
    compressed = get("/workspace.css", [{"accept-encoding", "gzip, deflate, br"}])

    assert compressed.status == 200
    assert Plug.Conn.get_resp_header(compressed, "content-encoding") == ["gzip"]
    assert Plug.Conn.get_resp_header(compressed, "vary") == ["accept-encoding"]
    assert :zlib.gunzip(compressed.resp_body) == plain
    assert byte_size(compressed.resp_body) < div(byte_size(plain), 3)

    font = get("/brand/fonts/IBMPlexSans-Regular.woff2", [{"accept-encoding", "gzip"}])
    assert Plug.Conn.get_resp_header(font, "content-encoding") == []
  end

  # The compressed and plain bytes carried one strong tag, so a cache holding
  # the compressed copy could answer a browser that cannot unpack it with a
  # 304 for those bytes; and "gzip;q=0", which refuses gzip, counted as
  # accepting it (2026-10-04 review).
  test "each encoding has its own tag, and a refused gzip is not sent" do
    plain = get("/workspace.css")
    compressed = get("/workspace.css", [{"accept-encoding", "gzip"}])
    assert [plain_tag] = Plug.Conn.get_resp_header(plain, "etag")
    assert [gzip_tag] = Plug.Conn.get_resp_header(compressed, "etag")
    refute plain_tag == gzip_tag

    # The compressed copy's tag does not validate the plain bytes.
    assert get("/workspace.css", [{"if-none-match", gzip_tag}]).status == 200

    assert get("/workspace.css", [{"accept-encoding", "gzip"}, {"if-none-match", gzip_tag}]).status ==
             304

    for refused <- ["gzip;q=0", "gzip; q=0.0, deflate", "identity", "br"] do
      response = get("/workspace.css", [{"accept-encoding", refused}])
      assert Plug.Conn.get_resp_header(response, "content-encoding") == [], refused
    end

    for accepted <- ["gzip;q=0.5", "deflate, GZIP", "*"] do
      response = get("/workspace.css", [{"accept-encoding", accepted}])
      assert Plug.Conn.get_resp_header(response, "content-encoding") == ["gzip"], accepted
    end
  end

  test "the page guard's no-store does not reach a script" do
    guarded =
      Plug.Test.conn(:get, String.replace_prefix(Assets.path("control-plane.js"), "/assets", ""))
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> BrowserGuard.call([])
      |> Assets.call([])

    assert guarded.status == 200
    assert Plug.Conn.get_resp_header(guarded, "cache-control") == ["no-cache"]
  end

  defp get(path, headers \\ []) do
    path =
      if path in ~w(/workspace.css /phoenix.mjs),
        do: String.replace_prefix(Assets.path(String.trim_leading(path, "/")), "/assets", ""),
        else: path

    headers
    |> Enum.reduce(Plug.Test.conn(:get, path), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> Assets.call([])
  end
end
