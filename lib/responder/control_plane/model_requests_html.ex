defmodule Responder.ControlPlane.ModelRequestsHTML do
  @moduledoc false

  alias Responder.ControlPlane.RequestContextHTML

  def render(view) do
    path =
      if view.episode_ref,
        do: "/episodes/#{URI.encode_www_form(view.episode_ref)}/requests",
        else: "/episodes/ingress-input%3A#{view.input_id}"

    back =
      if view.episode_ref, do: "/episodes/#{URI.encode_www_form(view.episode_ref)}", else: "/lab"

    [
      "<section class=\"request-heading\"><a href=\"",
      escape(back),
      "\">← Back to activity</a><p class=\"eyebrow\">Model request inspector</p><h2>What the model actually received</h2>",
      "<p>Retained submissions, decisions, and tool activity. Credentials are redacted before display; sanitized JSON is formatted for reading.</p>",
      "<nav class=\"request-tabs\" aria-label=\"Request type\">",
      if(view.episode_ref, do: tab(path, "work", "Work", view.kind), else: ""),
      tab(path, "admission", "Admission", view.kind),
      "</nav></section>",
      "<div class=\"request-workbench\"><aside class=\"request-attempts\"><h3>Requests · ",
      escape(view.total),
      "</h3>",
      Enum.map(view.items, fn item ->
        [
          "<a class=\"request-attempt\" href=\"",
          escape(link(path, view, %{attempt: item.id})),
          "\"",
          if(view.selected && item.id == view.selected.id,
            do: " aria-current=\"page\"",
            else: ""
          ),
          "><strong>",
          escape(human(item.status)),
          "</strong><time>",
          escape(time(item.at)),
          "</time></a>"
        ]
      end),
      pagination(path, view, :page, view.page, view.pages),
      "</aside><article class=\"request-detail\">",
      selected(view.selected, path, view),
      if(view.selected && Map.has_key?(view.selected, :generation),
        do:
          pagination(path, view, :generation, view.selected.generation, view.selected.generations),
        else: ""
      ),
      "</article></div>"
    ]
  end

  defp selected(nil, _path, _view),
    do: "<p class=\"request-empty\">No requests recorded on this page.</p>"

  defp selected(request, path, view) do
    [
      "<header><p class=\"eyebrow\">",
      escape(request.title),
      "</p><h2>",
      escape(request.target),
      "</h2><p>",
      escape(human(request.status)),
      " · ",
      escape(time(request.at)),
      "</p></header>",
      "<p class=\"request-coverage\">",
      escape(request.coverage),
      "</p>",
      "<nav class=\"request-section-index\" aria-label=\"Request sections\">",
      Enum.map(
        request.sections,
        &["<a href=\"#request-", escape(&1.id), "\">", escape(&1.title), "</a>"]
      ),
      "</nav>",
      Enum.map(request.sections, fn section ->
        [
          "<details class=\"request-section\" id=\"request-",
          escape(section.id),
          "\"",
          if(section.id in ["instructions", "input"], do: " open", else: ""),
          "><summary><span>",
          escape(section.title),
          "</span><small>",
          state(section.artifact),
          "</small></summary>",
          if(section.id == "context",
            do:
              RequestContextHTML.render(
                section.artifact,
                if(section[:source_kind] == :work, do: "$.work", else: "$.context"),
                "request-#{request.id}"
              ),
            else: ""
          ),
          artifact(section.artifact),
          "</details>"
        ]
      end),
      "<section class=\"request-tool-history\"><h3>Tool calls and host activity · ",
      escape(request.tools.total),
      "</h3>",
      "<p>Only retained public activity is shown. A completion status is not a retained tool result body; missing tool results cannot be reconstructed.</p>",
      Enum.map(request.tools.items, fn tool ->
        [
          "<details class=\"request-section\" id=\"tool-",
          escape(tool.id),
          "\"><summary>",
          escape(tool.kind),
          " · ",
          escape(time(tool.at)),
          "</summary>",
          artifact(tool.artifact),
          "</details>"
        ]
      end),
      pagination(path, view, :tools_page, request.tools.page, request.tools.pages),
      "</section>",
      "<details class=\"request-provenance\"><summary>Request identity and policy</summary>",
      "<p>Policy: ",
      escape(request.policy),
      "</p><p>Request: <code>",
      escape(request.id),
      "</code></p><p>Retained artifact fingerprint: <code>",
      escape(request.fingerprint || "not recorded"),
      "</code></p></details>"
    ]
  end

  defp artifact(%{state: state}) when state != :retained do
    [
      "<p class=\"request-empty\">",
      if(state == :expired,
        do: "Expired under the retention policy.",
        else: "Not recorded. No reconstructed substitute is shown."
      ),
      "</p>"
    ]
  end

  defp artifact(artifact) do
    [
      "<p class=\"artifact-identity\">Original: ",
      escape(artifact.bytes),
      " bytes · SHA-256 <code>",
      escape(artifact.sha256),
      "</code>",
      if(artifact.redacted,
        do: " · Redacted: this display differs from the retained original.",
        else: ""
      ),
      if(artifact.truncated, do: " · Display truncated; original identity preserved.", else: ""),
      "</p><pre class=\"request-document\" tabindex=\"0\">",
      escape(artifact.text),
      "</pre>"
    ]
  end

  defp state(%{state: :expired}), do: "Expired"
  defp state(%{state: :not_recorded}), do: "Not recorded"

  defp state(artifact),
    do: [
      if(artifact.redacted, do: "Redacted", else: "Retained"),
      if(artifact.truncated, do: " · Truncated", else: "")
    ]

  defp tab(path, kind, title, current),
    do: [
      "<a href=\"",
      escape(path <> "?kind=" <> kind),
      "\"",
      if(Atom.to_string(current) == kind, do: " aria-current=\"page\"", else: ""),
      ">",
      title,
      "</a>"
    ]

  defp pagination(_path, _view, _key, _page, 1), do: []

  defp pagination(path, view, key, page, pages) do
    [
      "<nav class=\"pagination\" aria-label=\"Pagination\">",
      if(page > 1,
        do: ["<a href=\"", escape(link(path, view, %{key => page - 1})), "\">← Previous</a>"],
        else: ""
      ),
      "<span>",
      escape(page),
      " / ",
      escape(pages),
      "</span>",
      if(page < pages,
        do: ["<a href=\"", escape(link(path, view, %{key => page + 1})), "\">Next →</a>"],
        else: ""
      ),
      "</nav>"
    ]
  end

  defp link(path, view, changes) do
    params = %{kind: view.kind, page: view.page}

    params =
      if view.selected && not Map.has_key?(changes, :page),
        do: Map.put(params, :attempt, view.selected.id),
        else: params

    path <> "?" <> URI.encode_query(Map.merge(params, changes))
  end

  defp time(at), do: Calendar.strftime(at, "%d %b · %H:%M:%S UTC")
  defp human(value), do: value |> to_string() |> String.replace("_", " ")

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
