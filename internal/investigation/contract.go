package investigation

import (
	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigationcontract"
)

// PublishedArtifactCompletionCriterion is a host-authored machine marker on an
// episode whose requested outcome applies to future runs. It lives in the
// existing persisted completion-criteria list so child episodes can inherit it
// without inferring publication intent from model prose.
const PublishedArtifactCompletionCriterion = completionpolicy.PublishedArtifactCriterion

const Version = investigationcontract.Version

type FreshnessRequirement = investigationcontract.FreshnessRequirement
type ClaimRequirement = investigationcontract.ClaimRequirement
type CompletionRule = investigationcontract.CompletionRule
type InvestigationContract = investigationcontract.InvestigationContract

func ValidCoverageLayer(value string) bool {
	return investigationcontract.ValidCoverageLayer(value)
}

func Compile(episode core.WorkEpisode) InvestigationContract {
	return investigationcontract.Compile(episode)
}

func ReusableArtifactAuthoring(text string) bool {
	return investigationcontract.ReusableArtifactAuthoring(text)
}

func SourcePolicy() string {
	return investigationcontract.SourcePolicy()
}
