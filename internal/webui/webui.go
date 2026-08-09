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
	"strings"
	"time"
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
}

var pages = []Page{
	{"", "Overview", "What is happening right now?"},
	{"episodes", "Episodes", "What did it do, and why?"},
	{"failures", "Failures", "What is broken, and can I retry it?"},
	{"decisions", "Decisions", "What did it choose, and was it right?"},
	{"audit", "Audit", "Who did what, and what came of it?"},
	{"memory", "Memory", "What does it believe, and where did that come from?"},
	{"configuration", "Configuration", "How is it set up?"},
	{"usage", "Usage", "What is it spending?"},
}

// Unwired marks a panel whose data does not exist yet.
//
// It renders as an explicit empty state naming what is missing and what would
// fill it, never as a zero or a plausible-looking estimate. This repository has
// twice shipped a check that reported success while not running — a deploy that
// announced an old binary as new, and a quality watcher that logged "no
// defects" for a day with a dead assessor. A panel that looks live and is not
// is the same defect in a nicer font.
type Unwired struct {
	Needs string
}

type Renderer struct {
	templates *template.Template
}

func NewRenderer() (*Renderer, error) {
	funcs := template.FuncMap{
		"since":    humanSince,
		"stamp":    humanStamp,
		"pct":      func(part, whole int) int { return percent(part, whole) },
		"truncate": func(limit int, value string) string { return truncate(value, limit) },
		"lower":    strings.ToLower,
	}
	parsed, err := template.New("webui").Funcs(funcs).ParseFS(assets, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse control plane templates: %w", err)
	}
	return &Renderer{templates: parsed}, nil
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
	Active  string
	Title   string
	Ask     string
	Deploy  string
	Content any
	Body    template.HTML
}

func NewShell(active, deployment string, content any) Shell {
	shell := Shell{Pages: pages, Active: active, Deploy: deployment, Content: content}
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
func humanStamp(value time.Time) string {
	if value.IsZero() {
		return "—"
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
	return strings.TrimRight(string(runes[:limit]), " ,;:-") + "…"
}

// Static serves the vendored stylesheet and htmx. Nothing is fetched from a CDN:
// the dashboard has to render with the network off, and no request about
// production work should leave the machine.
func Static() http.Handler {
	return http.FileServer(http.FS(assets))
}
