defmodule Ryker.GitHub.ActionLinksTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.ActionLinks

  test "review controls name the exact binding, PR and reviewed head and only accompany findings" do
    base = "https://ryker.example/github/actions/review/widget"
    head = String.duplicate("a", 40)
    body = ActionLinks.review("Two findings.", base, 42, head, [%{"body" => "Check input."}])
    assert body =~ "[**Fix all findings**](#{base}/42/#{head}/all)"
    assert body =~ "[**Fix selected (👍)**](#{base}/42/#{head}/selected)"
    assert ActionLinks.review("Looks good.", base, 42, head, []) == "Looks good."
    assert ActionLinks.review("One finding.", nil, 42, head, [%{}]) == "One finding."
  end
end
