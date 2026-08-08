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
