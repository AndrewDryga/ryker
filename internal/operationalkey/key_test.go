package operationalkey

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
)

// The generic Host OOM Grafana rule fired for a website worker at 04:44 and
// VictoriaLogs at 16:30. Both cards had the same alert URL and host, so they
// shared an episode and model session; the later investigation answered with
// the earlier process. One alert occurrence is one unit of model context.
func TestGrafanaAlertOccurrencesDoNotShareModelContext(t *testing.T) {
	website := core.SlackInput{
		Kind: "bot_message", UserID: "BGRAFANA",
		Text: "<https://grafana.example/alerting/grafana/va1-host-oom/view?orgId=1|[VA1 FIRING:1] WARNING | Host OOM kills>\n" +
			"*FIRING - 1 alert*\n*Service:* `cluster`\n*Component:* `node-exporter`\n" +
			"*Instance:* `nomad-hvn01`\n" +
			"*Started:* <!date^1787201090^{date_short_pretty} at {time_secs}|2026-08-20 04:44:50 UTC>",
	}
	victoriaLogs := website
	victoriaLogs.Text = strings.ReplaceAll(victoriaLogs.Text, "1787201090", "1787243450")
	victoriaLogs.Text = strings.ReplaceAll(victoriaLogs.Text, "04:44:50", "16:30:50")

	if Key(website) == Key(victoriaLogs) {
		t.Fatal("separate Host OOM occurrences shared one operational identity")
	}

	recovered := victoriaLogs
	recovered.Text = strings.ReplaceAll(recovered.Text, "FIRING", "RESOLVED")
	if got, want := Key(recovered), Key(victoriaLogs); got != want {
		t.Fatalf("one Host OOM occurrence changed identity on recovery: got %q, want %q", got, want)
	}
}
