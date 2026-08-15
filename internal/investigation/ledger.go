package investigation

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type ClaimState string

const (
	ClaimSupported     ClaimState = "supported"
	ClaimContradicted  ClaimState = "contradicted"
	ClaimMixed         ClaimState = "mixed"
	ClaimUnknown       ClaimState = "unknown"
	ClaimNotApplicable ClaimState = "not_applicable"
)

type ClaimView struct {
	Requirement       ClaimRequirement `json:"requirement"`
	State             ClaimState       `json:"state"`
	Confidence        string           `json:"confidence,omitempty"`
	Evidence          []core.Evidence  `json:"evidence,omitempty"`
	Contradictions    []core.Evidence  `json:"contradictions,omitempty"`
	StaleEvidence     []core.Evidence  `json:"stale_evidence,omitempty"`
	MissingDimensions []string         `json:"missing_dimensions,omitempty"`
	Stale             bool             `json:"stale"`
	Resolved          bool             `json:"resolved"`
	CoverageStatus    string           `json:"coverage_status,omitempty"`
	Detail            string           `json:"detail,omitempty"`
}

type Ledger struct {
	Contract InvestigationContract `json:"contract"`
	Claims   map[string]ClaimView  `json:"claims"`
}

// BuildLedger indexes the recorded evidence against the contract's claims,
// judging freshness against the wall clock. This is the read-only form: what
// an operator reading a stored assessment wants to know is whether the
// evidence is fresh now.
func BuildLedger(
	contract InvestigationContract,
	evidence []core.Evidence,
	coverage []core.Coverage,
	now time.Time,
) Ledger {
	return BuildLedgerForChain(contract, evidence, coverage, now, time.Time{})
}

// BuildLedgerForChain is BuildLedger with contract freshness anchored to the
// moment the attempt chain began — the run's first transition into running,
// which a correction requeue never clears. Evidence that was fresh when the
// model took it stays fresh for every correction round of the same chain. A
// zero chain start falls back to the wall clock.
//
// The correction loop may not be the thing that expires the evidence it is
// waiting on. tenant run_3a615b9db spent four of its nineteen rounds on
// "required claims do not have fresh supporting evidence": the chain started
// at 03:21:49Z, the model read the cluster at 03:28:47Z, and the contradiction
// rounds burned enough wall clock that a ten-minute window had closed by round
// 19. The model watched its own readings expire and renamed the rows to match
// — the harvested evidence is literally `evidence-host-expired` and
// `evidence-workload-expired`, each observation explaining that the snapshot
// is "now outside the required ten-minute window". Two validators ping-ponged:
// fixing a contradiction aged the evidence, refreshing the evidence resurfaced
// the contradiction.
//
// Deliberately not a wider window, which was the considered and rejected
// alternative: a first try quoting an hour-old reading is genuinely stale and
// still hears so. Only the rounds of one chain share the chain's own clock.
//
// ValidUntil is left on the wall clock on purpose. Contract MaxAge is a host
// policy about how recent operational evidence must be, and the host is what
// spent the time; ValidUntil is the model's own assertion that a reading has a
// shelf life in the world, and honouring it late is correct.
func BuildLedgerForChain(
	contract InvestigationContract,
	evidence []core.Evidence,
	coverage []core.Coverage,
	now time.Time,
	chainStartedAt time.Time,
) Ledger {
	freshnessNow := now
	if !chainStartedAt.IsZero() && chainStartedAt.Before(now) {
		freshnessNow = chainStartedAt
	}
	ledger := Ledger{Contract: contract, Claims: make(map[string]ClaimView, len(contract.Claims))}
	byLayer := make(map[string]core.Coverage, len(coverage))
	for _, item := range coverage {
		current, ok := byLayer[item.Layer]
		if !ok || observationTime(item.ObservedAt, item.CreatedAt).After(
			observationTime(current.ObservedAt, current.CreatedAt),
		) {
			byLayer[item.Layer] = item
		}
	}
	latestEvidence := latestEvidenceObservationTimes(evidence)
	for _, requirement := range contract.Claims {
		view := ClaimView{Requirement: requirement, State: ClaimUnknown}
		coverageItem, covered := byLayer[requirement.Layer]
		if covered {
			view.CoverageStatus = coverageItem.Status
			view.Detail = coverageItem.Detail
		}
		if covered && coverageItem.Status == "not_applicable" {
			view.State = ClaimNotApplicable
		}
		for _, item := range evidence {
			resolved, resolvable := contract.ResolveClaimID(item.ClaimID)
			if (!resolvable || resolved != requirement.ID) &&
				!contains(coverageItem.ClaimIDs, item.ClaimID) {
				continue
			}
			stale := observationTime(item.ObservedAt, item.CreatedAt).Before(
				latestEvidence[evidenceObservationKey(item)],
			) || requirement.Freshness.MaxAge > 0 &&
				(item.ObservedAt.IsZero() ||
					freshnessNow.Sub(item.ObservedAt) > requirement.Freshness.MaxAge)
			stale = stale || (!item.ValidUntil.IsZero() && now.After(item.ValidUntil))
			if stale {
				view.StaleEvidence = append(view.StaleEvidence, item)
				continue
			}
			relation := strings.ToLower(strings.TrimSpace(item.Relation))
			if relation == "contradicts" || relation == "contradiction" {
				view.Contradictions = append(view.Contradictions, item)
			} else {
				view.Evidence = append(view.Evidence, item)
			}
		}
		view.Stale = len(view.StaleEvidence) > 0 &&
			len(view.Evidence) == 0 && len(view.Contradictions) == 0
		for _, dimension := range requirement.Dimensions {
			if !dimensionPresent(view.Evidence, dimension) && !dimensionPresent(view.Contradictions, dimension) {
				view.MissingDimensions = append(view.MissingDimensions, dimension)
			}
		}
		if view.State != ClaimNotApplicable {
			switch {
			case len(view.Evidence) > 0 && len(view.Contradictions) > 0:
				view.State = ClaimMixed
			case len(view.Contradictions) > 0:
				view.State = ClaimContradicted
			case len(view.Evidence) > 0:
				view.State = ClaimSupported
			}
		}
		view.Confidence = weakestConfidence(append(append([]core.Evidence{}, view.Evidence...), view.Contradictions...))
		view.Resolved = claimResolution(
			view, coverageItem, covered, contract.Completion,
		)
		ledger.Claims[requirement.ID] = view
	}
	return ledger
}

func latestEvidenceObservationTimes(items []core.Evidence) map[string]time.Time {
	latest := make(map[string]time.Time, len(items))
	for _, item := range items {
		key := evidenceObservationKey(item)
		observed := observationTime(item.ObservedAt, item.CreatedAt)
		if current, ok := latest[key]; !ok || observed.After(current) {
			latest[key] = observed
		}
	}
	return latest
}

func evidenceObservationKey(item core.Evidence) string {
	dimensionKeys := make([]string, 0, len(item.Dimensions))
	for key := range item.Dimensions {
		dimensionKeys = append(dimensionKeys, key)
	}
	sort.Strings(dimensionKeys)
	var dimensions strings.Builder
	for _, key := range dimensionKeys {
		dimensions.WriteString("|")
		dimensions.WriteString(key)
		dimensions.WriteString("=")
		dimensions.WriteString(item.Dimensions[key])
	}
	return strings.Join([]string{
		strings.TrimSpace(item.ClaimID),
		strings.TrimSpace(item.Target),
		strings.TrimSpace(item.SourceType),
		strings.TrimSpace(item.SourceID),
		strings.TrimSpace(item.SourceName),
		dimensions.String(),
	}, "\x00")
}

func observationTime(observedAt, createdAt time.Time) time.Time {
	if !observedAt.IsZero() {
		return observedAt
	}
	return createdAt
}

func (ledger Ledger) CompletionCorrection(status string) string {
	return ledger.CompletionCorrectionFor(status, "")
}

func (ledger Ledger) CompletionCorrectionFor(status, verdict string) string {
	if status == "blocked" {
		return ""
	}
	missing := make([]string, 0)
	contradicted := make([]string, 0)
	unresolved := make([]string, 0)
	for _, requirement := range ledger.Contract.Claims {
		if !requirement.Required {
			continue
		}
		view := ledger.Claims[requirement.ID]
		switch view.State {
		case ClaimSupported:
			if view.Stale || len(view.MissingDimensions) > 0 {
				detail := ""
				if view.Stale {
					detail = "stale"
				}
				if len(view.MissingDimensions) > 0 {
					if detail != "" {
						detail += "; "
					}
					// Named as keys of the evidence payload, because "missing
					// dimensions: artifact, revision" was read three corrections
					// running as a remark about scope rather than as the two
					// object keys the host is waiting for.
					detail += "no evidence carries the dimensions keys: " +
						strings.Join(view.MissingDimensions, ", ")
				}
				missing = append(missing, requirement.ID+" ("+detail+")")
			} else if !view.Resolved {
				// ClaimSupported means zero contradictions by construction, so
				// this claim is held open by its coverage row and nothing else.
				unresolved = append(unresolved, unresolvedClaimDetail(view))
			}
		case ClaimNotApplicable:
			if requirement.Layer != "slo" || !ledger.Contract.Completion.AllowUnknownSLO {
				missing = append(missing, requirement.ID)
			}
		case ClaimUnknown:
			if !view.Resolved {
				detail := requirement.ID
				if view.Stale {
					detail += " (stale)"
				}
				missing = append(missing, detail)
			}
		case ClaimContradicted, ClaimMixed:
			if !view.Resolved {
				if detail, nameable := contradictionDetail(view); nameable {
					contradicted = append(contradicted, detail)
				} else {
					unresolved = append(unresolved, unresolvedClaimDetail(view))
				}
			}
		}
	}
	if len(contradicted) > 0 {
		if ledger.negativeVerdictIsDecisive(verdict) {
			return ""
		}
		sort.Strings(contradicted)
		// One block per claim on its own lines, and the resolutions once at the
		// top. Joined with ", " these ran together into a paragraph an operator
		// could not read either — the episode page showed a live one amputated
		// mid-word.
		return "required claims still contain unresolved contradictions. " +
			conflictResolutions + "\n\n" + strings.Join(contradicted, "\n")
	}
	if len(unresolved) > 0 {
		if ledger.negativeVerdictIsDecisive(verdict) {
			return ""
		}
		sort.Strings(unresolved)
		return "required claims are not established by their coverage. " +
			coverageResolutions + "\n\n" + strings.Join(unresolved, "\n")
	}
	if len(missing) > 0 {
		if ledger.negativeVerdictIsDecisive(verdict) {
			return ""
		}
		sort.Strings(missing)
		return "required claims do not have fresh supporting evidence: " + strings.Join(missing, ", ")
	}
	return ""
}

func (ledger Ledger) negativeVerdictIsDecisive(verdict string) bool {
	if ledger.Contract.Completion.ConclusionKind == "change_review" && verdict == "failed" {
		for _, view := range ledger.Claims {
			if !view.Requirement.Required || view.Requirement.Layer != "change" ||
				view.CoverageStatus != "unhealthy" {
				continue
			}
			if len(view.Evidence) > 0 || len(view.Contradictions) > 0 {
				return true
			}
		}
		return false
	}
	if ledger.Contract.Completion.ConclusionKind != "operational_health" ||
		(verdict != "degraded" && verdict != "unhealthy") {
		return false
	}
	for _, view := range ledger.Claims {
		if !view.Requirement.Required || !view.Resolved {
			continue
		}
		if verdict == "unhealthy" && view.CoverageStatus == "unhealthy" {
			return true
		}
		if verdict == "degraded" &&
			(view.CoverageStatus == "degraded" || view.CoverageStatus == "unhealthy") {
			return true
		}
	}
	return false
}

func claimResolution(
	view ClaimView,
	coverage core.Coverage,
	covered bool,
	completion CompletionRule,
) bool {
	if !covered || strings.TrimSpace(coverage.Detail) == "" {
		return false
	}
	switch view.State {
	case ClaimSupported:
		return coverage.Status == "healthy" ||
			(completion.ConclusionKind == "change_review" && coverage.Status == "unknown")
	case ClaimMixed:
		// A contradiction every supporting observation post-dates is history,
		// not a live disagreement, and the claim has recovered rather than
		// stayed in conflict.
		//
		// Correlation-based staleness cannot see this. Its key carries the
		// source id and every dimension value, so evidence about the revision
		// that fixed a problem never supersedes evidence about the revision
		// that caused it — the thing that changed is the thing keeping the two
		// records apart. That left a permanently mixed claim, and a mixed
		// claim could only resolve through a material health effect, which
		// requires a degraded or unhealthy status. A healthy verdict was
		// therefore unreachable: the host asked for the contradiction to be
		// resolved, the model had already recorded the evidence resolving it,
		// and the loop ran until the continuation budget was spent. Forty-four
		// episodes did this, ninety-two turns between them.
		//
		// The guard survives where it earns its keep. A contradiction that is
		// the newest thing known still blocks a healthy verdict, because that
		// is a disagreement about now rather than a record of something fixed.
		if contradictionsPredateSupport(view) {
			return coverage.Status == "healthy" ||
				(completion.ConclusionKind == "change_review" && coverage.Status == "unknown")
		}
		return materialHealthEffectPresent(view, coverage.Status)
	case ClaimContradicted:
		return materialHealthEffectPresent(view, coverage.Status)
	case ClaimUnknown:
		return (completion.AllowUnknownSLO && view.Requirement.Layer == "slo" &&
			view.Requirement.Required && coverage.Status == "unknown") ||
			(completion.ConclusionKind == "factual_assessment" && coverage.Status == "unknown")
	case ClaimNotApplicable:
		return coverage.Status == "not_applicable"
	default:
		return false
	}
}

// conflictResolutions states the moves that actually close a conflict.
//
// Without them the model's only visible option is to restate the claim, which
// is exactly what it did: nine distinct rewordings of change.recent across
// thirteen rounds of tenant run_3a615b9db, each colliding with a different
// recorded statement, none of them retiring anything. Rephrasing is the one
// move that cannot work, so it is named and refused here.
const conflictResolutions = "Resolve each one exactly one of three ways: retract the losing " +
	"statement, supersede it with a record_evidence observed AFTER the record it retires, or " +
	"reconcile both with new evidence naming both evidence ids. Do not rephrase the claim: a " +
	"reworded claim collides with the next recorded statement instead."

// coverageResolutions states the moves that close a claim nothing disagrees
// with. It is deliberately the opposite instruction to conflictResolutions,
// because the two were sent as one and the wrong one closes nothing.
//
// A supported claim holds no contradiction — ClaimSupported means exactly
// that — so a correction naming retraction and supersession describes moves
// that are unavailable, and the model spends turns looking for a conflict the
// host cannot name. What is actually open is the coverage row.
const coverageResolutions = "Emit record_coverage for the named layer with the status its " +
	"recorded evidence establishes, or return completion.status blocked naming the exact gap. " +
	"Do not retract, supersede or re-record the evidence: nothing the host holds disagrees " +
	"with it."

// unresolvedClaimDetail names the coverage row holding a claim open.
//
// Harvested from the eval-prompts case "alert triage returns an alert
// assessment" on 2026-08-15: three supporting statements on change.recent,
// each with its evidence id, and a change coverage row reading status
// "unknown" because the model could not map a Sentry release to a commit. The
// host read the three statements back and demanded a retraction, three
// correction turns running, then failed the episode. The row was the whole
// blocker and the correction never mentioned it.
func unresolvedClaimDetail(view ClaimView) string {
	layer := view.Requirement.Layer
	state := "coverage for layer " + layer + " records status \"" + view.CoverageStatus +
		"\", which does not establish this claim"
	switch {
	case strings.TrimSpace(view.CoverageStatus) == "":
		state = "no coverage row is recorded for layer " + layer
	case strings.TrimSpace(view.Detail) == "":
		state = "coverage for layer " + layer + " records no detail, so it establishes nothing"
	}
	lines := []string{view.Requirement.ID, "    " + state}
	if len(view.Contradictions) == 0 {
		// Said outright, because the previous text implied the opposite and the
		// model went looking for a conflict that was never there.
		lines = append(lines, "    nothing recorded against this claim contradicts it")
	}
	return strings.Join(lines, "\n")
}

// maximumQuotedConflicts bounds how many conflicting statements one claim
// quotes. Six is past the worst recorded case — no claim in the loop ever held
// more than three at once — and keeps a correction readable when a long
// investigation has recorded dozens of observations against one claim.
const maximumQuotedConflicts = 6

// contradictionDetail quotes both sides of the disagreement, whole, with the
// evidence id of every record involved.
//
// The correction used to be the claim id and nothing else: "required claims
// still contain unresolved contradictions: change.recent". Naming one
// observation per side came next, and it was still not enough — tenant
// run_3a615b9db spent nineteen rounds and twenty-two minutes against it. The
// text quoted ONE contradicting observation, cut at 160 runes mid-word, and
// carried no evidence id at all, so the model could not say which record it
// was retiring. It rewrote the claim instead, the checker found a different
// pairwise conflict, and the host quoted that one: whack-a-mole by
// construction, one collision per round, at ~146KB of briefing per round.
//
// So: every conflicting statement, not the newest one. The id of each, because
// "retract the losing side" is unanswerable without a name for it. And the
// resolutions themselves, which the model was never told.
//
// It reports false when it cannot name a single conflicting record, which is a
// host defect rather than anything the model can repair; the caller states the
// claim's coverage instead. Only a view with at least one contradiction may be
// passed here.
func contradictionDetail(view ClaimView) (string, bool) {
	statements := make([]string, 0, len(view.Contradictions)+1)
	if support := quotedStatements(view.Evidence, maximumQuotedConflicts); len(support) > 0 {
		for _, line := range support {
			statements = append(statements, "    asserted: "+line)
		}
	} else if len(view.Contradictions) > 0 {
		// Four recorded rounds — 13, 14, 16 and 17 — rendered as
		// "change.recent (contradicted by: …)" with nothing on the asserted
		// side, because the model had already replaced its own support while
		// chasing the conflict. Read plainly that says "your claim conflicts
		// with this"; what it means is "nothing supports this claim at all".
		// Those are different repairs and the model made neither.
		statements = append(
			statements,
			"    no supporting statement is recorded for this claim; record one bound to "+
				"this exact claim_id, or retract the claim",
		)
	}
	against := quotedStatements(view.Contradictions, maximumQuotedConflicts)
	for _, line := range against {
		statements = append(statements, "    contradicted by: "+line)
	}
	if extra := len(view.Contradictions) - len(against); extra > 0 {
		statements = append(statements, fmt.Sprintf(
			"    and %d further conflicting statement(s) on this claim", extra,
		))
	}
	if len(against) == 0 {
		// A contradiction with nothing quotable — no id, source, time,
		// observation or dimension — cannot be retracted, superseded or
		// reconciled, so every resolution this correction offers is
		// unavailable. The host used to print "a recorded contradiction carries
		// no nameable evidence; re-record the contradicting observation or
		// supersede it", which named no record and closed nothing: the live
		// alert-triage case burned three correction turns on it.
		//
		// ValidateEvidence requires an observation or dimensions, and the typed
		// operation path assigns the operation id as the evidence id, so this
		// is unreachable today. If it becomes reachable it is a host bug to
		// report, not a sentence to send a model.
		return "", false
	}
	return view.Requirement.ID + "\n" + strings.Join(statements, "\n"), true
}

// quotedStatements renders each recorded observation as a quotable line
// carrying its evidence id, source and observation time — the three facts that
// let a model name the record it is retiring.
func quotedStatements(evidence []core.Evidence, limit int) []string {
	lines := make([]string, 0, min(len(evidence), limit))
	for _, item := range evidence {
		if line := statementLine(item); line != "" {
			lines = append(lines, line)
		}
		if len(lines) == limit {
			break
		}
	}
	return lines
}

// statementLine is one recorded observation, quoted.
//
// The observation is bounded generously rather than at the old 160 runes: the
// point of quoting is that the model can tell two of its own statements apart,
// and the recorded corrections cut them off inside the shared prefix — three
// different observations that all began "tenant-infra run-o2BA7juuNF9VKQCV
// applied, while va1-apps…" were indistinguishable in the text the model got.
func statementLine(item core.Evidence) string {
	observation := strings.TrimSpace(item.Observation)
	if len([]rune(observation)) > 600 {
		observation = string([]rune(observation)[:597]) + "..."
	}
	facts := make([]string, 0, 3)
	if id := strings.TrimSpace(item.ID); id != "" {
		facts = append(facts, id)
	}
	if source := strings.TrimSpace(item.SourceName); source != "" {
		facts = append(facts, source)
	}
	if at := observationTime(item.ObservedAt, item.CreatedAt); !at.IsZero() {
		facts = append(facts, "observed "+at.UTC().Format(time.RFC3339))
	}
	if observation == "" {
		// Evidence may legally carry dimensions and no observation prose, and a
		// set made only of such records used to render as nothing: a live
		// correction read "host.current_state (… snapshot] — contradicted by:
		// )", telling the model to reconcile a contradiction the host never
		// named. There is no reply that satisfies that.
		dimensions := make([]string, 0, len(item.Dimensions))
		for key, value := range item.Dimensions {
			dimensions = append(dimensions, key+"="+value)
		}
		sort.Strings(dimensions)
		if len(dimensions) == 0 && len(facts) == 0 {
			return ""
		}
		observation = strings.Join(dimensions, " ")
	}
	if len(facts) == 0 {
		return observation
	}
	return strings.TrimSpace(observation+" ") + " [" + strings.Join(facts, " | ") + "]"
}

// firstObservation is the newest observation in a set, bounded so a correction
// stays readable when the evidence body does not.
func firstObservation(evidence []core.Evidence) string {
	newest := core.Evidence{}
	for _, item := range evidence {
		if strings.TrimSpace(item.Observation) == "" {
			continue
		}
		if newest.Observation == "" ||
			observationTime(item.ObservedAt, item.CreatedAt).After(
				observationTime(newest.ObservedAt, newest.CreatedAt),
			) {
			newest = item
		}
	}
	// Evidence may legally carry dimensions and no observation prose, and a
	// contradiction set made only of such records used to render as nothing:
	// a live correction read "host.current_state (… snapshot] — contradicted
	// by: )", telling the model to reconcile a contradiction the host never
	// named. There is no reply that satisfies that. When no entry has prose,
	// fall back to the newest entry's source and dimensions so the correction
	// always names what disagreed.
	if strings.TrimSpace(newest.Observation) == "" {
		for _, item := range evidence {
			if observationTime(item.ObservedAt, item.CreatedAt).After(
				observationTime(newest.ObservedAt, newest.CreatedAt),
			) || newest.SourceName == "" && newest.ID == "" {
				newest = item
			}
		}
		parts := make([]string, 0, len(newest.Dimensions))
		for key, value := range newest.Dimensions {
			parts = append(parts, key+"="+value)
		}
		sort.Strings(parts)
		descriptor := strings.TrimSpace(newest.SourceName)
		if descriptor == "" {
			descriptor = strings.TrimSpace(newest.ID)
		}
		if len(parts) > 0 {
			descriptor = strings.TrimSpace(descriptor + " " + strings.Join(parts, " "))
		}
		return descriptor
	}
	observation := strings.TrimSpace(newest.Observation)
	if len([]rune(observation)) > 160 {
		observation = string([]rune(observation)[:157]) + "..."
	}
	if source := strings.TrimSpace(newest.SourceName); source != "" && observation != "" {
		return observation + " [" + source + "]"
	}
	return observation
}

// contradictionsPredateSupport reports whether every contradiction is strictly
// older than the newest supporting observation.
//
// Strictly, and with an unknown time counting against: a contradiction whose
// observation instant was never recorded cannot be shown to be history, and
// the safe reading of "we do not know when this was seen" is "it may be now".
func contradictionsPredateSupport(view ClaimView) bool {
	if len(view.Evidence) == 0 || len(view.Contradictions) == 0 {
		return false
	}
	var newestSupport time.Time
	for _, item := range view.Evidence {
		if at := observationTime(item.ObservedAt, item.CreatedAt); at.After(newestSupport) {
			newestSupport = at
		}
	}
	if newestSupport.IsZero() {
		return false
	}
	for _, item := range view.Contradictions {
		at := observationTime(item.ObservedAt, item.CreatedAt)
		if at.IsZero() || !at.Before(newestSupport) {
			return false
		}
	}
	return true
}

func materialHealthEffectPresent(view ClaimView, status string) bool {
	if status != "degraded" && status != "unhealthy" {
		return false
	}
	items := append(append([]core.Evidence{}, view.Evidence...), view.Contradictions...)
	for _, item := range items {
		effect := strings.ToLower(strings.TrimSpace(item.HealthEffect))
		if status == "unhealthy" && effect == "unhealthy" {
			return true
		}
		if status == "degraded" && (effect == "degraded" || effect == "unhealthy") {
			return true
		}
	}
	return false
}

func (ledger Ledger) Assessments(episodeID string, now time.Time) []core.ClaimAssessment {
	result := make([]core.ClaimAssessment, 0, len(ledger.Contract.Claims))
	for _, requirement := range ledger.Contract.Claims {
		view := ledger.Claims[requirement.ID]
		assessment := core.ClaimAssessment{
			ID:        "claim_" + episodeID + "_" + strings.ReplaceAll(requirement.ID, ".", "_"),
			EpisodeID: episodeID, ClaimID: requirement.ID, Status: string(view.State),
			Confidence: view.Confidence, Detail: view.Detail, UpdatedAt: now,
		}
		for _, item := range view.Evidence {
			assessment.EvidenceIDs = append(assessment.EvidenceIDs, item.ID)
		}
		for _, item := range view.Contradictions {
			assessment.ContradictionIDs = append(assessment.ContradictionIDs, item.ID)
		}
		result = append(result, assessment)
	}
	return result
}

func ValidateEvidence(item core.Evidence) error {
	if strings.TrimSpace(item.ClaimID) == "" {
		return fmt.Errorf("evidence requires claim_id")
	}
	if strings.TrimSpace(item.SourceType) == "" || strings.TrimSpace(item.SourceName) == "" {
		return fmt.Errorf("evidence requires source_type and source_name")
	}
	if strings.TrimSpace(item.Observation) == "" && len(item.Dimensions) == 0 {
		return fmt.Errorf("evidence requires observation or structured dimensions")
	}
	switch strings.ToLower(strings.TrimSpace(item.Relation)) {
	case "", "supports", "contradicts":
	default:
		return fmt.Errorf("unsupported evidence relation %q", item.Relation)
	}
	switch strings.ToLower(strings.TrimSpace(item.HealthEffect)) {
	case "", "none", "risk", "degraded", "unhealthy", "unknown":
	default:
		return fmt.Errorf("unsupported evidence health_effect %q", item.HealthEffect)
	}
	return nil
}

func contains(values []string, target string) bool {
	if target == "" {
		return false
	}
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func dimensionPresent(items []core.Evidence, dimension string) bool {
	for _, item := range items {
		if strings.TrimSpace(item.Dimensions[dimension]) != "" {
			return true
		}
	}
	return false
}

func weakestConfidence(items []core.Evidence) string {
	if len(items) == 0 {
		return ""
	}
	result := "high"
	for _, item := range items {
		switch strings.ToLower(strings.TrimSpace(item.Confidence)) {
		case "low":
			return "low"
		case "medium", "":
			result = "medium"
		}
	}
	return result
}
