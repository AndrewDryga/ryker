package investigation

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func promotionOperation(offer *core.GrantPromotionOffer) ResultOperation {
	return ResultOperation{ID: "grant-1", Type: "offer_grant_promotion", GrantOffer: offer}
}

func wellFormedOffer() *core.GrantPromotionOffer {
	return &core.GrantPromotionOffer{
		ActionID: "nomad.job.restart", PackRef: "nomad@1.4.0+sha256:1111",
		RunnerRef: "runner:prod-us-east", Rung: "propose", VerifiedSuccesses: 3,
	}
}

// TestAPromotionOfferMustNameAWholeActionIdentity is the validator's real job.
//
// A grant is authority over exactly one action id, from exactly one pack, on
// exactly one runner. An offer missing any of the three is not a slightly vague
// offer — it is one that, if stored, would match every other grant missing the
// same field. Refusing it here means the model is told which part is missing
// while it can still supply it.
func TestAPromotionOfferMustNameAWholeActionIdentity(t *testing.T) {
	for _, missing := range []struct {
		name   string
		mutate func(*core.GrantPromotionOffer)
	}{
		{"action_id", func(o *core.GrantPromotionOffer) { o.ActionID = "" }},
		{"pack_ref", func(o *core.GrantPromotionOffer) { o.PackRef = " " }},
		{"runner_ref", func(o *core.GrantPromotionOffer) { o.RunnerRef = "" }},
	} {
		t.Run(missing.name, func(t *testing.T) {
			offer := wellFormedOffer()
			missing.mutate(offer)
			err := promotionOperation(offer).Validate()
			if err == nil {
				t.Fatal("an offer with a partial action identity validated")
			}
			if !strings.Contains(err.Error(), missing.name) {
				t.Fatalf("the refusal %q does not name the missing %s", err, missing.name)
			}
		})
	}
}

// TestAPromotionOfferCannotAskForTheAutoRung is the seam guard where the model
// reads it.
//
// The auto rung is specified and not built: it needs a decision only the
// operator can make about how a host-side execution path should work. A model
// that keeps asking for it should be told why in the correction it actually
// reads, rather than having the offer quietly accepted and downgraded.
func TestAPromotionOfferCannotAskForTheAutoRung(t *testing.T) {
	offer := wellFormedOffer()
	offer.Rung = "auto"
	err := promotionOperation(offer).Validate()
	if err == nil {
		t.Fatal("an offer for the auto rung validated")
	}
	if !strings.Contains(err.Error(), "one_click") {
		t.Fatalf("the refusal %q does not name the highest grantable rung", err)
	}
}

func TestAPromotionOfferRungMustBeOnTheLadder(t *testing.T) {
	offer := wellFormedOffer()
	offer.Rung = "supervisor"
	if err := promotionOperation(offer).Validate(); err == nil {
		t.Fatal("an offer naming a rung off the ladder validated")
	}
	offer.Rung = "one_click"
	if err := promotionOperation(offer).Validate(); err != nil {
		t.Fatalf("a well-formed one_click offer was refused: %v", err)
	}
}

// TestAPromotionOfferIsOneTypedPayloadLikeEveryOtherOperation keeps the new
// operation inside the rule the whole vocabulary rests on. Missing the payload
// census entry is the classic way to add an operation whose validator never
// runs, because Validate rejects on "exactly one typed payload" first.
func TestAPromotionOfferIsOneTypedPayloadLikeEveryOtherOperation(t *testing.T) {
	if err := promotionOperation(wellFormedOffer()).Validate(); err != nil {
		t.Fatalf("a well-formed promotion offer was refused: %v", err)
	}
	empty := promotionOperation(nil)
	err := empty.Validate()
	if err == nil {
		t.Fatal("an offer_grant_promotion with no payload validated")
	}
	if !strings.Contains(err.Error(), "exactly one typed payload") {
		t.Fatalf("err=%q, want the payload-census rejection", err)
	}
	// And it must not be able to ride along with another payload.
	both := promotionOperation(wellFormedOffer())
	both.MemoryOffer = &core.MemoryOffer{Subject: "deploys"}
	if err := both.Validate(); err == nil {
		t.Fatal("a promotion offer carrying a second payload validated")
	}
}

// TestTheBarePromotionNounResolvesToItsVerb rides the same prefix rule every
// other operation gets. A model that writes the payload noun instead of the
// full verb form has lost whole responses to it three times in the recorded
// history, and this operation's noun is the one most likely to be reached for.
func TestTheBarePromotionNounResolvesToItsVerb(t *testing.T) {
	if resolved := resolveOperationType("grant_promotion"); resolved != "offer_grant_promotion" {
		t.Fatalf("resolveOperationType(%q) = %q, want the offer_ verb form", "grant_promotion", resolved)
	}
}
