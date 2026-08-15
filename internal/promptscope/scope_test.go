package promptscope

import "testing"

// The clause detector is the only predicate here with real logic, and it is the
// one a later edit will break: adding a verb to requestOpeners is a one-line
// change that can turn every ordinary question compound, and removing one
// silently stops a genuine multi-instruction ask from being told to handle every
// clause. Both failures are invisible in a diff.
//
// Every string below is a real target message from testdata/eval — the prompt,
// golden, proactive and episode-replay corpora — chosen for a shape rather than
// invented to pass. The two false positives at the bottom are recorded as
// accepted, not as bugs: the predicate is biased toward inclusion, so paying
// 1,543 bytes on a pasted monitor card is the side of the trade that costs
// nothing but bytes.
func TestCompoundRequestCountsInstructionsNotWords(t *testing.T) {
	for _, testCase := range []struct {
		name       string
		senderType string
		text       string
		want       bool
	}{
		{"check and tell", "human",
			"Check whether the latest emisar terraform change applied and tell me what changed.", true},
		{"confirm and record", "human",
			"Confirm the current uptime of nomad-hst03 and record what you observed.", true},
		{"assess, use, give", "human",
			"Assess whether checkout recovered after the deployment. Use only the recorded " +
				"episode evidence and give a decision-ready result or the exact blocker.", true},
		{"extend, test, make sure", "human",
			"Also extend that runbook and test it; make sure it is all we need for daily checkups.", true},
		{"two questions and a constraint", "human",
			"Did the GitHub Actions restart finish, and was the earlier failure specifically " +
				"a Docker push networking timeout? Use configured sources before asking", true},
		{"do this but not that", "human",
			"Checkout is slow for several customers. Check what is currently verifiable, " +
				"but do not open an incident.", true},
		{"numbered corrections", "human",
			"<@U0BL8MNPUSY> feedback: 1. i told you to answer in thread; 2. i told you to " +
				"update channel memory/settings/rules", true},
		{"one question", "human",
			"What is the disk usage on nomad-hst03 right now?", false},
		{"one request behind a preamble", "human",
			"The retry backoff in the worker looks wrong to me — can you fix it?", false},
		{"one instruction", "human",
			"Open an incident for the recurring checkout 503 reports.", false},
		{"one instruction, no verb", "human",
			"Create reusable deep infrastructure health review runbook", false},
		{"one recurring instruction", "human",
			"Every morning, check production health for me.", false},
		{"one instruction with a time", "human",
			"Every Monday at 09:00 UTC, prepare an evidence-backed production health review " +
				"in this channel.", false},
		{"one instruction, two objects", "human",
			"Summarize the decision and the remaining evidence gap.", false},
		{"one correction with a caveat", "human",
			"Those four runner records are only two hosts; check infra/ before counting them " +
				"as four machines.", false},
		{"teammate chatter", "human",
			"Sounds good, I will deploy it after lunch.", false},
		{"question to another teammate", "human",
			"Alex, do you know whether the migration finished?", false},
		{"quoted question", "human",
			`Maya asked "is the deploy green?" and I told her yes.`, false},
		{"handoff notes in bullets", "human",
			"Session working notes, 34 turns.\n- #backend-ops asked why emisar checkout p99 " +
				"doubled after the 14:10 rollout.\n- The regression is real: p99 sat at 1.9s " +
				"from 14:12, against 0.9s across the preceding day.", false},
		// Decimals and versions must not read as list markers.
		{"alert with a decimal", "external_app",
			"[VA1 FIRING:1] WARNING | Cassandra repair overdue sts_ks last completed " +
				"5.625 days ago; expected every five days plus grace.", false},
		// Three lines that each open with the verb `Run`. Without the app check
		// this is the worst false positive in the corpus, and Terraform posts it
		// several times a day.
		{"terraform run notification", "external_app",
			"Run notification for SME-Tenant/tenant-infra\nRun run-UBwFpsiiVMtXwtbi\n" +
				"Run Planned - Needs Confirmation", false},
		{"deployment notification", "external_app",
			"Deployment production/portal completed successfully. All rollout checks passed.", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := CompoundRequest(testCase.senderType, testCase.text); got != testCase.want {
				t.Errorf("CompoundRequest = %t, want %t", got, testCase.want)
			}
		})
	}
}

// The visual vocabulary has to survive an operations channel, where `image`
// means a container and `graph` is part of GraphQL. The tokenizer splits on
// everything that is not a letter or a digit, so a compound identifier stays
// whole and only the bare word matches.
func TestVisualRequestReadsTheAskNotTheInfrastructure(t *testing.T) {
	for _, testCase := range []struct {
		text string
		want bool
	}{
		{"Chart the checkout p99 for the last hour.", true},
		{"Can you make a graph of the error rate since the rollout?", true},
		{"post a meme, we survived the migration", true},
		{"drop a screenshot of the dashboard in here", true},
		{"send me the charts from last week", true},
		{"What is the disk usage on nomad-hst03 right now?", false},
		{"Is production infrastructure healthy right now?", false},
		{"Check whether the latest emisar terraform change applied.", false},
		{"the pod is in ImagePullBackOff on nomad-hst03", false},
		{"the GraphQL endpoint is timing out", false},
		{"Grafana says the reaper schedule is unfulfilled", false},
		{"", false},
	} {
		t.Run(testCase.text, func(t *testing.T) {
			if got := VisualRequest(testCase.text); got != testCase.want {
				t.Errorf("VisualRequest = %t, want %t", got, testCase.want)
			}
		})
	}
}
