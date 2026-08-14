package taskcard

import (
	"bytes"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
)

// ChangesStat is "3 files · +48 −12", or nothing.
//
// Nothing is the important half. The diff is fetched a page at a time — seven
// kilobytes, whatever that lands in the middle of — and a file count taken from
// the first page of a sixty-kilobyte patch reads exactly like a file count
// taken from the whole of it. So the stat is computed only when the fetch holds
// the entire patch, and omitted otherwise: the operator can open the diff and
// see for themselves, which is worse than a number and much better than a wrong
// one.
//
// Whole means all three at once. PatchOffset 0 says the page starts at the
// beginning, PatchHasMore false says nothing follows it, and Truncated false
// says Coop did not cut the patch short before paging ever entered it.
func ChangesStat(changes coop.Changes) string {
	if changes.Truncated || changes.PatchHasMore || changes.PatchOffset != 0 {
		return ""
	}
	return PatchStat(changes.Patch)
}

// PatchStat counts a whole unified diff in one pass.
//
// Files are counted from `diff --git` headers rather than from `+++` lines,
// because the two disagree on exactly the cases worth counting: a rename with
// no edits has a `diff --git` and no hunk at all, and a deletion writes
// `+++ /dev/null`. A binary file has a header and no line changes, which is the
// truth about it — one file touched, nothing to add up.
func PatchStat(patch []byte) string {
	files, added, removed := 0, 0, 0
	seenHeader := false
	for line := range bytes.Lines(patch) {
		switch {
		case bytes.HasPrefix(line, []byte("diff --git ")):
			files++
			seenHeader = true
		case bytes.HasPrefix(line, []byte("+++ ")), bytes.HasPrefix(line, []byte("--- ")):
			// The file headers of a hunk, not content. Skipped before the
			// single-character cases below can read them as a line each.
		case bytes.HasPrefix(line, []byte("+")):
			added++
		case bytes.HasPrefix(line, []byte("-")):
			removed++
		}
	}
	// A patch from a producer that emits no `diff --git` header — `diff -u`,
	// or a single-file fragment — still has files in it, and counting zero
	// would report a change that touched nothing.
	if !seenHeader {
		files = bytes.Count(patch, []byte("\n+++ "))
		if bytes.HasPrefix(patch, []byte("+++ ")) {
			files++
		}
	}
	if files == 0 && added == 0 && removed == 0 {
		return ""
	}
	// The minus is U+2212, matching the interpuncts the cards already use: a
	// hyphen here sits directly under a diff full of them and reads as one.
	return fmt.Sprintf("%s · +%d −%d", countLabel(files, "file"), added, removed)
}

func countLabel(count int, noun string) string {
	if count == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", count, noun)
}
