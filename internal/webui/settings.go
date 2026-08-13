package webui

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
)

// TurnBudget is what the assembled prompts actually measured, against the cap
// the transport enforces.
//
// The Configuration page used to carry a "Prompt budget" table fed by a slice
// the caller never passed, so it rendered a header over nothing on every
// deployment since it was written. The replacement is not a better estimate of
// what a prompt might cost — it is the measurement, read from the manifests of
// turns that actually ran. A configured limit is a claim; a recorded size is a
// fact, and only one of them tells an operator whether context is being lost.
type TurnBudget struct {
	// Cap is the transport's ceiling, and Largest and Typical are measured
	// against it. Typical is the median rather than the mean because one
	// enormous turn should not move the number an operator reads as "normal".
	Cap              int
	Turns            int
	Largest, Typical int
	// Thinned counts turns that reached the model with at least one layer of
	// context dropped, and Layers says which layers, most often dropped first.
	Thinned int
	Layers  []BudgetLayer
	Oldest  time.Time
}

// BudgetLayer is one kind of dropped context and how many turns lost it.
type BudgetLayer struct {
	Reason string
	Turns  int
}

// Measured reports whether any turn has been recorded with its prompt kept.
func (b TurnBudget) Measured() bool { return b.Turns > 0 }

// Fullest is how close the largest turn came to the ceiling, as a percentage.
func (b TurnBudget) Fullest() int { return percent(b.Largest, b.Cap) }

// Healthy reports a budget with room to spare and nothing being cut.
//
// Both halves are required. Turns can sit at a third of the ceiling and still
// drop context every time, because what the assembler is budgeting against is
// its own share of the prompt rather than the whole of it — which is exactly
// the state that looks fine from the cap alone and is not.
func (b TurnBudget) Healthy() bool { return b.Thinned == 0 && b.Fullest() < 80 }

// Verdict states what the numbers mean, so the section says something an
// operator can act on rather than leaving them to divide two figures.
func (b TurnBudget) Verdict() string {
	switch {
	case !b.Measured():
		return "No turn has run with its prompt kept, so there is nothing to measure yet."
	case b.Thinned > 0 && b.Fullest() < 60:
		return "Context is being dropped while the largest turn still used well under " +
			"the ceiling, so the cap is not what cut it. The assembler budgets the " +
			"conversation against its own share of the prompt rather than against " +
			"what the transport will carry, which leaves headroom nothing is allowed " +
			"to use. What was cut is listed below, most often cut first."
	case b.Thinned > 0:
		return "Some turns reached the model with context dropped. What was cut is " +
			"listed below, most often cut first."
	case b.Fullest() >= 80:
		return "Nothing has been cut yet, but the largest turn is close enough to the " +
			"ceiling that the next one may be."
	default:
		return "Every turn fitted with room to spare, and nothing was dropped to make it fit."
	}
}

// TurnBudget measures the recent prompts. The window is the last turns rather
// than the last days: a deployment that ran nothing this week should still be
// able to say what its prompts looked like when it last worked.
func (r *Reader) TurnBudget(ctx context.Context) (TurnBudget, error) {
	budget := TurnBudget{Cap: coop.MaxPromptBytes}
	if !r.live() {
		return budget, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT LENGTH(submitted_prompt), omissions_json, created_at
	  FROM context_manifests WHERE submitted_prompt <> ''
	  ORDER BY created_at DESC LIMIT 300`)
	if err != nil {
		return budget, err
	}
	defer rows.Close()
	sizes := []int{}
	dropped := map[string]int{}
	for rows.Next() {
		var size int
		var omissions, created string
		if err := rows.Scan(&size, &omissions, &created); err != nil {
			return budget, err
		}
		sizes = append(sizes, size)
		budget.Oldest = parseStamp(created)
		if reasons := decodeOmissions(omissions); len(reasons) > 0 {
			budget.Thinned++
			for _, reason := range reasons {
				dropped[reason]++
			}
		}
	}
	if err := rows.Err(); err != nil {
		return budget, err
	}
	budget.Turns = len(sizes)
	if budget.Turns == 0 {
		return budget, nil
	}
	sort.Ints(sizes)
	budget.Largest = sizes[len(sizes)-1]
	budget.Typical = sizes[len(sizes)/2]
	for reason, turns := range dropped {
		budget.Layers = append(budget.Layers, BudgetLayer{Reason: reason, Turns: turns})
	}
	sort.Slice(budget.Layers, func(i, j int) bool {
		if budget.Layers[i].Turns != budget.Layers[j].Turns {
			return budget.Layers[i].Turns > budget.Layers[j].Turns
		}
		return budget.Layers[i].Reason < budget.Layers[j].Reason
	})
	if len(budget.Layers) > 8 {
		budget.Layers = budget.Layers[:8]
	}
	return budget, nil
}

// decodeOmissions reads the recorded reasons, collapsing the transport's
// elision notes into one line.
//
// Those notes name the exact byte counts of the prompt they cut — "elided 4085
// bytes from the middle of this 69621-byte prompt" — so counting them verbatim
// produces one row per turn and a list that says nothing. They are one fact
// worth stating once: the transport, not the assembler, did the cutting.
func decodeOmissions(encoded string) []string {
	if encoded == "" || encoded == "[]" {
		return nil
	}
	var reasons []string
	if err := json.Unmarshal([]byte(encoded), &reasons); err != nil {
		return nil
	}
	out := make([]string, 0, len(reasons))
	for _, reason := range reasons {
		if strings.Contains(reason, "transport elided") {
			reason = "the transport elided the middle of an oversized prompt"
		}
		out = append(out, reason)
	}
	return out
}

// SetBy is who put a piece of configuration in place and when.
//
// Every standing instruction here was created by someone asking for it in
// Slack, and none of it can be edited on this page. That makes provenance the
// operative fact rather than a footnote: an operator who disagrees with a
// setting has to go back to the conversation that made it, and the page has to
// be able to say which one that was.
type SetBy struct {
	Actor, Source string
	At            time.Time
}

// PreferenceDetail is one saved preference with what it changes said plainly.
type PreferenceDetail struct {
	Preference
	SetBy
	ScopeKind, ScopeKey string
}

// Means describes the effect of this preference in the words an operator would
// use, because "response_location = prefer_thread" states a value and not a
// behaviour.
func (p PreferenceDetail) Means() string {
	switch p.Name + "=" + p.Value {
	case "response_location=prefer_thread":
		return "Answer in a thread under the message, rather than in the channel."
	case "response_location=prefer_channel":
		return "Answer in the channel, rather than in a thread under the message."
	case "response_location=follow_context":
		return "Answer wherever the message was: in a thread if it was in one."
	case "response_detail=concise":
		return "Keep replies short — the answer, not the reasoning behind it."
	case "response_detail=standard":
		return "Give the answer with the reasoning that supports it."
	case "response_detail=detailed":
		return "Show the working: evidence, steps checked, and what was ruled out."
	case "health_check_depth=quick":
		return "Check the obvious signals and answer fast."
	case "health_check_depth=standard":
		return "Check the usual signals before answering."
	case "health_check_depth=deep":
		return "Check thoroughly, including the signals that are slow to read."
	}
	return ""
}

// Title names the preference in the page's own words.
func (p PreferenceDetail) Title() string {
	switch p.Name {
	case "response_location":
		return "Where to answer"
	case "response_detail":
		return "How much to say"
	case "health_check_depth":
		return "How hard to look"
	}
	return p.Name
}

// Where says what the preference applies to, in a form that reads as a place
// rather than as two database columns.
func (p PreferenceDetail) Where() string {
	switch p.ScopeKind {
	case "workspace":
		return "everywhere in this workspace"
	case "channel":
		return p.Scope
	case "repository":
		return "work on " + p.ScopeKey
	case "operator":
		return "requests from " + p.Scope
	}
	return p.Scope
}

// PreferenceDetails is every saved preference with its provenance.
func (r *Reader) PreferenceDetails(ctx context.Context) ([]PreferenceDetail, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT name, value, scope_kind, scope_key, enabled, expires_at,
	         actor_id, source_ref, created_at
	  FROM responder_preferences ORDER BY updated_at DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []PreferenceDetail{}
	for rows.Next() {
		var item PreferenceDetail
		var expires, created string
		if err := rows.Scan(&item.Name, &item.Value, &item.ScopeKind, &item.ScopeKey,
			&item.Enabled, &expires, &item.Actor, &item.Source, &created); err != nil {
			return nil, err
		}
		item.Scope = item.ScopeKind
		if item.ScopeKey != "" {
			if item.ScopeKind == "channel" {
				item.Scope = r.channelName(ctx, item.ScopeKey)
			} else {
				item.Scope = r.userName(item.ScopeKey)
			}
		}
		item.Expires, item.At = parseStamp(expires), parseStamp(created)
		item.Actor = r.userName(item.Actor)
		items = append(items, item)
	}
	return items, rows.Err()
}

// RuleDetail is one standing rule with everything needed to judge it: what it
// matches, what it has cost, and who asked for it.
type RuleDetail struct {
	StandingRule
	SetBy
	ID, Repository, SourceKind string
	Created                    time.Time
}

// Triggered names the event this rule watches for, in the operator's words.
func (d RuleDetail) Triggered() string {
	switch d.Trigger {
	case "operational_alert":
		return "an alert fires"
	case "deployment":
		return "a deployment is announced"
	case "terraform_plan":
		return "a Terraform plan is posted"
	case "terraform_lifecycle":
		return "a Terraform apply starts or finishes"
	}
	return d.Trigger
}

// Does names the response, in the same voice as Triggered.
func (d RuleDetail) Does() string {
	switch d.Action {
	case "triage_alert":
		return "triage it and say whether it matters"
	case "verify_deployment":
		return "check the deployment actually landed"
	case "review_terraform_plan":
		return "review the plan before it is applied"
	case "monitor_terraform_lifecycle":
		return "watch the apply through to its result"
	}
	return d.Action
}

// From says which senders the rule listens to. A rule bound to apps ignores
// people saying the same thing, which is the difference between a rule that
// looks dead and one that is waiting for a sender that never posts.
func (d RuleDetail) From() string {
	switch d.SourceKind {
	case "app":
		return "posted by an app"
	case "human":
		return "posted by a person"
	}
	return "from anyone"
}

// Sentence is the whole rule in one line, which is how an operator holds it in
// mind and how the list has to read to be scannable.
func (d RuleDetail) Sentence() string {
	return "When " + d.Triggered() + " in " + d.Channel + " " + d.From() +
		", " + d.Does() + "."
}

// RuleRun is one firing of a standing rule, with what came of it.
type RuleRun struct {
	Outcome, Action, Reason string
	Episode                 string
	At                      time.Time
}

// Acted reports a firing that produced a response rather than a decision to
// stay quiet.
func (r RuleRun) Acted() bool { return r.Outcome != "ignore" && r.Outcome != "shadowed" }

// Reads names the outcome the way the rest of the control plane does.
func (r RuleRun) Reads() string {
	switch r.Outcome {
	case "reply":
		return "answered"
	case "ignore":
		return "stayed quiet"
	case "shadowed":
		return "already covered"
	}
	return r.Outcome
}

// StandingRuleDetails is every rule with its provenance and identity, which the
// summary rows on the Configuration page deliberately leave out.
func (r *Reader) StandingRuleDetails(ctx context.Context) ([]RuleDetail, error) {
	if !r.live() {
		return nil, nil
	}
	return r.ruleDetails(ctx, "")
}

// StandingRuleDetail is one rule by id.
func (r *Reader) StandingRuleDetail(ctx context.Context, id string) (RuleDetail, bool, error) {
	if !r.live() || id == "" {
		return RuleDetail{}, false, nil
	}
	items, err := r.ruleDetails(ctx, id)
	if err != nil || len(items) == 0 {
		return RuleDetail{}, false, err
	}
	return items[0], true, nil
}

func (r *Reader) ruleDetails(ctx context.Context, id string) ([]RuleDetail, error) {
	where, args := "", []any{}
	if id != "" {
		where, args = " WHERE id = ?", []any{id}
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT id, trigger_name, action_name, channel_id, repository, source_kind,
	         enabled, trigger_count, acted_count, quiet_count,
	         COALESCE((SELECT max(run.created_at) FROM standing_rule_runs run
	                   WHERE run.rule_id = standing_rules.id
	                     AND run.outcome NOT IN ('ignore', 'shadowed')), ''),
	         expires_at, actor_id, source_ref, created_at
	  FROM standing_rules`+where+` ORDER BY updated_at DESC LIMIT 100`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []RuleDetail{}
	for rows.Next() {
		var item RuleDetail
		var channel, acted, expires, created string
		if err := rows.Scan(&item.ID, &item.Trigger, &item.Action, &channel,
			&item.Repository, &item.SourceKind, &item.Enabled, &item.Runs,
			&item.Acted, &item.Quiet, &acted, &expires, &item.Actor,
			&item.Source, &created); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.LastActed, item.Expires = parseStamp(acted), parseStamp(expires)
		item.Created, item.At = parseStamp(created), parseStamp(created)
		item.Actor = r.userName(item.Actor)
		items = append(items, item)
	}
	return items, rows.Err()
}

// RuleRuns is every recorded firing of one rule, newest first.
//
// The reason and the episode come from the decision the firing produced rather
// than from the rule's own row, because a rule records that it matched and
// nothing about what the match led to. Both joins are outer: a firing older
// than the decision retention window keeps its outcome and loses its
// explanation, which is a thinner row rather than a missing one.
func (r *Reader) RuleRuns(ctx context.Context, id string, limit int) ([]RuleRun, error) {
	if !r.live() || id == "" {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT run.outcome, run.created_at,
	         COALESCE(decision.action, ''), COALESCE(decision.reason, ''),
	         COALESCE(agent.episode_id, '')
	  FROM standing_rule_runs run
	  LEFT JOIN evaluation_decisions decision ON decision.source_input = run.source_input
	  LEFT JOIN agent_runs agent ON agent.id = decision.agent_run_id
	  WHERE run.rule_id = ? ORDER BY run.created_at DESC LIMIT ?`, id, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []RuleRun{}
	for rows.Next() {
		var item RuleRun
		var created string
		if err := rows.Scan(&item.Outcome, &created, &item.Action,
			&item.Reason, &item.Episode); err != nil {
			return nil, err
		}
		item.At = parseStamp(created)
		items = append(items, item)
	}
	return items, rows.Err()
}

// Deployment is what this instance is, as opposed to what it has been told.
//
// It sat in the page footer in three-point type, which is where a fact goes
// when nobody has decided whether it matters. It matters on exactly one page:
// the one an operator opens to answer "how is this set up".
type Deployment struct {
	Name, Schema, Binary string
	Models               []DeploymentModel
	Coop                 string
}

// DeploymentModel is one model the deployment has actually run, with how often.
// Configured models are not listed: a model named in a file and never reached
// is a plan, and this section reports what happened.
type DeploymentModel struct {
	Provider, Model, Effort string
	Turns                   int
}

// Label names the model the way the rest of the control plane does.
func (m DeploymentModel) Label() string {
	if m.Provider == "" {
		return m.Model
	}
	return m.Provider + " " + m.Model
}

// Models reports which models ran, busiest first.
func (r *Reader) Models(ctx context.Context) ([]DeploymentModel, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT provider, model, reasoning_effort, COUNT(*) AS turns
	  FROM context_manifests WHERE model <> ''
	  GROUP BY provider, model, reasoning_effort
	  ORDER BY turns DESC LIMIT 12`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []DeploymentModel{}
	for rows.Next() {
		var item DeploymentModel
		if err := rows.Scan(&item.Provider, &item.Model, &item.Effort, &item.Turns); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}
