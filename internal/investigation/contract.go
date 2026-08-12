package investigation

import (
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigationcontract"
)

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
