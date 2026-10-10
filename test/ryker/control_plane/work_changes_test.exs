defmodule Ryker.ControlPlane.WorkChangesTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.ControlPlane.WorkChanges

  @work_ref "task-card:abc123"

  # Moved here from the Slack work-control tests when diff reading became
  # web-only on 2026-09-09. The page contract is the only thing standing
  # between a reviewer and a patch that silently lost bytes, so it keeps its
  # own owner rather than riding along with whichever page happens to call it.
  test "a page is only rendered for its own exact snapshot" do
    patch = "diff --git a/lib/ryker.ex b/lib/ryker.ex\n+safe change\n"
    digest = digest(patch)

    assert {:ok, page} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))

    assert page["patch_digest"] == digest
    assert page["patch_offset"] == 0
    assert page["patch_next_offset"] == byte_size(patch)
    assert page["patch_has_more"] == false
    assert page["message"] =~ "lib/ryker.ex"
    assert page["message"] =~ "+safe change"

    forged =
      patch
      |> changes_page(digest, 0, 2_400)
      |> Map.put("patch_digest", digest(patch <> "smuggled"))

    assert WorkChanges.render(@work_ref, forged) == {:error, :work_diff_digest_mismatch}
  end

  # The Chat diff page opened with "Workspace diff for record:task_offer:605e…", the patch's
  # SHA-256 and "Patch bytes: 0-149 of 149" (manual test, 2026-10-09): Ryker's own reference
  # and bookkeeping, shown to a person who came to read the change.
  test "a diff page reads in words, without Ryker's references, digests or byte counts" do
    patch = "diff --git a/lib/ryker.ex b/lib/ryker.ex\n+safe change\n"
    digest = digest(patch)

    assert {:ok, page} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))
    assert page["message"] =~ "1 changed file in this working copy."
    assert page["message"] =~ "committed: lib/ryker.ex (modified)"

    for internal <- [@work_ref, digest, "Snapshot", "Patch bytes", "patch page", "Workspace diff"] do
      refute page["message"] =~ internal, "the page shows #{internal}"
    end
  end

  test "an incomplete first page keeps its continuation and never claims to be whole" do
    patch = String.duplicate("a", 2_400) <> String.duplicate("b", 600)
    digest = digest(patch)

    assert {:ok, first} = WorkChanges.render(@work_ref, changes_page(patch, digest, 0, 2_400))
    assert first["patch_has_more"]
    assert first["patch_next_offset"] == 2_400
    assert first["message"] =~ "The rest of the changes is on the next page."

    assert {:ok, last} =
             WorkChanges.render(@work_ref, changes_page(patch, digest, 2_400, 2_400))

    assert last["patch_has_more"] == false
    assert last["message"] =~ "Continued from the previous page."
    refute last["message"] =~ "next page"
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
    assert page["message"] =~ "This part of the changes is binary and is not shown."
    refute page["message"] =~ "\0"
  end

  test "an unauthorized work reference never reaches the changes page" do
    patch = "diff --git a/lib/ryker.ex b/lib/ryker.ex\n+safe change\n"
    changes = changes_page(patch, digest(patch), 0, 2_400)

    assert WorkChanges.render("record:memory_offer:abc123", changes) ==
             {:error, :work_diff_invalid}

    assert WorkChanges.render(@work_ref, %{"patch" => "not base64"}) ==
             {:error, :work_diff_invalid}
  end

  # Coop's page metadata was trusted to be numbers: an offset sent as text raised in the
  # arithmetic and the changes page crashed instead of saying the view is unavailable
  # (2026-10-04 review).
  test "page metadata of the wrong type is refused, never a crash" do
    patch = "diff --git a/lib/ryker.ex b/lib/ryker.ex\n+safe change\n"
    page = changes_page(patch, digest(patch), 0, 2_400)

    for {field, value} <- [
          {"patch_offset", "0"},
          {"patch_next_offset", nil},
          {"patch_bytes", "53"}
        ] do
      assert WorkChanges.render(@work_ref, Map.put(page, field, value)) ==
               {:error, :work_diff_invalid}
    end
  end

  defp changes_page(full_patch, patch_digest, offset, limit) do
    size = byte_size(full_patch)
    page = binary_part(full_patch, offset, min(limit, size - offset))
    next_offset = offset + byte_size(page)

    %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/ryker.ex", "status" => "modified"}],
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
end
