package behaviorstore_test

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/behaviorstore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func TestPreferencesReplaceResolveByScopeAndToggle(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := behaviorstore.New(db, time.Now)
	now := time.Now().UTC()
	add := func(scope, key, value string) core.ResponderPreference {
		preference, replaced, saveErr := repo.UpsertPreference(
			ctx,
			core.ResponderPreference{
				ScopeKind: scope, ScopeKey: key,
				Name: "health_check_depth", Value: value,
				SourceRef: "slack_" + scope, ActorID: "UOPERATOR",
				ExpiresAt: now.Add(30 * 24 * time.Hour),
			},
			20,
			10,
		)
		if saveErr != nil || replaced {
			t.Fatalf("add %s = %+v, replaced=%t, err=%v",
				scope, preference, replaced, saveErr)
		}
		return preference
	}
	workspace := add("workspace", "TWORKSPACE", "quick")
	repository := add("repository", "repo", "standard")
	channel := add("channel", "COPS", "deep")
	operator := add("operator", "UOPERATOR", "quick")

	preferences, err := repo.ListPreferencesForContext(
		ctx, "TWORKSPACE", "COPS", "repo", "UOPERATOR", true, 20,
	)
	if err != nil || len(preferences) != 4 {
		t.Fatalf("preferences = %+v, %v", preferences, err)
	}
	wantOrder := []string{operator.ID, channel.ID, repository.ID, workspace.ID}
	for index, want := range wantOrder {
		if preferences[index].ID != want {
			t.Fatalf("preference order = %+v, want %v", preferences, wantOrder)
		}
	}

	replacement, replaced, err := repo.UpsertPreference(
		ctx,
		core.ResponderPreference{
			ScopeKind: "channel", ScopeKey: "COPS",
			Name: "health_check_depth", Value: "standard",
			SourceRef: "slack_replacement", ActorID: "UOPERATOR",
			ExpiresAt: now.Add(90 * 24 * time.Hour),
		},
		20,
		10,
	)
	if err != nil || !replaced || replacement.ID != channel.ID ||
		replacement.Value != "standard" {
		t.Fatalf("replacement = %+v, replaced=%t, err=%v",
			replacement, replaced, err)
	}
	disabled, err := repo.SetPreferenceEnabled(ctx, replacement.ID, false)
	if err != nil || disabled.Enabled {
		t.Fatalf("disabled preference = %+v, %v", disabled, err)
	}
	active, err := repo.ListPreferencesForContext(
		ctx, "TWORKSPACE", "COPS", "repo", "", true, 20,
	)
	if err != nil || len(active) != 2 {
		t.Fatalf("active preferences = %+v, %v", active, err)
	}
	if _, err := repo.DeletePreference(ctx, replacement.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.GetPreference(ctx, replacement.ID); err != core.ErrNotFound {
		t.Fatalf("deleted preference error = %v", err)
	}
}

func TestResponseLocationPreferenceIsTypedAndRejectsRepositoryScope(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := behaviorstore.New(db, time.Now)
	preference := core.ResponderPreference{
		ScopeKind: "operator", ScopeKey: "UOPERATOR",
		Name: "response_location", Value: "prefer_thread",
		SourceRef: "slack_location", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
	}
	stored, replaced, err := repo.UpsertPreference(ctx, preference, 20, 10)
	if err != nil || replaced || stored.Value != "prefer_thread" {
		t.Fatalf("response location preference = %+v, replaced=%t, err=%v", stored, replaced, err)
	}
	preference.ScopeKind = "repository"
	preference.ScopeKey = "repo"
	if _, _, err := repo.UpsertPreference(ctx, preference, 20, 10); err == nil {
		t.Fatal("repository-scoped response location was accepted")
	}
	preference.ScopeKind = "channel"
	preference.ScopeKey = "COPS"
	preference.Value = "sometimes"
	if _, _, err := repo.UpsertPreference(ctx, preference, 20, 10); err == nil {
		t.Fatal("untyped response location was accepted")
	}
}

// A rule has to be judgeable from its own row.
//
// trigger_count alone never was: emisar's Terraform rule reads 64 fires, and the
// only outcomes anyone kept were 'ignore'. The tally has to survive the runs
// being swept — that is the whole point of putting it on the rule — and it has
// to keep the two kinds of fire apart, because "matched and answered" and
// "matched and said nothing" are the entire question.
func TestStandingRuleTallyOutlivesTheRunsItCounts(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := behaviorstore.New(db, time.Now)
	rule, _, err := repo.UpsertStandingRule(
		ctx,
		core.StandingRule{
			ChannelID: "COPS", Repository: "repo",
			Trigger: "terraform_plan", Action: "review_terraform_plan",
			SourceKind: "app", SourceRef: "slack_rule", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
		},
		20, 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	for input, outcome := range map[string]string{
		"plan_1": "reply", "plan_2": "incident", "plan_3": "ignore",
		"plan_4": "ignore", "plan_5": "shadowed",
	} {
		if _, err := repo.RecordStandingRuleRun(
			ctx, rule.ID, input, "Ev_"+input, outcome,
		); err != nil {
			t.Fatal(err)
		}
	}
	// A redelivered Slack event is one fire, so it moves neither counter.
	if recorded, err := repo.RecordStandingRuleRun(
		ctx, rule.ID, "plan_1", "Ev_plan_1", "reply",
	); err != nil || recorded {
		t.Fatalf("redelivery recorded = %t, %v", recorded, err)
	}
	stored, err := repo.GetStandingRule(ctx, rule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.TriggerCount != 5 || stored.ActedCount != 2 || stored.QuietCount != 3 {
		t.Fatalf(
			"fired=%d acted=%d quiet=%d, want 5/2/3",
			stored.TriggerCount, stored.ActedCount, stored.QuietCount,
		)
	}
	if stored.LastActed.IsZero() {
		t.Fatal("a rule that acted twice reports no recent action")
	}

	// Retention sweeps the evidence. The count is what is left, and losing it
	// here is exactly the failure this table was unable to survive before.
	if _, err := db.Exec(`DELETE FROM standing_rule_runs WHERE rule_id = ?`, rule.ID); err != nil {
		t.Fatal(err)
	}
	swept, err := repo.GetStandingRule(ctx, rule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if swept.TriggerCount != 5 || swept.ActedCount != 2 || swept.QuietCount != 3 {
		t.Fatalf(
			"after the sweep fired=%d acted=%d quiet=%d, want the tally intact",
			swept.TriggerCount, swept.ActedCount, swept.QuietCount,
		)
	}
	// Recency is deliberately not durable: with no retained run to point at, the
	// honest answer is "not inside the window", not a date nothing can support.
	if !swept.LastActed.IsZero() {
		t.Fatalf("last acted = %s, want empty once the evidence expired", swept.LastActed)
	}
}

func TestStandingRulesDeduplicateRunsAndCleanUpWithChannel(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := behaviorstore.New(db, time.Now)
	rule, replaced, err := repo.UpsertStandingRule(
		ctx,
		core.StandingRule{
			ChannelID: "COPS", Repository: "repo",
			Trigger: "terraform_plan", Action: "review_terraform_plan",
			SourceKind: "app", SourceRef: "slack_rule", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
		},
		20,
		10,
	)
	if err != nil || replaced || rule.ID == "" {
		t.Fatalf("rule = %+v, replaced=%t, err=%v", rule, replaced, err)
	}
	recorded, err := repo.RecordStandingRuleRun(
		ctx, rule.ID, "slack_plan", "EvPlan", "replied",
	)
	if err != nil || !recorded {
		t.Fatalf("first run = %t, %v", recorded, err)
	}
	recorded, err = repo.RecordStandingRuleRun(
		ctx, rule.ID, "slack_plan", "EvPlan", "replied",
	)
	if err != nil || recorded {
		t.Fatalf("duplicate run = %t, %v", recorded, err)
	}
	rule, err = repo.GetStandingRule(ctx, rule.ID)
	if err != nil || rule.TriggerCount != 1 || rule.LastTriggered.IsZero() {
		t.Fatalf("recorded rule = %+v, %v", rule, err)
	}
	rule, err = repo.SetStandingRuleEnabled(ctx, rule.ID, false)
	if err != nil || rule.Enabled {
		t.Fatalf("disabled rule = %+v, %v", rule, err)
	}
	active, err := repo.ListStandingRulesForChannel(ctx, "COPS", true, 20)
	if err != nil || len(active) != 0 {
		t.Fatalf("active rules = %+v, %v", active, err)
	}
	preference, _, err := repo.UpsertPreference(
		ctx,
		core.ResponderPreference{
			ScopeKind: "channel", ScopeKey: "COPS",
			Name: "response_detail", Value: "detailed",
			SourceRef: "slack_pref", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(time.Hour),
		},
		20,
		10,
	)
	if err != nil {
		t.Fatal(err)
	}
	preferences, rules, err := repo.DeleteChannelBehavior(ctx, "COPS")
	if err != nil || preferences != 1 || rules != 1 {
		t.Fatalf("channel cleanup = preferences=%d rules=%d err=%v",
			preferences, rules, err)
	}
	if _, err := repo.GetPreference(ctx, preference.ID); err != core.ErrNotFound {
		t.Fatalf("channel preference survived deletion: %v", err)
	}
	if _, err := repo.GetStandingRule(ctx, rule.ID); err != core.ErrNotFound {
		t.Fatalf("channel rule survived deletion: %v", err)
	}
	var runs int
	if err := db.QueryRow(`SELECT count(*) FROM standing_rule_runs`).Scan(&runs); err != nil ||
		runs != 0 {
		t.Fatalf("standing rule runs after cascade = %d, %v", runs, err)
	}
}

func TestTerraformLifecycleStandingRulePersists(t *testing.T) {
	ctx := context.Background()
	repo := behaviorstore.New(storetest.DB(t), time.Now)
	rule, replaced, err := repo.UpsertStandingRule(
		ctx,
		core.StandingRule{
			ChannelID: "CTERRAFORM", Repository: "repo",
			Trigger: "terraform_lifecycle", Action: "monitor_terraform_lifecycle",
			SourceKind: "app", SourceRef: "slack_assignment", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
		},
		20,
		10,
	)
	if err != nil || replaced || rule.ID == "" {
		t.Fatalf("terraform lifecycle rule = %+v, replaced=%t, err=%v", rule, replaced, err)
	}
	stored, err := repo.GetStandingRule(ctx, rule.ID)
	if err != nil || stored.Trigger != "terraform_lifecycle" ||
		stored.Action != "monitor_terraform_lifecycle" {
		t.Fatalf("stored terraform lifecycle rule = %+v, err=%v", stored, err)
	}
}

func TestBehaviorCapacityAllowsReplacementButRejectsNewEntries(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := behaviorstore.New(db, time.Now)
	preference := core.ResponderPreference{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		Name: "health_check_depth", Value: "standard",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := repo.UpsertPreference(ctx, preference, 1, 1); err != nil {
		t.Fatal(err)
	}
	preference.Value = "deep"
	if _, replaced, err := repo.UpsertPreference(ctx, preference, 1, 1); err != nil ||
		!replaced {
		t.Fatalf("preference replacement = %t, %v", replaced, err)
	}
	preference.Name = "response_detail"
	preference.Value = "detailed"
	if _, _, err := repo.UpsertPreference(ctx, preference, 1, 1); err == nil {
		t.Fatal("new preference exceeded capacity")
	}

	rule := core.StandingRule{
		ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "any", SourceRef: "slack_rule", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := repo.UpsertStandingRule(ctx, rule, 1, 1); err != nil {
		t.Fatal(err)
	}
	rule.ExpiresAt = time.Now().UTC().Add(2 * time.Hour)
	if _, replaced, err := repo.UpsertStandingRule(ctx, rule, 1, 1); err != nil ||
		!replaced {
		t.Fatalf("rule replacement = %t, %v", replaced, err)
	}
	rule.Trigger = "deployment"
	rule.Action = "verify_deployment"
	if _, _, err := repo.UpsertStandingRule(ctx, rule, 1, 1); err == nil {
		t.Fatal("new rule exceeded capacity")
	}
}
