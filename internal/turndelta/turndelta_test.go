package turndelta_test

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/turndelta"
)

// eligible is the one shape that earns a delta: a live open session, the run
// still bound to it at the same generation, its cursor sitting exactly where the
// standing briefing's turn ended, and nothing about the contract changed.
//
// Every case below is this value with one field spoiled, which is the point —
// the test is not "does Decide work" but "which single fact is enough to make
// the host restate 146 KB it does not need to". A reader adding a clause to
// Decide should be able to add one line here and see it fail.
func eligible() (turndelta.Session, turndelta.Attempt, turndelta.Standing, turndelta.Contract) {
	contract := turndelta.Contract{
		Prompt:        "ryker-prompt-v3",
		Investigation: "investigation-contract-v1",
		ToolSchema:    "result-operations-v2",
	}
	return turndelta.Session{
			ID: "sess_live", State: "open", Preset: "watch", Generation: 4, Cursor: 918,
		},
		turndelta.Attempt{
			SessionID: "sess_live", SessionGeneration: 4, Cursor: 918,
		},
		turndelta.Standing{
			ManifestID: "manifest_prev", Preset: "watch",
			Contract: contract, Delivered: true,
		},
		contract
}

func TestAFollowUpIntoTheSessionHoldingItsBriefingSendsADelta(t *testing.T) {
	session, attempt, standing, contract := eligible()
	decision := turndelta.Decide(session, attempt, standing, contract)
	if !decision.Delta {
		t.Fatalf("a live session at the previous terminal was made to restate its briefing: %s",
			decision.Reason)
	}
	if decision.ParentManifestID != "manifest_prev" {
		t.Fatalf(
			"the delta must name the briefing it leans on so the manifest can record delta_of; got %q",
			decision.ParentManifestID,
		)
	}
	if decision.Reason != turndelta.ReasonStandingBriefingHeld {
		t.Fatalf("reason = %q", decision.Reason)
	}
}

// Each row is a doubt. The rule the whole feature rests on is that a doubt costs
// nothing but bytes: the fallback is what the host did before this package
// existed, so a wrong "full" is invisible and a wrong "delta" loses the model
// its instructions mid-episode.
func TestEveryDoubtFallsBackToTheFullBriefing(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		spoil  func(*turndelta.Session, *turndelta.Attempt, *turndelta.Standing, *turndelta.Contract)
		reason string
	}{{
		name: "the channel rotated to a new session",
		spoil: func(s *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.ID = "sess_rotated"
		},
		reason: turndelta.ReasonRotatedSession,
	}, {
		name: "the session generation advanced under the run",
		spoil: func(s *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.Generation = 5
		},
		reason: turndelta.ReasonRotatedSession,
	}, {
		name: "the episode was handed to a run that has never spoken",
		spoil: func(_ *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			a.SessionID, a.Cursor = "", 0
		},
		reason: turndelta.ReasonRotatedSession,
	}, {
		name: "the session is exhausted rather than open",
		spoil: func(s *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.State = "exhausted"
		},
		reason: turndelta.ReasonSessionNotOpen,
	}, {
		name: "something else spoke in the session since the briefing",
		spoil: func(s *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.Cursor = 931
		},
		reason: turndelta.ReasonCursorMoved,
	}, {
		name: "the run never reached Coop, so its cursor never moved",
		spoil: func(s *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.Cursor, a.Cursor = 0, 0
		},
		reason: turndelta.ReasonCursorMoved,
	}, {
		name: "the previous turn is still running",
		spoil: func(_ *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			a.TurnID = "turn_live"
		},
		reason: turndelta.ReasonTurnInFlight,
	}, {
		name: "this attempt already froze the prompt it must submit",
		spoil: func(_ *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			a.FrozenManifestID = "manifest_frozen"
		},
		reason: turndelta.ReasonAttemptAlreadyFrozen,
	}, {
		name: "the attempt replays deliberately in a fresh session",
		spoil: func(_ *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			a.Replay = true
		},
		reason: turndelta.ReasonFreshSessionReplay,
	}, {
		name: "a session handoff opens its own session",
		spoil: func(_ *turndelta.Session, a *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			a.Handoff = true
		},
		reason: turndelta.ReasonSessionHandoff,
	}, {
		name: "no briefing was ever delivered for this episode",
		spoil: func(_ *turndelta.Session, _ *turndelta.Attempt, st *turndelta.Standing, _ *turndelta.Contract) {
			st.ManifestID = ""
		},
		reason: turndelta.ReasonNoStandingBriefing,
	}, {
		// The manifest is frozen BEFORE the submit it describes, so a manifest
		// that exists is a prompt the host meant to send and may never have.
		name: "the previous manifest was frozen but its turn never ran",
		spoil: func(_ *turndelta.Session, _ *turndelta.Attempt, st *turndelta.Standing, _ *turndelta.Contract) {
			st.Delivered = false
		},
		reason: turndelta.ReasonNoStandingBriefing,
	}, {
		name: "the result contract changed mid-episode",
		spoil: func(_ *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, c *turndelta.Contract) {
			c.ToolSchema = "result-operations-v3"
		},
		reason: turndelta.ReasonContractChanged,
	}, {
		name: "the prompt version changed mid-episode",
		spoil: func(_ *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, c *turndelta.Contract) {
			c.Prompt = "ryker-prompt-v4"
		},
		reason: turndelta.ReasonContractChanged,
	}, {
		name: "the investigation contract changed mid-episode",
		spoil: func(_ *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, c *turndelta.Contract) {
			c.Investigation = "investigation-contract-v2"
		},
		reason: turndelta.ReasonContractChanged,
	}, {
		name: "the session policy changed mid-episode",
		spoil: func(s *turndelta.Session, _ *turndelta.Attempt, _ *turndelta.Standing, _ *turndelta.Contract) {
			s.Preset = "watch-operator"
		},
		reason: turndelta.ReasonPresetChanged,
	}} {
		t.Run(testCase.name, func(t *testing.T) {
			session, attempt, standing, contract := eligible()
			testCase.spoil(&session, &attempt, &standing, &contract)
			decision := turndelta.Decide(session, attempt, standing, contract)
			if decision.Delta {
				t.Fatalf(
					"a delta turn was sent into a session that may not hold the briefing (%s)",
					testCase.name,
				)
			}
			if decision.Reason != testCase.reason {
				t.Fatalf("reason = %q, want %q", decision.Reason, testCase.reason)
			}
			if decision.ParentManifestID != "" {
				t.Fatalf(
					"a full briefing must not claim a delta parent; got %q",
					decision.ParentManifestID,
				)
			}
		})
	}
}

// A mid-episode policy change is the one doubt the host cannot see in the
// session at all: Coop reports an open session at the right cursor, and the only
// thing that moved is what the host itself would now say. Left unchecked, the
// model keeps answering to a contract that has been retired.
func TestAStandingBriefingGoesStaleWhenThePromptContractMoves(t *testing.T) {
	session, attempt, standing, contract := eligible()
	standing.Contract.ToolSchema = "result-operations-v1"
	if decision := turndelta.Decide(session, attempt, standing, contract); decision.Delta {
		t.Fatal("a session holding a retired result contract was told it was current")
	}
}

func TestADeltaTurnSaysTheStandingBriefingStillApplies(t *testing.T) {
	prompt := turndelta.Prompt(turndelta.Sections{
		Input:   "<host-new-input>\nrestart the exporter now\n</host-new-input>",
		Episode: []string{"<episode-continuity>\n{}\n</episode-continuity>"},
		Host:    "<host-decision-correction>\nname the evidence\n</host-decision-correction>",
	})
	for _, required := range []string{
		"still applies in full and is deliberately not repeated",
		"structured result envelope that briefing specified",
		"restart the exporter now",
		"<episode-continuity>",
		"<host-decision-correction>",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("the delta turn lacks %q:\n%s", required, prompt)
		}
	}
	// The saving is the whole point of the change, so it is asserted rather
	// than assumed: a delta that grew back into a briefing is a regression the
	// byte count catches and no behavioural assertion would.
	if len(prompt) > 2<<10 {
		t.Fatalf("a delta turn grew to %d bytes; it replaces a ~146 KB briefing", len(prompt))
	}
}

// An empty section must vanish rather than arrive as a bare tag. A model that
// receives "<episode-continuity></episode-continuity>" reads it as a section it
// failed to get, and asks for it.
func TestADeltaTurnOmitsSectionsItHasNothingToPutIn(t *testing.T) {
	prompt := turndelta.Prompt(turndelta.Sections{
		Input: "  ", Episode: []string{"", "   "}, Host: "\n",
	})
	if strings.Contains(prompt, "\n\n\n") || strings.TrimSpace(prompt) != prompt {
		t.Fatalf("empty sections left their separators behind:\n%q", prompt)
	}
}

// The whole evidence ledger rides every attempt of an episode, and on the 201
// eligible follow-ups measured on blitz it averaged 23,476 bytes against a
// 9,412-byte episode contract that was byte-identical on every single one. A
// section the standing briefing already carried word for word is a section the
// session is still holding, by exactly the argument that justifies the delta
// itself — so the ledger becomes the ledger's delta without the store having to
// answer a question it has no index for.
func TestADeltaDropsTheEpisodeSectionsTheBriefingAlreadyCarried(t *testing.T) {
	const contract = "<host-investigation-contract>\nobjective: why is checkout slow\n</host-investigation-contract>"
	const ledgerBefore = "<episode-continuity>\n{\"evidence\":[1]}\n</episode-continuity>"
	const ledgerNow = "<episode-continuity>\n{\"evidence\":[1,2]}\n</episode-continuity>"
	prompt := turndelta.Prompt(turndelta.Sections{
		Input:    "<host-new-input>\nand now?\n</host-new-input>",
		Contract: contract,
		Episode:  []string{ledgerBefore, ledgerNow},
		Standing: "a 146 KB briefing\n\n" + contract + "\n\n" + ledgerBefore,
	})
	if strings.Count(prompt, ledgerBefore) != 0 {
		t.Fatalf("the delta re-read a ledger the session already holds:\n%s", prompt)
	}
	if !strings.Contains(prompt, ledgerNow) {
		t.Fatalf("the delta dropped the ledger that CHANGED, which is the one "+
			"thing it exists to carry:\n%s", prompt)
	}
	// The contract is never deduped, even though it is byte-identical on every
	// measured follow-up. A correction turn is the model being told it missed
	// this contract, and TestEscalatedDeepWorkReceivesStructuredCorrection is
	// the production behaviour that says so.
	if !strings.Contains(prompt, contract) {
		t.Fatalf("the delta dropped the contract the correction holds it to:\n%s", prompt)
	}
}

// The input and the correction are never dropped as duplicates. A correction is
// the model being told it failed to satisfy something, and the case where it
// fires twice with the same words is precisely the case where saying it once
// was not enough.
func TestADeltaRepeatsTheInputAndCorrectionEvenWhenTheBriefingHadThem(t *testing.T) {
	const input = "<host-new-input>\nwhy is checkout slow\n</host-new-input>"
	const correction = "<host-decision-correction>\nname the evidence\n</host-decision-correction>"
	prompt := turndelta.Prompt(turndelta.Sections{
		Input: input, Host: correction,
		Standing: input + "\n\n" + correction,
	})
	if !strings.Contains(prompt, input) || !strings.Contains(prompt, correction) {
		t.Fatalf("a delta dropped the message it answers or the correction it "+
			"carries because the briefing happened to contain them:\n%s", prompt)
	}
}

// A retry delivered on a higher rung than the standing briefing is briefed
// again, because the model that read that briefing is not the model answering.
//
// A repeated correction escalates the retry up the session policy's ladder, and
// a ladder step is a DIFFERENT model: on blitz on 2026-08-16 the second
// `unreadable` correction moved an attempt from gpt-5.6-terra to Claude Opus,
// and the retry went out as a delta on the premise that "the standing briefing
// is already in this session". It was — the previous rung had read it. The new
// model had never seen the result contract, and its first two answers were
// `unknown field "completion_contract"` and `unknown field "record_evidence"`:
// two envelope rounds, about $0.85 and four minutes, spent learning a schema
// the host could have restated. It only answered correctly once a new attempt
// handed it the full 136 KB briefing.
//
// Equal floors stay a delta. Every ordinary retry of an escalated run submits
// at the rung it already escalated to, and re-briefing those would give back
// the saving for a model that has read the briefing.
func TestEscalatedRetryIsBriefedInFull(t *testing.T) {
	session, attempt, standing, contract := eligible()
	attempt.TargetFloor, standing.TargetFloor = 1, 0
	decision := turndelta.Decide(session, attempt, standing, contract)
	if decision.Delta {
		t.Fatal("a retry that moved up the ladder leaned on a briefing the model " +
			"answering it has never read")
	}
	if decision.Reason != turndelta.ReasonRungEscalated {
		t.Fatalf("reason = %q, want %q", decision.Reason, turndelta.ReasonRungEscalated)
	}
	if decision.ParentManifestID != "" {
		t.Fatalf("a full briefing must not claim a delta parent; got %q",
			decision.ParentManifestID)
	}

	attempt.TargetFloor, standing.TargetFloor = 1, 1
	if decision := turndelta.Decide(session, attempt, standing, contract); !decision.Delta {
		t.Fatalf("a retry on the rung its briefing was submitted at restated it: %s",
			decision.Reason)
	}
}
