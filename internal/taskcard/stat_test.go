package taskcard

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
)

// A patch with everything awkward in it: an ordinary edit, a rename that
// changes nothing, a deletion, a new file, and a binary blob. The shapes are
// git's own, because the patch is git's output and a fixture that invented its
// own header would pass while the real thing counted wrong.
const mixedPatch = `diff --git a/terraform/apps_cms.tf b/terraform/apps_cms.tf
index 1a2b3c4..5d6e7f8 100644
--- a/terraform/apps_cms.tf
+++ b/terraform/apps_cms.tf
@@ -12,7 +12,8 @@ resource "nomad_job" "cms" {
   memory = 4096
-  replicas = 3
+  memory = 8192
+  replicas = 5
 }
diff --git a/docs/old-runbook.md b/docs/runbook.md
similarity index 100%
rename from docs/old-runbook.md
rename to docs/runbook.md
diff --git a/scripts/legacy.sh b/scripts/legacy.sh
deleted file mode 100755
index 9f8e7d6..0000000
--- a/scripts/legacy.sh
+++ /dev/null
@@ -1,3 +0,0 @@
-#!/bin/sh
-echo "retired"
-exit 0
diff --git a/alerts/rss.yaml b/alerts/rss.yaml
new file mode 100644
index 0000000..3c4d5e6
--- /dev/null
+++ b/alerts/rss.yaml
@@ -0,0 +1,2 @@
+alert: TraefikRSS
+expr: process_resident_memory_bytes > 8e9
diff --git a/assets/logo.png b/assets/logo.png
index 7a8b9c0..1d2e3f4 100644
Binary files a/assets/logo.png and b/assets/logo.png differ
`

// The stat is a count of the patch, not a count of the page it arrived in.
func TestPatchStatCountsFilesAndLines(t *testing.T) {
	for name, testCase := range map[string]struct {
		patch string
		want  string
	}{
		// Five headers: edit, rename, delete, add, binary. Additions are the
		// two rewritten lines plus the two in the new file; removals are the
		// one replaced line plus the three from the deleted script. The rename
		// and the binary contribute a file each and no lines, which is the
		// whole reason both are in the fixture.
		"every shape git emits": {patch: mixedPatch, want: "5 files · +4 −4"},
		"one file": {patch: `diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -1,2 +1,2 @@
-old
+new
`, want: "1 file · +1 −1"},
		// A rename with no edits is a real change to report and has no hunk at
		// all, which is why files are counted from the header rather than from
		// the +++ lines a hunk would have carried.
		"rename only": {patch: `diff --git a/old.md b/new.md
similarity index 100%
rename from old.md
rename to new.md
`, want: "1 file · +0 −0"},
		// A binary file changed. One file touched, nothing to add up — and the
		// "Binary files ... differ" line must not be counted as content.
		"binary only": {patch: `diff --git a/logo.png b/logo.png
index 7a8b9c0..1d2e3f4 100644
Binary files a/logo.png and b/logo.png differ
`, want: "1 file · +0 −0"},
		// A fragment from a producer that writes no `diff --git` header still
		// touched a file, and reporting zero would deny a change that happened.
		"headerless fragment": {patch: `--- a/a.go
+++ b/a.go
@@ -1 +1 @@
-old
+new
`, want: "1 file · +1 −1"},
		"nothing at all": {patch: "", want: ""},
	} {
		t.Run(name, func(t *testing.T) {
			if got := PatchStat([]byte(testCase.patch)); got != testCase.want {
				t.Fatalf("PatchStat = %q, want %q", got, testCase.want)
			}
		})
	}
}

// The stat is omitted rather than guessed whenever the fetch did not hold the
// whole patch. "3 files" taken from the first seven kilobytes of a sixty
// kilobyte diff reads exactly like "3 files" taken from all of it.
func TestChangesStatRefusesToCountAPage(t *testing.T) {
	whole := coop.Changes{Patch: []byte(mixedPatch), PatchBytes: int64(len(mixedPatch))}
	if got := ChangesStat(whole); got != "5 files · +4 −4" {
		t.Fatalf("a whole patch counted %q", got)
	}
	for name, changes := range map[string]coop.Changes{
		"more pages follow":     {Patch: []byte(mixedPatch), PatchHasMore: true},
		"starts mid-patch":      {Patch: []byte(mixedPatch), PatchOffset: 7000},
		"Coop cut it short":     {Patch: []byte(mixedPatch), Truncated: true},
		"no patch was returned": {},
	} {
		t.Run(name, func(t *testing.T) {
			if got := ChangesStat(changes); got != "" {
				t.Fatalf("ChangesStat counted a partial patch as %q", got)
			}
		})
	}
}
