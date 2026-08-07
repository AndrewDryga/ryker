package app

import (
	"bytes"
	"testing"
	"time"
)

func TestZZProbeRecord(t *testing.T) {
	var out, errOut bytes.Buffer
	start := time.Now()
	err := runRecordEpisode([]string{
		"--config", "/Users/andrewdryga/Projects/tenant/.responder/responder.yaml",
		"--episode", "episode_run_6b70093a69450d019d272fd88fd9f503",
		"--capability", "engineering-changes",
	}, &out, &errOut)
	t.Logf("runRecordEpisode took %v, err=%v, stdout=%d bytes", time.Since(start), err, out.Len())
	if errOut.Len() > 0 {
		t.Logf("stderr: %s", errOut.String()[:min(300, errOut.Len())])
	}
}
