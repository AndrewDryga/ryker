defmodule Ryker.ControlPlane.PublicPageTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias Ryker.ControlPlane.PublicPage

  test "public page titles and escaped body values stay text" do
    attack = "<script>alert('no')</script>"

    page =
      PublicPage.page(conn(:get, "/"), 409, attack, ["<p>", PublicPage.escape(attack), "</p>"])

    assert page.status == 409
    assert page.halted
    assert page.resp_body =~ "&lt;script&gt;"
    refute page.resp_body =~ "<script>"
  end
end
