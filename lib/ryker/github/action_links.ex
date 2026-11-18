defmodule Ryker.GitHub.ActionLinks do
  @moduledoc "Host-owned links from GitHub reviews to repository action pages."

  def review(body, _base, _number, _head, []), do: body
  def review(body, nil, _number, _head, _comments), do: body

  def review(body, base, number, head, _comments) do
    path = "#{base}/#{number}/#{head}"

    body <>
      "\n\n---\n\n[**Fix all findings**](#{path}/all) · [**Fix selected (👍)**](#{path}/selected)\n\n" <>
      "Choose findings on the next page. Your own thumbs-ups are preselected."
  end
end
