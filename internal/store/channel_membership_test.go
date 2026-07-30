package store

import (
	"context"
	"testing"
	"time"
)

func TestSlackChannelMembershipTransitionsDriveOnboardingOncePerJoin(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first := time.Now().UTC().Truncate(time.Microsecond)
	observations := []SlackChannelMembershipObservation{
		{ChannelID: "CPUBLIC", ChannelName: "infra", Present: true},
		{ChannelID: "CPRIVATE", ChannelName: "security", Private: true, Present: true},
	}
	if err := st.ReconcileSlackChannelMemberships(ctx, observations, first); err != nil {
		t.Fatal(err)
	}
	pending, err := st.ListPendingSlackChannelOnboarding(ctx, 10)
	if err != nil || len(pending) != 2 {
		t.Fatalf("first pending onboarding = %+v, %v", pending, err)
	}
	sawPrivate := false
	for _, item := range pending {
		if !item.JoinedAt.Equal(first) {
			t.Fatalf("first joined time = %v, want %v", item.JoinedAt, first)
		}
		if item.ChannelID == "CPRIVATE" && item.Private {
			sawPrivate = true
		}
		if err := st.FinishSlackChannelOnboarding(
			ctx, item.ChannelID, item.JoinedAt,
		); err != nil {
			t.Fatal(err)
		}
	}
	if !sawPrivate {
		t.Fatalf("private channel was not retained in pending onboarding: %+v", pending)
	}
	if err := st.ReconcileSlackChannelMemberships(
		ctx, observations, first.Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if pending, err = st.ListPendingSlackChannelOnboarding(ctx, 10); err != nil ||
		len(pending) != 0 {
		t.Fatalf("unchanged membership queued onboarding = %+v, %v", pending, err)
	}

	observations[0].Present = false
	if err := st.ReconcileSlackChannelMemberships(
		ctx, observations, first.Add(2*time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	observations[0].Present = true
	rejoined := first.Add(3 * time.Minute)
	if err := st.ReconcileSlackChannelMemberships(ctx, observations, rejoined); err != nil {
		t.Fatal(err)
	}
	pending, err = st.ListPendingSlackChannelOnboarding(ctx, 10)
	if err != nil || len(pending) != 1 || !pending[0].JoinedAt.Equal(rejoined) {
		t.Fatalf("rejoin pending onboarding = %+v, %v", pending, err)
	}

	if deleted, err := st.DeleteChannelConfigurationState(ctx, "CPUBLIC"); err != nil ||
		deleted != 1 {
		t.Fatalf("deleted channel membership state = %d, %v", deleted, err)
	}
	if pending, err = st.ListPendingSlackChannelOnboarding(ctx, 10); err != nil ||
		len(pending) != 0 {
		t.Fatalf("deleted channel remains pending = %+v, %v", pending, err)
	}
}
