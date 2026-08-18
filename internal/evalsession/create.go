// Package evalsession owns bounded Coop session preparation for live model
// evaluations.
package evalsession

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/serviceport"
)

// Create resumes the same durable create after Coop's transport handoff. Live
// workers get that resubmission from their scheduler; one evaluation case owns
// its context directly and therefore has to resume it here.
func Create(
	ctx context.Context,
	client serviceport.Coop,
	key string,
	policy string,
	externalRef string,
	retryInterval time.Duration,
) (coop.Session, coop.Operation, error) {
	if retryInterval <= 0 {
		retryInterval = 500 * time.Millisecond
	}
	for {
		session, operation, err := client.CreateSession(ctx, key, policy, externalRef)
		if err == nil {
			return session, operation, nil
		}
		var pending *coop.OperationPendingError
		if !errors.As(err, &pending) {
			return session, operation, err
		}
		timer := time.NewTimer(retryInterval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return session, operation, fmt.Errorf(
				"workspace preparation did not finish before the evaluation case deadline: %w",
				ctx.Err(),
			)
		case <-timer.C:
		}
	}
}
