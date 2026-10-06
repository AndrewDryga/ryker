defmodule Ryker.ControlPlane.AssetsTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Assets, BrowserGuard}

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
      Plug.Test.conn(:get, "/control-plane.js")
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> BrowserGuard.call([])
      |> Assets.call([])

    assert guarded.status == 200
    assert Plug.Conn.get_resp_header(guarded, "cache-control") == ["no-cache"]
  end

  defp get(path, headers \\ []) do
    headers
    |> Enum.reduce(Plug.Test.conn(:get, path), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> Assets.call([])
  end
end
