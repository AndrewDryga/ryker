package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestConfigurationSessionAndChannelConfigurationLifecycle(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	session, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: "T123", ChannelID: "C123", Initiator: "U123",
		Draft: core.ChannelConfiguration{
			ChannelID: "C123", Participation: "mentions",
			Repository: "repo", AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: "T123", ChannelID: "C123",
		Draft: core.ChannelConfiguration{
			ChannelID: "C123", Participation: "mentions",
			Repository: "repo", AlertPolicy: "reply",
		},
	}); !errors.Is(err, ErrConflict) {
		t.Fatalf("second active session error = %v, want conflict", err)
	}
	if err := st.BindConfigurationThread(ctx, session.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "C123")
	if err != nil || session.ThreadTS != "1700.1" || session.Revision != 2 {
		t.Fatalf("bound session = %+v, %v", session, err)
	}
	if !slices.Equal(session.ThreadRoots, []string{"1700.1"}) {
		t.Fatalf("bound thread roots = %+v", session.ThreadRoots)
	}
	if err := st.RecordConfigurationMessage(
		ctx, session.ID, "1700.2", "",
	); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordConfigurationMessage(
		ctx, session.ID, "1700.3", "1700.2",
	); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "C123")
	if err != nil {
		t.Fatal(err)
	}
	if session.ResponseThreadTS != "1700.2" ||
		!slices.Equal(session.ThreadRoots, []string{"1700.1", "1700.2"}) {
		t.Fatalf("recorded conversation locations = %+v", session)
	}
	session.Draft.Participation = "proactive"
	session, err = st.AdvanceConfigurationSession(
		ctx, session.ID, session.Revision, "confirm", "confirming", session.Draft,
	)
	if err != nil {
		t.Fatal(err)
	}
	session.Draft.ActorID = "U123"
	session.Draft.InviteUsers = []string{"U123", "U456"}
	session.Draft.InviteUserGroups = []string{"S123"}
	configuration, err := st.SaveChannelConfiguration(ctx, session.Draft)
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Revision != 1 ||
		!slices.Equal(configuration.InviteUsers, []string{"U123", "U456"}) ||
		!slices.Equal(configuration.InviteUserGroups, []string{"S123"}) {
		t.Fatalf("saved configuration = %+v", configuration)
	}
	if err := st.FinishConfigurationSession(
		ctx, session.ID, session.Revision, "saved",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetActiveConfigurationSession(ctx, "C123"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("finished session remains active: %v", err)
	}
	latest, err := st.GetLatestConfigurationSession(ctx, "C123")
	if err != nil || latest.ID != session.ID || latest.Status != "saved" {
		t.Fatalf("latest session = %+v, %v", latest, err)
	}

	configuration.Participation = "shadow"
	configuration.ActorID = "U456"
	updated, err := st.SaveChannelConfiguration(ctx, configuration)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Revision != 2 || updated.Participation != "shadow" ||
		updated.ActorID != "U456" {
		t.Fatalf("updated configuration = %+v", updated)
	}
}
