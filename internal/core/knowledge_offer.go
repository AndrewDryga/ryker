package core

// A verified remediation is the most expensive thing this product produces and
// the shortest-lived. The fix is applied, the check passes, the channel moves
// on, and six weeks later the same alert is investigated from nothing by
// somebody reading the same dashboards. Phase 1 made the episode recallable;
// these two offers are how it stops being only a memory and becomes an artefact
// somebody else can run or read.
//
// Both are OFFERS in the exact sense the rest of this file uses the word. The
// model proposes, the host recomputes what it can and refuses what it cannot
// reproduce, and an operator confirms. Nothing is created before the click:
// no runbook draft in Emisar, no branch, no pull request.

// RunbookDraftOffer proposes that an action this episode ran and verified
// should become an Emisar runbook draft.
//
// The three refs are a CLAIM, exactly like GrantPromotionOffer.VerifiedSuccesses
// is a claim. The host holds the approval rows for this episode and builds the
// draft from those; an offer naming an action the record does not hold is
// refused rather than sent, because a runbook assembled from a model-invented
// action id is a document that looks authoritative and points at nothing. Any
// operator reading a draft is entitled to assume its steps were run.
//
// Slug and Title are the model's, bounded by Emisar's own schema, because they
// are the parts a human is best at and the host has no basis to invent.
type RunbookDraftOffer struct {
	Title string `json:"title"`
	Slug  string `json:"slug"`
	// Summary becomes the draft's description and the first line of its
	// context. It is prose about an incident and is treated as prose.
	Summary   string `json:"summary"`
	ActionID  string `json:"action_id"`
	PackRef   string `json:"pack_ref"`
	RunnerRef string `json:"runner_ref"`
	// Rationale is one operator-facing sentence for the confirmation card.
	Rationale string `json:"rationale,omitempty"`
}

// UnmarshalJSON accepts the names a model reaches for when it is describing a
// runbook rather than filling in this struct. Each names exactly one real field
// and nothing else in a runbook offer could be meant.
func (offer *RunbookDraftOffer) UnmarshalJSON(data []byte) error {
	type wire RunbookDraftOffer
	var value wire
	if err := DecodeModelObject(data, map[string]string{
		"name":        "title",
		"action":      "action_id",
		"description": "summary",
		"reason":      "rationale",
	}, &value); err != nil {
		return err
	}
	*offer = RunbookDraftOffer(value)
	return nil
}

// KnowledgeCardOffer proposes a `.agent/kb/` card recording what this episode
// established.
//
// It is the other half of the same loop and the cheaper one: not everything
// worth keeping is an action worth running. "The pool exhausts when the
// migration and the nightly export overlap" is not a runbook step, and today it
// survives only as prose in a Slack thread nobody will search.
//
// The card is a draft pull request and never anything else. Responder opens it;
// a person reads the diff and merges it, or does not. Body is model prose about
// content that arrived from Slack and an alert, so it lands in a file a reviewer
// reads before it lands anywhere a prompt reads.
type KnowledgeCardOffer struct {
	Slug  string `json:"slug"`
	Title string `json:"title"`
	// Body is the card's Markdown, without a heading: the host writes the
	// heading and the provenance block from what it recorded, so the two parts
	// a reader checks the card against cannot be authored by the thing being
	// checked.
	Body string `json:"body"`
	// Rationale is one operator-facing sentence for the confirmation card.
	Rationale string `json:"rationale,omitempty"`
}

// UnmarshalJSON accepts the two names a model is most likely to reach for.
func (offer *KnowledgeCardOffer) UnmarshalJSON(data []byte) error {
	type wire KnowledgeCardOffer
	var value wire
	if err := DecodeModelObject(data, map[string]string{
		"name":    "title",
		"content": "body",
		"reason":  "rationale",
	}, &value); err != nil {
		return err
	}
	*offer = KnowledgeCardOffer(value)
	return nil
}
