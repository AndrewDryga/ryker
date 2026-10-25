defmodule Ryker.ControlPlane.ExecutionCardDesignTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, Components}

  test "raw copy is the final utility in its own content block" do
    html = Components.copy_block_html("<pre>exact retained bytes</pre>") |> IO.iodata_to_binary()
    assert :binary.match(html, "</pre>") < :binary.match(html, "data-copy-block")
    assert html =~ "exact retained bytes"
  end

  test "service badges use supplied artwork beside a readable name" do
    for service <- [:emisar, :slack, :github, :ryker, :workspace] do
      html = render_component(&Components.service_badge/1, service: service)
      assert html =~ "data-service=\"#{service}\""
      assert html =~ Components.service_name(service)
      if service != :workspace, do: assert(html =~ "service-mark")
    end

    for service <- ["slack", "github"] do
      conn = Assets.call(Plug.Test.conn(:get, "/platforms/#{service}.svg"), [])
      assert conn.status == 200
      assert conn.resp_body == File.read!("site/assets/platforms/#{service}.svg")
    end
  end

  test "an outcome keeps decision and attributed reason together without large competing panels" do
    html =
      render_component(&Components.outcome/1,
        decision: "Answer now",
        reason: "A short greeting.",
        reason_label: "Model's reason"
      )

    assert html =~ "Answer now"
    assert html =~ "A short greeting."
    assert html =~ "Model&#39;s reason"
    assert html =~ "decision-outcome"
    refute html =~ "data-copy"
    refute html =~ "<h3"
  end
end
