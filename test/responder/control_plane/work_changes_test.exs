defmodule Responder.ControlPlane.WorkChangesTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.WorkChanges

  @work_ref "task-card:abc123"

  # Moved here from the Slack work-control tests when diff reading became
  # web-only on 2026-09-09. The page contract is the only thing standing
  # between a reviewer and a patch that silently lost bytes, so it keeps its
  # own owner rather than riding along with whichever page happens to call it.
  test "a page is only rendered for its own exact snapshot" do
    patch = "diff --git a/lib/responder.ex b/lib/responder.ex\n+safe change\n"
    digest = digest(patch)

    assert {:ok, page} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))

    assert page["patch_digest"] == digest
    assert page["patch_offset"] == 0
    assert page["patch_next_offset"] == byte_size(patch)
    assert page["patch_has_more"] == false
    assert page["message"] =~ "lib/responder.ex"
    assert page["message"] =~ "+safe change"
    assert page["message"] =~ digest

    forged =
      patch
      |> changes_page(digest, 0, 2_400)
      |> Map.put("patch_digest", digest(patch <> "smuggled"))

    assert WorkChanges.render(@work_ref, forged) == {:error, :work_diff_digest_mismatch}
  end

  test "an incomplete first page keeps its continuation and never claims to be whole" do
    patch = String.duplicate("a", 2_400) <> String.duplicate("b", 600)
    digest = digest(patch)

    assert {:ok, first} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))
    assert first["patch_has_more"]
    assert first["patch_next_offset"] == 2_400
    assert first["message"] =~ "More patch bytes remain"

    assert {:ok, last} =
             WorkChanges.render(@work_ref, changes_page(patch, digest, 2_400, 2_400))

    assert last["patch_has_more"] == false
    assert last["message"] =~ "This is the final patch page."
    assert last["message"] =~ String.duplicate("b", 20)

    truncated =
      patch
      |> changes_page(digest, 0, 2_400)
      |> Map.put("patch_next_offset", byte_size(patch))

    assert WorkChanges.render(@work_ref, truncated) == {:error, :work_diff_invalid}
  end

  test "a non-textual patch page is described rather than pasted" do
    patch = <<0, 1, 2, 3, 4>>
    digest = digest(patch)

    assert {:ok, page} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))
    assert page["message"] =~ "binary patch page omitted"
    refute page["message"] =~ "\0"
  end

  test "an unauthorized work reference never reaches the changes page" do
    patch = "diff --git a/lib/responder.ex b/lib/responder.ex\n+safe change\n"
    changes = changes_page(patch, digest(patch), 0, 2_400)

    assert WorkChanges.render("record:memory_offer:abc123", changes) ==
             {:error, :work_diff_invalid}

    assert WorkChanges.render(@work_ref, %{"patch" => "not base64"}) ==
             {:error, :work_diff_invalid}
  end

  defp changes_page(full_patch, patch_digest, offset, limit) do
    size = byte_size(full_patch)
    page = binary_part(full_patch, offset, min(limit, size - offset))
    next_offset = offset + byte_size(page)

    %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/responder.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => String.duplicate("b", 40),
      "fork_tree" => String.duplicate("c", 40),
      "parent_head" => String.duplicate("d", 40),
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch" => Base.encode64(page),
      "patch_bytes" => size,
      "patch_digest" => patch_digest,
      "patch_has_more" => next_offset < size,
      "patch_next_offset" => next_offset,
      "patch_offset" => offset,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
