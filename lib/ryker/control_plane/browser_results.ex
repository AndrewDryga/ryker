defmodule Ryker.ControlPlane.BrowserResults do
  @moduledoc "A protected, durable view of browser observations and retained screenshots."
  import Plug.Conn
  alias Ryker.Artifacts
  alias Ryker.ControlPlane.{PathRef, PublicPage}

  def call(conn, action, token, options) do
    case Artifacts.shared_results(conn.path_params["turn"], token, options) do
      {:ok, result} -> respond(conn, action, result)
      {:error, _unavailable} -> unavailable(conn)
    end
  end

  defp respond(conn, :browser_results, result) do
    PublicPage.page(conn, 200, "Browser results", html(result))
  end

  defp respond(conn, :result_image, result) do
    with {:ok, ref} <- PathRef.decode(conn.path_params["ref"]),
         artifact when not is_nil(artifact) <- Enum.find(result.artifacts, &(&1.ref == ref)) do
      image(conn, artifact)
    else
      _unavailable -> unavailable(conn)
    end
  end

  def html(result) do
    [
      "<div class=\"github-action-page browser-results\"><p class=\"eyebrow\">Retained task evidence</p><p>",
      PublicPage.escape(result.repository),
      "</p><p>Checks below are reported by the task. Ryker verifies and retains image bytes; a screenshot alone does not prove a check passed.</p>",
      Enum.map(result.reports, &report(&1, result)),
      if(result.reports == [],
        do: "<p>No structured browser report was recorded for this turn.</p>",
        else: ""
      ),
      "<section><h2>Retained images</h2><div class=\"browser-image-grid\">",
      Enum.map(result.artifacts, &figure(&1, result.turn.id)),
      "</div>",
      empty_images(result.artifacts),
      if(result.missing_images > 0,
        do: "<p>Some selected images have expired or are unavailable.</p>",
        else: ""
      ),
      "</section><p class=\"hint\">Access is checked against current repository permissions on every view. Images remain available until this turn’s operational data is pruned under the installation’s retention settings. These links do not point to the worker.</p></div>"
    ]
  end

  defp report(report, result) do
    doc = report.document

    [
      "<section class=\"browser-report\"><h2>",
      PublicPage.escape(doc["title"]),
      "</h2><p>Observed ",
      PublicPage.escape(doc["observed_at"]),
      " · Recorded ",
      PublicPage.escape(DateTime.to_iso8601(report.inserted_at)),
      "</p><details><summary>Tested revision</summary><dl><dt>Commit reported by task</dt><dd><code>",
      PublicPage.escape(doc["revision"]["commit"]),
      "</code></dd><dt>Tree reported by task</dt><dd><code>",
      PublicPage.escape(doc["revision"]["tree"]),
      "</code></dd><dt>Uncommitted changes</dt><dd>",
      if(doc["revision"]["dirty"], do: "Yes", else: "No"),
      "</dd><dt>Starting commit pinned by Ryker</dt><dd><code>",
      PublicPage.escape(get_in(report.source, ["binding", "selected_commit"]) || "Unavailable"),
      "</code></dd></dl></details>",
      Enum.map(doc["cases"], &test_case(&1, result)),
      "</section>"
    ]
  end

  defp test_case(test, result) do
    screenshot = test["screenshot"]

    image =
      Enum.find(
        result.artifacts,
        &(&1.name == screenshot and &1.sha256 == test["screenshot_sha256"])
      )

    [
      "<article class=\"browser-case\"><div class=\"browser-case-heading\"><h3>",
      PublicPage.escape(test["name"]),
      "</h3><span class=\"browser-result-status\" data-status=\"",
      test["status"],
      "\">",
      PublicPage.escape(String.capitalize(test["status"])),
      "</span></div><p>",
      Integer.to_string(test["viewport"]["width"]),
      " × ",
      Integer.to_string(test["viewport"]["height"]),
      "</p><ol>",
      Enum.map(test["steps"], &["<li>", PublicPage.escape(&1), "</li>"]),
      "</ol><dl><dt>Expected</dt><dd>",
      PublicPage.escape(test["expected"]),
      "</dd><dt>Observed</dt><dd>",
      PublicPage.escape(test["observed"]),
      "</dd></dl>",
      screenshot_link(screenshot, image, result.turn.id),
      "</article>"
    ]
  end

  defp screenshot_link(nil, _image, _turn),
    do: "<p class=\"hint\">No screenshot recorded for this check.</p>"

  defp screenshot_link(_name, nil, _turn),
    do: "<p class=\"hint\">Screenshot not retained yet or expired.</p>"

  defp screenshot_link(name, image, turn),
    do: ["<a href=\"", image_path(turn, image.ref), "\">Open ", PublicPage.escape(name), "</a>"]

  defp figure(artifact, turn) do
    path = image_path(turn, artifact.ref)

    [
      "<figure><a href=\"",
      path,
      "\"><img loading=\"lazy\" src=\"",
      path,
      "\" alt=\"",
      PublicPage.escape(artifact.name),
      "\"></a><figcaption>",
      PublicPage.escape(artifact.name),
      " · ",
      Integer.to_string(artifact.byte_size),
      " bytes</figcaption></figure>"
    ]
  end

  defp image_path(turn, ref),
    do: "/github/actions/results/#{turn}/images/#{URI.encode(ref, &URI.char_unreserved?/1)}"

  # The stored type and bytes are verified by Artifacts.Outputs; HTML and SVG are refused there.
  # sobelow_skip ["XSS.SendResp"]
  defp image(conn, artifact) do
    conn
    |> put_resp_header("content-type", artifact.media_type)
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-disposition",
      "inline; filename*=UTF-8''" <> URI.encode(artifact.name, &URI.char_unreserved?/1)
    )
    |> send_resp(200, artifact.data)
    |> halt()
  end

  defp empty_images([]) do
    "<p>No selected images are available. They may still be pending, may not have been selected, or may have expired.</p>"
  end

  defp empty_images(_images), do: ""

  defp unavailable(conn) do
    PublicPage.page(
      conn,
      404,
      "Results unavailable",
      "<p>These results have expired, are not retained, or your GitHub account does not have access to the repository.</p>"
    )
  end
end
