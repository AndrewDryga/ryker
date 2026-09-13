package httpapi

import (
	"strings"
	"testing"
)

// The dashboard served every page as unstyled HTML while returning 200,
// because one Content-Security-Policy covered both surfaces and the API's
// default-src 'none' blocked the dashboard's own stylesheet. Only the browser
// could see it; the server reported success. This pins both halves.
func TestContentSecurityPolicySuitsEachSurface(t *testing.T) {
	for _, path := range []string{"/healthz", "/readyz", "/metrics", "/v1/hooks/grafana"} {
		policy := contentSecurityPolicy(path)
		if policy != "default-src 'none'; frame-ancestors 'none'" {
			t.Errorf("API path %s should stay fully locked down, got %q", path, policy)
		}
	}

	for _, path := range []string{"/", "/episodes", "/episodes/ep_1", "/usage", "/static/app.css"} {
		policy := contentSecurityPolicy(path)
		if !strings.Contains(policy, "style-src 'self'") {
			t.Errorf("dashboard path %s cannot load its stylesheet: %q", path, policy)
		}
		// The stylesheet self-hosts its display faces. Without font-src the
		// browser falls back to the system stack silently — the page renders,
		// the server reports success, and only a screenshot shows the loss.
		if !strings.Contains(policy, "font-src 'self'") {
			t.Errorf("dashboard path %s cannot load its own fonts: %q", path, policy)
		}
		// Same-origin styles and images only. Everything else stays refused,
		// including the scripts a server-rendered page has no use for.
		for _, forbidden := range []string{"script-src", "'unsafe-inline'", "http:", "https:", "*"} {
			if strings.Contains(policy, forbidden) {
				t.Errorf("dashboard policy admits %q: %q", forbidden, policy)
			}
		}
		for _, required := range []string{"default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'"} {
			if !strings.Contains(policy, required) {
				t.Errorf("dashboard policy dropped %q: %q", required, policy)
			}
		}
	}
}

// The dashboard introduces its deployment by name. The naive derivation
// stopped at the dot-directory, and every page header said ".ryker" — the
// name of the convention, not of anything running.
func TestDeploymentNameSkipsTheDotDirectory(t *testing.T) {
	for _, testCase := range []struct{ in, want string }{
		{"/Users/x/Projects/blitz/.ryker/state", "blitz"},
		{"/Users/x/Projects/os/emisar/.ryker/state", "emisar"},
		{"/srv/ryker/state", "ryker"},
		{"", "ryker"},
	} {
		if got := deploymentName(testCase.in); got != testCase.want {
			t.Errorf("deploymentName(%q) = %q, want %q", testCase.in, got, testCase.want)
		}
	}
}
