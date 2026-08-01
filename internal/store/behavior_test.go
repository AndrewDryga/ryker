package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestPreferencesReplaceResolveByScopeAndToggle(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	add := func(scope, key, value string) core.ResponderPreference {
		preference, replaced, saveErr := st.UpsertPreference(
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

	preferences, err := st.ListPreferencesForContext(
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

	replacement, replaced, err := st.UpsertPreference(
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
	disabled, err := st.SetPreferenceEnabled(ctx, replacement.ID, false)
	if err != nil || disabled.Enabled {
		t.Fatalf("disabled preference = %+v, %v", disabled, err)
	}
	active, err := st.ListPreferencesForContext(
		ctx, "TWORKSPACE", "COPS", "repo", "", true, 20,
	)
	if err != nil || len(active) != 2 {
		t.Fatalf("active preferences = %+v, %v", active, err)
	}
	if _, err := st.DeletePreference(ctx, replacement.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetPreference(ctx, replacement.ID); err != ErrNotFound {
		t.Fatalf("deleted preference error = %v", err)
	}
}

func TestResponseLocationPreferenceIsTypedAndRejectsRepositoryScope(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	preference := core.ResponderPreference{
		ScopeKind: "operator", ScopeKey: "UOPERATOR",
		Name: "response_location", Value: "prefer_thread",
		SourceRef: "slack_location", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
	}
	stored, replaced, err := st.UpsertPreference(ctx, preference, 20, 10)
	if err != nil || replaced || stored.Value != "prefer_thread" {
		t.Fatalf("response location preference = %+v, replaced=%t, err=%v", stored, replaced, err)
	}
	preference.ScopeKind = "repository"
	preference.ScopeKey = "repo"
	if _, _, err := st.UpsertPreference(ctx, preference, 20, 10); err == nil {
		t.Fatal("repository-scoped response location was accepted")
	}
	preference.ScopeKind = "channel"
	preference.ScopeKey = "COPS"
	preference.Value = "sometimes"
	if _, _, err := st.UpsertPreference(ctx, preference, 20, 10); err == nil {
		t.Fatal("untyped response location was accepted")
	}
}

func TestStandingRulesDeduplicateRunsAndCleanUpWithChannel(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	rule, replaced, err := st.UpsertStandingRule(
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
	recorded, err := st.RecordStandingRuleRun(
		ctx, rule.ID, "slack_plan", "EvPlan", "replied",
	)
	if err != nil || !recorded {
		t.Fatalf("first run = %t, %v", recorded, err)
	}
	recorded, err = st.RecordStandingRuleRun(
		ctx, rule.ID, "slack_plan", "EvPlan", "replied",
	)
	if err != nil || recorded {
		t.Fatalf("duplicate run = %t, %v", recorded, err)
	}
	rule, err = st.GetStandingRule(ctx, rule.ID)
	if err != nil || rule.TriggerCount != 1 || rule.LastTriggered.IsZero() {
		t.Fatalf("recorded rule = %+v, %v", rule, err)
	}
	rule, err = st.SetStandingRuleEnabled(ctx, rule.ID, false)
	if err != nil || rule.Enabled {
		t.Fatalf("disabled rule = %+v, %v", rule, err)
	}
	active, err := st.ListStandingRulesForChannel(ctx, "COPS", true, 20)
	if err != nil || len(active) != 0 {
		t.Fatalf("active rules = %+v, %v", active, err)
	}
	preference, _, err := st.UpsertPreference(
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
	preferences, rules, err := st.DeleteChannelBehavior(ctx, "COPS")
	if err != nil || preferences != 1 || rules != 1 {
		t.Fatalf("channel cleanup = preferences=%d rules=%d err=%v",
			preferences, rules, err)
	}
	if _, err := st.GetPreference(ctx, preference.ID); err != ErrNotFound {
		t.Fatalf("channel preference survived deletion: %v", err)
	}
	if _, err := st.GetStandingRule(ctx, rule.ID); err != ErrNotFound {
		t.Fatalf("channel rule survived deletion: %v", err)
	}
	var runs int
	if err := st.db.QueryRow(`SELECT count(*) FROM standing_rule_runs`).Scan(&runs); err != nil ||
		runs != 0 {
		t.Fatalf("standing rule runs after cascade = %d, %v", runs, err)
	}
}

func TestBehaviorCapacityAllowsReplacementButRejectsNewEntries(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	preference := core.ResponderPreference{
		ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		Name: "health_check_depth", Value: "standard",
		SourceRef: "slack_1", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := st.UpsertPreference(ctx, preference, 1, 1); err != nil {
		t.Fatal(err)
	}
	preference.Value = "deep"
	if _, replaced, err := st.UpsertPreference(ctx, preference, 1, 1); err != nil ||
		!replaced {
		t.Fatalf("preference replacement = %t, %v", replaced, err)
	}
	preference.Name = "response_detail"
	preference.Value = "detailed"
	if _, _, err := st.UpsertPreference(ctx, preference, 1, 1); err == nil {
		t.Fatal("new preference exceeded capacity")
	}

	rule := core.StandingRule{
		ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "any", SourceRef: "slack_rule", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}
	if _, _, err := st.UpsertStandingRule(ctx, rule, 1, 1); err != nil {
		t.Fatal(err)
	}
	rule.ExpiresAt = time.Now().UTC().Add(2 * time.Hour)
	if _, replaced, err := st.UpsertStandingRule(ctx, rule, 1, 1); err != nil ||
		!replaced {
		t.Fatalf("rule replacement = %t, %v", replaced, err)
	}
	rule.Trigger = "deployment"
	rule.Action = "verify_deployment"
	if _, _, err := st.UpsertStandingRule(ctx, rule, 1, 1); err == nil {
		t.Fatal("new rule exceeded capacity")
	}
}
