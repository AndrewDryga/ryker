package webui

import (
	"context"
	"html/template"
	"net/url"
	"strings"
	"testing"
	"time"
)

// Recall spends prompt budget on a different, finished incident, and the only
// defence an operator has against a bad match is reading the episode it came
// from. Before this the runtime table printed the stored ref — "episode:ep_…" —
// with no link and no role, so judging the match meant copying an id out of a
// table cell and searching for it.
func TestARecalledEpisodeLinksToItsOwnTrace(t *testing.T) {
	// An id that has to be escaped. Real episode ids never contain a slash, and
	// a row that silently builds a broken URL out of one is not something a
	// test written after the fact would catch.
	const episodeID = "ep/01K2 QF"
	runtime, replay := contextReferenceDetails([]ContextRef{
		{Kind: "similar_past_episode", What: "Zot returned 500s after an image push",
			Visibility: "eligible", Episode: episodeID},
	}, func(value string) string { return value }, nil)

	if len(replay) != 0 || len(runtime) != 1 || runtime[0].Table == nil ||
		len(runtime[0].Table.Rows) != 1 {
		t.Fatalf("context details = %+v / %+v, want one runtime row", runtime, replay)
	}
	row := runtime[0].Table.Rows[0]
	if want := template.URL("/episodes/" + url.PathEscape(episodeID)); row.Href != want {
		t.Fatalf("recalled episode href = %q, want %q", row.Href, want)
	}
	if row.Cells[0] != "Recalled past episode" ||
		row.Cells[1] != "Zot returned 500s after an image push" {
		t.Fatalf("recalled episode row = %+v, want the label and what it concluded", row.Cells)
	}
	// The role is the whole point of the row: a section headed "root cause"
	// beside live evidence invites skipping the checking, which is the product.
	for _, want := range []string{"History", "symptom overlap", "not evidence of current health", "not authorization"} {
		if !strings.Contains(row.Cells[3], want) {
			t.Fatalf("recalled episode role = %q, want it to carry %q", row.Cells[3], want)
		}
	}
}

// The manifest stores "episode:<id>" and nothing else, so every word the page
// says about a recalled episode has to come back out of the corpus. All three
// states have to read as something: the corpus has the row, the corpus has a
// row that never verified anything, and retention has already pruned it while
// the manifest reference that cites it is kept.
func TestARecalledEpisodeIsNamedByWhatItConcludedNotItsID(t *testing.T) {
	reader := recalledEpisodeFixture(t)
	defer reader.Close()

	manifests, err := reader.Manifests(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) != 1 {
		t.Fatalf("manifests = %+v, want the one seeded attempt", manifests)
	}
	named := map[string]string{}
	for _, ref := range manifests[0].Refs {
		if ref.Kind == "similar_past_episode" {
			named[ref.Episode] = ref.What
		}
	}
	for episode, want := range map[string]string{
		"episode-past":    "Zot registry returned 500s after an image push",
		"episode-blocked": "Checkout pool exhausted and could not be restarted (blocked, not verified)",
		// Pruned outcome, surviving reference. The id is the only honest answer
		// left, and an error or an empty cell would read as a page fault.
		"episode-pruned": "episode episode-pruned",
	} {
		if named[episode] != want {
			t.Fatalf("recalled %s named %q, want %q", episode, named[episode], want)
		}
	}
	for _, ref := range manifests[0].Refs {
		if strings.Contains(ref.What, "episode:") {
			t.Fatalf("recalled episode echoed its stored ref: %q", ref.What)
		}
	}
}

// The link and the role have to survive the whole render, not just the row
// builder: the runtime table is assembled in one place and rendered in another,
// and a row whose Href is set on a cell the template does not link is a row
// nobody can click.
func TestTheTracePageLinksEveryRecalledEpisodeItNames(t *testing.T) {
	reader := recalledEpisodeFixture(t)
	defer reader.Close()

	body := servePage(t, reader, "/episodes/episode-1")
	for _, want := range []string{
		`href="/episodes/episode-past"`,
		`href="/episodes/episode-blocked"`,
		`href="/episodes/episode-pruned"`,
		"Recalled past episode",
		"Zot registry returned 500s after an image push",
		"History the host recalled by symptom overlap",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("episode page missing %q", want)
		}
	}
	if strings.Contains(body, "episode:episode-past") {
		t.Fatal("episode page printed the stored manifest ref instead of the episode")
	}
}

// A recalled layer is not operational memory and must not be filed as it: it is
// the only context on the page about an incident that is already over, and it
// is the first thing the budget drops. Both facts are invisible if the layer
// lands in the page's leftover bucket for context nobody classified.
func TestRecalledEpisodesRenderAsTheirOwnPromptLayer(t *testing.T) {
	prompt := recallPrompt(`"similar_past_episodes":[
	  {"episode_id":"episode-past","past_root_cause":"The registry pod was OOM killed.","matched_on":["same alert group"]},
	  {"episode_id":"episode-blocked","past_root_cause":"The pool was exhausted.","matched_on":["shared service checkout"]}
	],`)
	details, layers := promptContextDetails(prompt, func(value string) string { return value }, nil, "incident_investigation")

	var recalled *TraceDetail
	for index, detail := range details {
		if detail.Label == "Recalled past episodes" {
			recalled = &details[index]
		}
		if detail.Group == "Other submitted context" && strings.Contains(detail.Body, "episode-past") {
			t.Fatalf("recalled episodes fell into the unclassified bucket: %+v", detail)
		}
	}
	if recalled == nil {
		t.Fatalf("no recalled-episode layer in %+v", details)
	}
	if recalled.Group != "Recalled past episodes" || recalled.Count != 2 {
		t.Fatalf("recalled layer = %+v, want its own group and both episodes counted", *recalled)
	}
	if !strings.Contains(recalled.Description, "never proves current state") {
		t.Fatalf("recalled layer selection note = %q, want it to refuse the evidence reading", recalled.Description)
	}
	if !strings.Contains(recalled.Body, "The registry pod was OOM killed.") {
		t.Fatalf("recalled layer body = %q, want the recalled cause the model actually read", recalled.Body)
	}
	// Four memory layers were offered and four have to be counted, or the
	// briefing card's summary undercounts what the model was given.
	if layers != 4 {
		t.Fatalf("memory layers = %d, want operational, conversation, related, and recalled", layers)
	}
	// The colour strip under the final prompt names each envelope field from
	// the same table. An unnamed field is titled from its raw JSON key and
	// coloured as Slack content, which is the one thing this layer is not.
	labelled := false
	for _, segment := range promptSegments(prompt) {
		if segment.Source == "Recalled past episodes" && segment.Tone == recalled.Tone {
			labelled = true
		}
	}
	if !labelled || recalled.Tone != "operational" {
		t.Fatalf("recalled layer tone = %q and prompt strip labelled = %v, want a named memory-toned segment",
			recalled.Tone, labelled)
	}
}

// Absent and cut are different answers, and the page has told this lie before:
// a layer the budget removed must never render as "nothing matched", because
// that sends an operator looking for a corpus gap that does not exist.
func TestADroppedRecallLayerIsNeverShownAsNothingMatched(t *testing.T) {
	const dropped = "recalled outcomes of similar past episodes were omitted to fit the turn"
	prompt := recallPrompt("")
	present := func(value string) string { return value }

	cut, _ := promptContextDetails(prompt, present, map[string][]string{
		"similar_past_episodes": {dropped},
	}, "operational_assessment")
	joined := ""
	for _, detail := range cut {
		joined += detail.Label + " · " + detail.Status + " · " + detail.Description + "\n"
	}
	if !strings.Contains(joined, "Recalled past episodes · Trimmed · "+dropped) {
		t.Fatalf("dropped recall layer rendered as:\n%s", joined)
	}
	if strings.Contains(joined, "No resolved past episode matched this symptom.") {
		t.Fatalf("a layer the budget cut claimed the corpus was empty:\n%s", joined)
	}

	quiet, _ := promptContextDetails(prompt, present, nil, "operational_assessment")
	empty := ""
	for _, detail := range quiet {
		empty += detail.Label + " · " + detail.Status + " · " + detail.Description + "\n"
	}
	if !strings.Contains(empty, "Recalled past episodes · Not sent · No resolved past episode matched this symptom.") {
		t.Fatalf("a turn that recalled nothing said:\n%s", empty)
	}
}

// The outcome row is the only part of this episode another episode can read,
// and it is written once inside the terminal transaction and never mentioned
// again. A row with an empty root cause degrades every future recall silently,
// so the page that explains this episode has to show what it actually stored.
func TestAFinishedEpisodeShowsTheRecallRowItLeftBehind(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	stamp := time.Date(2026, 8, 11, 12, 4, 0, 0, time.UTC).Format(time.RFC3339Nano)
	fixture.exec(`INSERT INTO episode_outcomes
	  (episode_id, workspace_id, channel_id, repository, mode, effort, terminal_state,
	   terminal_at, objective, symptom_fingerprint, fingerprint_source, alert_group_key,
	   services_json, root_cause, remediation, verification, verified,
	   time_to_decision_seconds, created_at)
	  VALUES ('episode-1','T1','C1','emisar','triage','operational_assessment','completed',
	          ?,'Check the rollout','image push registry rollout','trigger_text',
	          'alert-zot-5xx','["zot","registry"]','The registry pod was OOM killed after the image push.',
	          'emisar action restart_zot','Error rate returned to baseline for ten minutes.',
	          1,240,?)`, stamp, stamp)
	reader := fixture.reader()
	defer reader.Close()

	body := servePage(t, reader, "/episodes/episode-1")
	for _, want := range []string{
		"Recorded for future recall",
		"The registry pod was OOM killed after the image push.",
		"image push registry rollout",
		"emisar action restart_zot",
		"Error rate returned to baseline for ten minutes.",
		"Fingerprinted from",
		"the trigger message",
		"Time to decision",
		"4m 00s",
		"zot · registry",
		"alert-zot-5xx",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("episode page missing recall projection %q", want)
		}
	}
}

// fingerprint_source is the difference between a match on what the operator
// wrote and a match on a truncated display headline. Retention prunes Slack
// inputs long before outcome rows, so the weak sources are the common case, and
// a page that shows the fingerprint without its provenance invites an operator
// to conclude the corpus is broken when it is only working from less.
func TestAFingerprintSaysWhichSourceItCouldSettleFor(t *testing.T) {
	for _, testCase := range []struct {
		source, wantStat, wantNote string
	}{
		{"trigger_text", "the trigger message", "what the operator actually wrote"},
		{"trigger_control", "a Slack control", "no message text"},
		{"alert_labels", "alert labels", "came from a webhook"},
		{"objective", "the objective headline", "A weak fingerprint"},
		{"", "an unrecorded source", "does not name where its fingerprint came from"},
	} {
		step := recallProjectionStep(OutcomeRow{
			EpisodeID: "episode-1", TerminalState: "completed",
			SymptomFingerprint: "pool exhausted checkout", FingerprintSource: testCase.source,
		}, func(value string) string { return value })
		stat := ""
		for _, item := range step.Stats {
			if item.Label == "Fingerprinted from" {
				stat = item.Value
			}
		}
		if stat != testCase.wantStat {
			t.Fatalf("%q fingerprint stat = %q, want %q", testCase.source, stat, testCase.wantStat)
		}
		if len(step.Details) == 0 || !strings.Contains(step.Details[0].Description, testCase.wantNote) {
			t.Fatalf("%q fingerprint note = %+v, want it to carry %q",
				testCase.source, step.Details, testCase.wantNote)
		}
	}
}

// Recall accepts blocked episodes on purpose — an episode that hit an external
// blocker still diagnosed something real — and ranks them below completed ones.
// The page has to draw the same line the scorer does, or "we fixed this in
// July" gets said about an episode that gave up in July.
func TestABlockedOutcomeIsNeverShownAsAVerifiedFix(t *testing.T) {
	step := recallProjectionStep(OutcomeRow{
		EpisodeID: "episode-1", TerminalState: "blocked",
		RootCause: "The pool was exhausted and could not be restarted.",
	}, func(value string) string { return value })

	if step.Tone != "warn" {
		t.Fatalf("blocked projection tone = %q, want it marked as the weaker source", step.Tone)
	}
	verified := ""
	for _, stat := range step.Stats {
		if stat.Label == "Remediation verified" {
			verified = stat.Value
		}
	}
	if !strings.HasPrefix(verified, "no") || !strings.Contains(verified, "no verification step") {
		t.Fatalf("blocked projection verified = %q, want an explicit unverified reading", verified)
	}
	absent := map[string]string{}
	for _, detail := range step.Details {
		if detail.Inert {
			absent[detail.Label] = detail.Description
		}
	}
	if !strings.Contains(absent["Remediation"], "No remediation was recorded") ||
		!strings.Contains(absent["Verification"], "No verification step was recorded") {
		t.Fatalf("blocked projection absences = %+v, want each empty field to say so", absent)
	}
}

// A group header that says "1 item" over a single row reading "Not sent" is
// counting its own placeholder. episode_run_225513b54c5e8c2c8478869e3f17596f
// rendered exactly that for both recall groups on the first day the layers
// shipped: the count is a claim that content was sent, and an inert row is the
// absence of content.
func TestAGroupOfNothingAdvertisesNoItemCount(t *testing.T) {
	details, _ := promptContextDetails(recallPrompt(""),
		func(value string) string { return value }, nil, "operational_assessment")

	counts := map[string]int{}
	for _, detail := range details {
		if detail.Group != "" {
			counts[detail.Group] = detail.GroupCount
		}
	}
	for _, quiet := range []string{"Recalled past episodes", "Recent changes"} {
		if _, marked := counts[quiet]; !marked {
			t.Fatalf("no %q group in %+v", quiet, counts)
		}
		if counts[quiet] != 0 {
			t.Fatalf("%q holds only an inert placeholder yet advertises %d items", quiet, counts[quiet])
		}
	}
	// The rule must not silence groups that carry content, or every header
	// loses its count and the change reads as a regression.
	if counts["Operational memory"] == 0 {
		t.Fatalf("operational memory sent content yet counts 0 items in %+v", counts)
	}
}

// "No resolved past episode matched this symptom" claims a search that, on a
// conversational or engineering turn, never ran: recall and the change ledger
// are gated to assessments and investigations (changeledger.RecalledBy, and the
// same pair in the service's similarPastEpisodes). The first conversational
// trace to render the layers claimed a recall miss, which sends an operator
// hunting for a corpus gap that does not exist.
func TestALaneWithoutRecallNeverClaimsNothingMatched(t *testing.T) {
	notes := func(effort string) map[string]string {
		details, _ := promptContextDetails(recallPrompt(""),
			func(value string) string { return value }, nil, effort)
		byLabel := map[string]string{}
		for _, detail := range details {
			byLabel[detail.Label] = detail.Description
		}
		return byLabel
	}

	for _, lane := range []string{"conversational", "focused_check", "engineering_task"} {
		byLabel := notes(lane)
		if !strings.Contains(byLabel["Recalled past episodes"], "the corpus was not searched") {
			t.Fatalf("%s recall note = %q, want it to say the search never ran",
				lane, byLabel["Recalled past episodes"])
		}
		if !strings.Contains(byLabel["Recent changes"], "no correlation was attempted") {
			t.Fatalf("%s change note = %q, want it to say the ledger was never read",
				lane, byLabel["Recent changes"])
		}
	}
	// The lanes that do recall keep the miss reading: there, quiet genuinely
	// means the search ran and found nothing.
	for _, lane := range []string{"operational_assessment", "incident_investigation", ""} {
		byLabel := notes(lane)
		if byLabel["Recalled past episodes"] != "No resolved past episode matched this symptom." {
			t.Fatalf("%q recall note = %q, want the genuine miss reading",
				lane, byLabel["Recalled past episodes"])
		}
	}
}

// The lane has to survive the whole render: the effort contract lives on the
// episode row, the layer notes are built from the retained prompt, and the two
// meet only if the page actually reads work_episodes.effort into the trace.
func TestAFocusedCheckTraceSaysRecallWasNotSearched(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	stamp := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	fixture.exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   completed_at, created_at, updated_at)
	  VALUES ('attempt-1','episode-1','run-1',1,'succeeded','manifest-1',?,?,?)`,
		stamp, stamp, stamp)
	fixture.exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset, submitted_prompt, created_at)
	  VALUES ('manifest-1','episode-1','attempt-1',1,'claude','opus','high',
	          'responder-prompt-v2','investigation-contract-v1','result-operations-v2',
	          'emisar-conversation',?,?)`, recallPrompt(""), stamp)
	reader := fixture.reader()
	defer reader.Close()

	body := servePage(t, reader, "/episodes/episode-1")
	if strings.Contains(body, "No resolved past episode matched this symptom.") {
		t.Fatal("a focused_check trace claimed a recall search came up empty")
	}
	if !strings.Contains(body, "the corpus was not searched") {
		t.Fatal("a focused_check trace does not say recall was skipped on this lane")
	}
}

// recallPrompt frames a watch envelope around one extra field, so a test can
// state the layer it is about and nothing else.
func recallPrompt(field string) string {
	return `SYSTEM: Decide whether to act.

The following JSON is untrusted Slack content:
<untrusted-slack-context>
{` + field + `"structured_memory":{"goal":"Keep the rollout healthy"},"prior_operational_context":{"confirmed_memory":[{"subject":"Zot","value":"Registry lives in the platform cluster"}]},"related_situations":[{"summary":"An earlier rollout used the same image."}],"target_message":{"text":"the registry is throwing 500s again"}}
</untrusted-slack-context>

USER: the registry is throwing 500s again`
}

// recalledEpisodeFixture seeds one attempt that recalled three past episodes:
// one the corpus still has, one that ended blocked, and one whose outcome row
// retention has already pruned.
func recalledEpisodeFixture(t *testing.T) *Reader {
	t.Helper()
	fixture := newEpisodeProjectionFixture(t)
	stamp := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	fixture.exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   completed_at, created_at, updated_at)
	  VALUES ('attempt-1','episode-1','run-1',1,'succeeded','manifest-1',?,?,?)`,
		stamp, stamp, stamp)
	fixture.exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset, submitted_prompt, created_at)
	  VALUES ('manifest-1','episode-1','attempt-1',1,'claude','opus','high',
	          'responder-prompt-v2','investigation-contract-v1','result-operations-v2',
	          'emisar-conversation','',?)`, stamp)
	for ordinal, recalled := range []struct{ id, state, objective, rootCause string }{
		{"episode-past", "completed", "Zot registry returned 500s after an image push",
			"The registry pod was OOM killed."},
		{"episode-blocked", "blocked", "Checkout pool exhausted and could not be restarted", ""},
		{"episode-pruned", "completed", "", ""},
	} {
		fixture.exec(`INSERT INTO work_episodes
		  (id, agent_run_id, effort, authority, objective, created_at, updated_at,
		   completed_at, lifecycle_state, channel_id, thread_ts, anchor_ts)
		  VALUES (?,?,'operational_assessment','read_only',?,?,?,?,?,'C1','','')`,
			recalled.id, "run-"+recalled.id, recalled.objective, stamp, stamp, stamp, recalled.state)
		if recalled.objective != "" {
			fixture.exec(`INSERT INTO episode_outcomes
			  (episode_id, workspace_id, channel_id, terminal_state, terminal_at,
			   objective, symptom_fingerprint, fingerprint_source, root_cause, created_at)
			  VALUES (?,'T1','C1',?,?,?,'registry 500s image push','trigger_text',?,?)`,
				recalled.id, recalled.state, stamp, recalled.objective, recalled.rootCause, stamp)
		}
		fixture.exec(`INSERT INTO context_manifest_refs
		  (id, manifest_id, kind, source_ref, visibility, content_digest, ordinal, metadata_json)
		  VALUES (?,'manifest-1','similar_past_episode',?,'eligible',?,?,?)`,
			"ref-"+recalled.id, "episode:"+recalled.id, "digest-"+recalled.id, ordinal+1,
			`{"terminal_state":"`+recalled.state+`"}`)
	}
	return fixture.reader()
}
