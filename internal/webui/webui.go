// Package webui serves the Responder control plane.
//
// The Slack App Home answers "does anything need me right now?" and is good at
// it. It cannot answer "what happened, why, and what do I do about it", because
// Block Kit has no table, no sort, no filter and no pagination, and the content
// is lists of twenty-one blocked items and a hundred failures. This package is
// the workbench; Slack stays the alert. See docs/control-plane.md.
//
// Bound to loopback, and that is the whole of the trust model: no accounts, no
// roles, no tokens. Every design choice below follows from it — writes are
// individually opted in, secrets are redacted before they reach a template, and
// nothing is fetched from the network at render time.
package webui

import (
	"embed"
	"fmt"
	"html/template"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

//go:embed templates/*.html static/*
var assets embed.FS

// Page is one entry in the sidebar, and the question that page answers.
//
// The question is rendered, not just documentation. A dashboard section that
// cannot state what it is for is usually one that should not exist.
type Page struct {
	Slug     string
	Title    string
	Question string
	Group    string
}

var pages = []Page{
	{"", "Overview", "What is happening right now?", "Operate"},
	{"episodes", "Episodes", "What did it do, and why?", "Operate"},
	{"schedules", "Schedules", "What runs on its own, and did it?", "Operate"},
	{"channels", "Channels", "Where is Responder, and what is set up there?", "Operate"},
	{"failures", "Failures", "What is broken, and can I retry it?", "Operate"},
	{"workspaces", "Workspaces", "What is still held, and why?", "Operate"},
	{"decisions", "Decisions", "What did it choose, and was it right?", "Improve"},
	{"findings", "Findings", "What is wrong with Responder itself?", "Improve"},
	{"memory", "Memory", "What does it believe, and where did that come from?", "Improve"},
	{"audit", "Audit", "Who did what, and what came of it?", "System"},
	{"configuration", "Configuration", "How is it set up?", "System"},
	{"usage", "Usage", "What is it spending?", "System"},
}

// NavGroup is one titled section of the sidebar. Ten flat entries read as a
// list to memorize; three named sections read as a mental model — operate the
// work, improve the behaviour, inspect the system.
type NavGroup struct {
	Name  string
	Pages []Page
}

func navGroups() []NavGroup {
	groups := []NavGroup{}
	for _, page := range pages {
		if len(groups) == 0 || groups[len(groups)-1].Name != page.Group {
			groups = append(groups, NavGroup{Name: page.Group})
		}
		last := len(groups) - 1
		groups[last].Pages = append(groups[last].Pages, page)
	}
	return groups
}

// Unwired marks a panel whose data does not exist.
//
// It renders as an explicit empty state naming what is missing and what would
// fill it, never as a zero or a plausible-looking estimate. This repository has
// twice shipped a check that reported success while not running — a deploy that
// announced an old binary as new, and a quality watcher that logged "no
// defects" for a day with a dead assessor. A panel that looks live and is not
// is the same defect in a nicer font.
//
// Tag overrides the default "Not recorded yet", because that phrase claims the
// product is missing a pipe. Once token usage and the effective target began
// being recorded, the same phrase over an attempt frozen before the change
// reported a fixed gap as an open one, and would send someone to plumb what is
// already plumbed. "Not recorded for this attempt" is the honest version.
type Unwired struct {
	Tag   string
	Needs string
}

type Renderer struct {
	templates *template.Template
}

func NewRenderer() (*Renderer, error) {
	funcs := template.FuncMap{
		"since":    humanSince,
		"until":    humanUntil,
		"stamp":    humanStamp,
		"pct":      func(part, whole int) int { return percent(part, whole) },
		"kib":      humanKiB,
		"truncate": func(limit int, value string) string { return truncate(value, limit) },
		"lower":    strings.ToLower,
		"add1":     func(value int) int { return value + 1 },
		// dict builds the argument for a sub-template that needs more than one
		// value. Only the channel settings control uses it: three buttons per
		// row differing by one field each, which is a partial rather than three
		// copies of the same form.
		"dict": func(pairs ...any) map[string]any {
			out := make(map[string]any, len(pairs)/2)
			for index := 0; index+1 < len(pairs); index += 2 {
				key, _ := pairs[index].(string)
				out[key] = pairs[index+1]
			}
			return out
		},
		"tokens":  humanTokens,
		"exact":   groupDigits,
		"confirm": confirmStep,
		"meter":   meterSVG,
		"mrkdwn":  renderMrkdwn,
		"summary": renderSummary,
		"bytes":   HumanBytes,
	}
	parsed, err := template.New("webui").Funcs(funcs).ParseFS(assets, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse control plane templates: %w", err)
	}
	return &Renderer{templates: parsed}, nil
}

var (
	mrkdwnBoldMd    = regexp.MustCompile(`\*\*([^*\n]+)\*\*`)
	mrkdwnBoldSlack = regexp.MustCompile(`\*([^*\n]+)\*`)
	// One pattern for every span that is not bold, alternated in priority
	// order and matched in a single pass.
	//
	// Priority is the whole point. Code spans used to be resolved first, in
	// their own pass, and links second within each gap between them — so a
	// link whose label contained a code span was cut in half before anything
	// looked for it. Model prose does that constantly, and the reader got a
	// literal "[brief `sdb` latency spike](" followed by an anchor whose href
	// carried the closing bracket. One pass, links first, cannot split.
	mrkdwnSpan = regexp.MustCompile(
		"\\[([^\\[\\]\n]+)\\]\\((https?://[^\\s()]+)\\)" + // [label](url)
			"|`([^`\n]+)`" + // `code`
			"|(https?://[^\\s<>\"]+)") // a bare URL
)

// renderMrkdwn renders the safe subset of the markup model prose actually
// carries — `code` spans, bold in both the model's **markdown** and Slack's
// *mrkdwn* spelling, and [text](https://…) links — instead of printing the
// punctuation literally. The text is HTML-escaped before any tag is inserted;
// the inserted tags are the fixed <code> and <strong> pairs plus an anchor
// whose href comes from the already-escaped match and must start with
// http(s)://, so nothing in the text can become markup or a javascript: URL.
// Italics are deliberately not rendered: identifiers like claim_id are
// everywhere in this prose and underscores inside them are not emphasis.
func renderMrkdwn(text string) template.HTML { return mrkdwnHTML(text, true) }

// renderSummary is renderMrkdwn for prose that sits inside a link — a list row
// is one click target, and an anchor nested in an anchor is invalid HTML that
// browsers repair by closing the outer one, which tore the row's own layout
// open around the paragraph. Link labels keep their words and lose their href;
// the row's destination is the only thing worth clicking there anyway.
func renderSummary(text string) template.HTML { return mrkdwnHTML(text, false) }

func mrkdwnHTML(text string, links bool) template.HTML {
	escaped := template.HTMLEscapeString(text)
	var out strings.Builder
	last := 0
	for _, span := range mrkdwnSpan.FindAllStringSubmatchIndex(escaped, -1) {
		out.WriteString(mrkdwnBold(escaped[last:span[0]]))
		out.WriteString(mrkdwnSpanHTML(escaped, span, links))
		last = span[1]
	}
	out.WriteString(mrkdwnBold(escaped[last:]))
	return template.HTML(strings.ReplaceAll(out.String(), "\n", "<br>")) //nolint:gosec // escaped above; only fixed tags inserted
}

// mrkdwnSpanHTML renders whichever alternative of mrkdwnSpan matched. The
// group indexes are the alternation's, in order: link label, link href, code
// body, bare URL.
func mrkdwnSpanHTML(escaped string, span []int, links bool) string {
	group := func(n int) string {
		if span[2*n] < 0 {
			return ""
		}
		return escaped[span[2*n]:span[2*n+1]]
	}
	if href := group(2); href != "" {
		// A link's label is prose of its own and keeps its code and bold.
		label := mrkdwnBold(mrkdwnCodeSpans(group(1)))
		if !links {
			return label
		}
		return anchor(href, label)
	}
	if code := group(3); code != "" {
		return "<code>" + code + "</code>"
	}
	// A bare URL. Neither the sentence's closing punctuation nor the escaped
	// ">" of Slack's <url|label> spelling is part of it.
	href := group(4)
	if cut, _, found := strings.Cut(href, "&gt;"); found {
		href = cut
	}
	trimmed := strings.TrimRight(href, ".,;:!?")
	tail := strings.TrimPrefix(href, trimmed)
	if !links {
		// A naked URL in a list row is a wall of characters standing where a
		// sentence should be. Its host is the part that means anything.
		return mrkdwnHost(trimmed) + tail
	}
	return anchor(trimmed, trimmed) + tail
}

// mrkdwnHost shortens a URL to its host for prose that cannot link. The whole
// URL is still one click away on the episode's own page.
func mrkdwnHost(url string) string {
	rest := strings.TrimPrefix(strings.TrimPrefix(url, "https://"), "http://")
	host, _, _ := strings.Cut(rest, "/")
	if host == "" {
		return url
	}
	return "<span class=\"link-host\">" + host + "</span>"
}

func anchor(href, label string) string {
	return `<a href="` + href + `" target="_blank" rel="noopener noreferrer">` + label + `</a>`
}

func mrkdwnCodeSpans(text string) string {
	return mrkdwnCode.ReplaceAllString(text, "<code>$1</code>")
}

var mrkdwnCode = regexp.MustCompile("`([^`\n]+)`")

func mrkdwnBold(text string) string {
	text = mrkdwnBoldMd.ReplaceAllString(text, "<strong>$1</strong>")
	return mrkdwnBoldSlack.ReplaceAllString(text, "<strong>$1</strong>")
}

// meterSVG is the proportional bar every table can put beside a share or a
// count: sixty-four units wide, filled to the percentage. It is built from
// clamped integers only, so returning pre-rendered HTML cannot carry input.
// A non-zero value keeps a visible two-unit sliver — a real quantity must not
// round away to nothing, in ink any more than in text.
func meterSVG(pct int) template.HTML {
	pct = min(max(pct, 0), 100)
	width := pct * 64 / 100
	if pct > 0 && width < 2 {
		width = 2
	}
	return template.HTML(fmt.Sprintf(
		`<svg class="meter" width="64" height="5" viewBox="0 0 64 5" aria-hidden="true">`+
			`<rect class="meter-bg" width="64" height="5" rx="2.5"/>`+
			`<rect class="meter-fg" width="%d" height="5" rx="2.5"/></svg>`, width))
}

// confirmStep feeds the "confirm" partial: a native <details> disclosure whose
// real submit button does not exist on the page until the operator opens it.
//
// It replaces onclick="return confirm(...)", which never ran: this dashboard's
// CSP is default-src 'none' with no script-src, so browsers refuse inline
// handlers — every destructive button fired on first click while looking
// guarded. A safety step that looks present and is not is the same defect as a
// live-looking button that does nothing, aimed the other way.
func confirmStep(label, ask, sure, action, id string) map[string]string {
	return map[string]string{
		"Label": label, "Ask": ask, "Sure": sure, "Action": action, "ID": id,
	}
}

// Render writes one page inside the shared shell.
//
// The body is rendered first and only then wrapped, so a template failure is
// reported as an error rather than sent as a half-written page. A dashboard
// that stops mid-render is indistinguishable from a system with missing data,
// which is the confusion this package exists to end.
func (r *Renderer) Render(w http.ResponseWriter, body string, shell Shell) {
	var content strings.Builder
	if err := r.templates.ExecuteTemplate(&content, body, shell.Content); err != nil {
		http.Error(w, "render "+body+": "+err.Error(), http.StatusInternalServerError)
		return
	}
	shell.Body = template.HTML(content.String()) //nolint:gosec // rendered by our own templates, which escape their inputs
	var page strings.Builder
	if err := r.templates.ExecuteTemplate(&page, "layout", shell); err != nil {
		http.Error(w, "render layout: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(page.String()))
}

// Shell is the frame every page shares.
type Shell struct {
	Pages   []Page
	Nav     []NavGroup
	Active  string
	Title   string
	Ask     string
	Deploy  string
	Content any
	Body    template.HTML

	// The persistent answer to "what am I looking at, and is it alive". Health
	// used to live only on Overview, which left every other page context-free.
	Binary   string
	Schema   string
	Ready    bool
	NotReady string

	// Badges put the one number that would make someone open a page beside its
	// name — needs-you on Overview, failures on Failures, corrections on
	// Decisions. Keyed by slug; a zero renders nothing, because a zero badge is
	// decoration.
	Badges map[string]Badge

	// Detail pages title themselves after the entity and point back at their
	// section. With the section name as the h1, an episode page was headed
	// "Episodes" and its actual subject was buried in a panel below.
	Crumbs        []Crumb
	TitleOverride string

	// Refresh reloads the page after this many seconds. Only Overview sets it:
	// a "what is happening right now" page that changes only on manual reload
	// is a snapshot pretending to be live, and this dashboard allows no
	// JavaScript, so the meta tag is the whole mechanism.
	Refresh int
}

type Badge struct {
	N    int
	Warn bool
}

type Crumb struct {
	Href  string
	Label string
}

// HeadTitle is the browser-tab line: the entity when there is one, then the
// section, then the deployment — so ten open tabs stay tellable apart.
func (s Shell) HeadTitle() string {
	title := s.Title
	if s.TitleOverride != "" {
		title = s.TitleOverride
	}
	if len(title) > 60 {
		title = truncate(title, 60)
	}
	return title + " · " + s.Deploy + " · Responder"
}

func NewShell(active, deployment string, content any) Shell {
	shell := Shell{Pages: pages, Nav: navGroups(), Active: active, Deploy: deployment, Content: content}
	for _, page := range pages {
		if page.Slug == active {
			shell.Title = page.Title
			shell.Ask = page.Question
		}
	}
	return shell
}

// humanStamp refuses to print a zero time as a date.
//
// An attempt that was cancelled before it began has no started_at, and
// formatting the zero value put "0001-01-01 00:00 UTC" in the Started column —
// a timestamp that looks like a fact and is the absence of one. Same rule as
// every other panel here: nothing invented where there is no data.
// It refuses to print the permanent-expiry sentinel as a date for the same
// reason: "9999-12-31 23:59 UTC" is not what a row that never expires means,
// and the Expires column is where an operator looks to find out.
func humanStamp(value time.Time) string {
	switch {
	case value.IsZero():
		return "—"
	case core.IsPermanentExpiry(value):
		return core.NeverExpires
	}
	return value.UTC().Format("2006-01-02 15:04 UTC")
}

func humanSince(value time.Time) string {
	if value.IsZero() {
		return "never"
	}
	elapsed := time.Since(value)
	switch {
	case elapsed < time.Minute:
		return "just now"
	case elapsed < time.Hour:
		return fmt.Sprintf("%dm ago", int(elapsed.Minutes()))
	case elapsed < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(elapsed.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(elapsed.Hours()/24))
	}
}

// humanUntil describes a deadline rather than an observation. Reusing
// humanSince for future schedule times made every task, however distant, say
// "just now" because a negative elapsed duration satisfies elapsed < minute.
func humanUntil(value time.Time) string {
	if value.IsZero() {
		return "not scheduled"
	}
	remaining := time.Until(value)
	if remaining <= 0 {
		overdue := -remaining
		switch {
		case overdue < time.Minute:
			return "due now"
		case overdue < time.Hour:
			return fmt.Sprintf("overdue by %dm", int(overdue.Minutes()))
		case overdue < 24*time.Hour:
			return fmt.Sprintf("overdue by %dh", int(overdue.Hours()))
		default:
			return fmt.Sprintf("overdue by %dd", int(overdue.Hours()/24))
		}
	}
	switch {
	case remaining < time.Minute:
		return "in less than a minute"
	case remaining < time.Hour:
		return fmt.Sprintf("in %dm", int(remaining.Minutes()))
	case remaining < 24*time.Hour:
		return fmt.Sprintf("in %dh", int(remaining.Hours()))
	default:
		return fmt.Sprintf("in %dd", int(remaining.Hours()/24))
	}
}

func percent(part, whole int) int {
	if whole == 0 {
		return 0
	}
	return part * 100 / whole
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	cut := string(runes[:limit])
	// Break on a word when one is near: "…overdue for 24h FI…" reads as
	// corruption, and the two letters the hard cut saves are not worth it.
	if space := strings.LastIndex(cut, " "); space > limit*2/3 {
		cut = cut[:space]
	}
	return strings.TrimRight(cut, " ,;:-") + "…"
}

// Static serves the vendored stylesheet and htmx. Nothing is fetched from a CDN:
// the dashboard has to render with the network off, and no request about
// production work should leave the machine.
func Static() http.Handler {
	return http.FileServer(http.FS(assets))
}
