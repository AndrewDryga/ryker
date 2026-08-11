package service

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// channelPosters put a message where everyone in the room reads it.
//
// Each of these ends in store.EnqueueSlackDelivery or slack.Post against a
// channel. Nothing here can address one person: an ephemeral needs a user, and
// none of these takes one. That is the whole reason the list is the boundary
// this test guards — a sentence reaching any of them is a sentence the room
// gets.
var channelPosters = map[string]bool{
	"enqueue":                        true,
	"enqueueEpisode":                 true,
	"enqueueMessageUpdate":           true,
	"postInputNotice":                true,
	"postInputMessage":               true,
	"postInputMessageInSourceThread": true,
	"postInputMessageAt":             true,
	"postInputMessageAtEpisode":      true,
	"postInputMessageDelivery":       true,
	"postConfigurationMessage":       true,
	"postBehaviorReceipt":            true,
}

// noOpPhrases are how this codebase says that nothing happened.
//
// Every one is lifted from a message that was actually shipped and actually
// posted to a room: "no further action was needed", "Manual turn allocation is
// no longer required", "Nothing was stopped", "This memory entry was already
// removed". They are phrases rather than words because "already" alone matches
// prose that is carrying real news, and a guard that cries wolf gets deleted.
var noOpPhrases = []string{
	"no further action",
	"was not needed",
	"were not needed",
	"no longer required",
	"nothing was ",
	"nothing changed",
	"nothing remains",
	"nothing more to do",
	"nothing to do",
	"is already ",
	"are already ",
	"was already ",
	"were already ",
	"has already ",
	"have already ",
	"you’re already ",
	"you're already ",
	"already complete",
	"already saved",
	"already running",
	"no changed files",
	"there is nothing",
}

// TestNoOpSentencesCannotReachAChannel fails when a sentence that announces a
// no-op is written into a call that posts to a Slack channel.
//
// Six of those went out in two minutes when an operator cleared workspaces from
// the dashboard, in rooms where nobody had asked for anything, and not one
// carried news. The messages were individually defensible and collectively the
// reason a room learns to tune Responder out. Anything in this class belongs to
// the person who asked — ephemeral, or an error on the surface they asked from
// — and the audit row is the durable half.
//
// What this proves, exactly: no string literal matching the vocabulary above is
// passed to a channel-posting helper, either directly or through a local
// variable assigned a literal in the same function.
//
// What it does not prove, and cannot: real reachability. A no-op sentence
// returned by another function, built from a fmt verb whose format string is
// innocent, or carried in a slackui constructor's own text will pass this test.
// It is a spelling check over the shapes every regression in this class has
// actually taken, not a proof about the program. The regression tests in
// product_journey_test.go are what pin the behaviour; this stops the next
// person adding a fourteenth one by hand without noticing the pattern.
func TestNoOpSentencesCannotReachAChannel(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		fileSet := token.NewFileSet()
		parsed, err := parser.ParseFile(fileSet, path, source, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, declaration := range parsed.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || function.Body == nil {
				continue
			}
			bindings := stringBindings(function.Body)
			ast.Inspect(function.Body, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok || !postsToChannel(call) {
					return true
				}
				checked++
				text := strings.ToLower(callText(call, bindings))
				for _, phrase := range noOpPhrases {
					if !strings.Contains(text, phrase) {
						continue
					}
					t.Errorf(
						"%s:%d: %s posts %q to a channel, which says nothing happened.\n"+
							"Answer whoever asked instead: refuseControl for a control, "+
							"finishSlashInput for a command, or an error for the dashboard. "+
							"If this really is news to the room, widen noOpPhrases and say why.",
						path,
						fileSet.Position(call.Pos()).Line,
						function.Name.Name,
						phrase,
					)
					return true
				}
				return true
			})
		}
	}
	// A rename that quietly emptied channelPosters would leave this test
	// passing over nothing at all, which is the failure mode a guard like this
	// dies of. The floor is well under the real count and only has to prove the
	// walk still finds calls.
	if checked < 20 {
		t.Fatalf(
			"only %d channel-posting calls were found; channelPosters is stale "+
				"and this test is checking almost nothing",
			checked,
		)
	}
}

// postsToChannel reports whether this call is one of the channel posters,
// called as a method on the service.
func postsToChannel(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	receiver, ok := selector.X.(*ast.Ident)
	if !ok || receiver.Name != "s" {
		return false
	}
	return channelPosters[selector.Sel.Name]
}

// stringBindings collects `name := "literal"` and `name = "literal"` inside one
// function, so a message assembled into a variable one line above the post is
// read rather than missed. Concatenations count; anything else does not.
func stringBindings(body *ast.BlockStmt) map[string]string {
	bindings := map[string]string{}
	record := func(targets, values []ast.Expr) {
		for index, target := range targets {
			name, ok := target.(*ast.Ident)
			if !ok || index >= len(values) {
				continue
			}
			if text := literalText(values[index]); text != "" {
				bindings[name.Name] += " " + text
			}
		}
	}
	ast.Inspect(body, func(node ast.Node) bool {
		switch statement := node.(type) {
		case *ast.AssignStmt:
			record(statement.Lhs, statement.Rhs)
		case *ast.ValueSpec:
			targets := make([]ast.Expr, 0, len(statement.Names))
			for _, name := range statement.Names {
				targets = append(targets, name)
			}
			record(targets, statement.Values)
		}
		return true
	})
	return bindings
}

// callText is every string this call could be carrying: the literals in its
// argument subtree, plus the literals bound to any bare identifier it passes.
func callText(call *ast.CallExpr, bindings map[string]string) string {
	var parts []string
	for _, argument := range call.Args {
		ast.Inspect(argument, func(node ast.Node) bool {
			switch value := node.(type) {
			case *ast.BasicLit:
				if text := literalText(value); text != "" {
					parts = append(parts, text)
				}
			case *ast.Ident:
				if text, ok := bindings[value.Name]; ok {
					parts = append(parts, text)
				}
			}
			return true
		})
	}
	return strings.Join(parts, " ")
}

// literalText unquotes a string literal, or the literals in a concatenation of
// them, and reports "" for anything else.
func literalText(node ast.Expr) string {
	switch value := node.(type) {
	case *ast.BasicLit:
		if value.Kind != token.STRING {
			return ""
		}
		text, err := strconv.Unquote(value.Value)
		if err != nil {
			return ""
		}
		return text
	case *ast.BinaryExpr:
		if value.Op != token.ADD {
			return ""
		}
		return literalText(value.X) + literalText(value.Y)
	case *ast.ParenExpr:
		return literalText(value.X)
	}
	return ""
}
