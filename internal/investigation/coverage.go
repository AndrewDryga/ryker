package investigation

// NormalizeCoverageStatus retains the legacy "covered" value without turning
// it into an unsupported health claim. It means inspected, not healthy.
func NormalizeCoverageStatus(status string) string {
	if status == "covered" {
		return "unknown"
	}
	return status
}
