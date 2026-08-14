package service

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/localstate"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A Slack write that skips the delivery queue still spends the channel's
// posting budget, and the queue has to know.
//
// It did not. Only processSlackDelivery recorded, so the pacer's picture of a
// room was the queue's own traffic; an ephemeral refusal, an abandoned-request
// notice or a setup question posted straight from the interaction handler was
// invisible to it. The queue then read the channel as free, posted on top of a
// write Slack had just taken, and the second one is the one Slack rate-limits.
func TestUnqueuedSlackWriteSpendsTheChannelPacingBudget(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)

	body, err := slackui.Encode(slackui.Notice("the queued answer"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_answer_1", Operation: "post", Kind: "notice",
		ChannelID: "CROOM", ThreadTS: "1700.001", Body: body,
	}); err != nil {
		t.Fatal(err)
	}

	// Refusing someone is a chat.postEphemeral into CROOM. It never enters the
	// delivery queue, and it is the exact shape of write the pacer used to miss.
	svc.denyInput(ctx, core.SlackInput{
		ID: "in_denied", ChannelID: "CROOM", UserID: "U1",
	}, "this channel is not configured for that")
	if len(slack.ephemerals) != 1 || slack.ephemerals[0].channel != "CROOM" {
		t.Fatalf("refusal ephemerals = %+v", slack.ephemerals)
	}

	err = svc.processSlackWrite(ctx)
	var deferral scheduledWorkDeferral
	if !errors.As(err, &deferral) {
		t.Fatalf(
			"queued write straight after an unqueued ephemeral = %v, posts %+v; want the "+
				"queue to see CROOM cooling",
			err, slack.posts,
		)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("the queue posted into a channel it had just spent: %+v", slack.posts)
	}

	// Once the interval has passed the channel is the queue's again.
	clock.Advance(localstate.SlackWriteInterval)
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || slack.posts[0].channel != "CROOM" {
		t.Fatalf("the cooled channel did not resume: %+v", slack.posts)
	}
}

// slackOptionalCapabilities names every Slack method a service path may reach by
// type assertion, past the channel-write pacer.
//
// These are the capabilities that are not on slackui.API, so the pacer wrapper
// does not carry them and unpacedSlack has to look underneath. That is a hole
// in the chokepoint by construction, and this list is what keeps it a small
// known one: adding a capability here is the moment to ask whether it spends a
// channel's message-posting budget, because if it does it belongs in
// slackui.API and in localstate's channelPostingArgument instead.
var slackOptionalCapabilities = map[string]string{
	"React":        "reactions.add is workspace-tier and does not compete with chat.postMessage",
	"Unreact":      "reactions.remove, same tier as reactions.add",
	"UserTimezone": "a read of the operator's Slack profile",
	"ListChannels": "a read of the workspace channel list",
	// chat.delete removes a message rather than adding one, and it is not on
	// the per-channel posting limit chat.postMessage competes for. It is also
	// self-limiting in a way the posting methods are not: it can only be
	// reached by pressing a control on a message that already exists, and the
	// press deletes that message.
	"Delete": "chat.delete removes a message and does not spend the posting budget",
}

// Nothing may reach the Slack client for a write that the pacer cannot see.
//
// The pacer only works because the service holds it as its only Slack client.
// A type assertion straight onto s.slack looks past it, and a posting method
// reached that way would be exactly the invisible write this whole change
// exists to remove — so assertions have to go through unpacedSlack, and what
// they may ask for has to be named above.
func TestSlackOptionalCapabilitiesDoNotBypassPacing(t *testing.T) {
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	files := make(map[string]*ast.File)
	fset := token.NewFileSet()
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		parsed, parseErr := parser.ParseFile(fset, path, nil, 0)
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		files[path] = parsed
	}
	if len(files) == 0 {
		t.Fatal("no service sources were parsed; this guard would pass vacuously")
	}
	named := namedInterfaceMethods(files)
	found := 0
	for path, file := range files {
		ast.Inspect(file, func(node ast.Node) bool {
			assertion, ok := node.(*ast.TypeAssertExpr)
			if !ok || assertion.Type == nil {
				return true
			}
			line := fset.Position(assertion.Pos()).Line
			if isSlackClientSelector(assertion.X) {
				t.Errorf(
					"%s:%d asserts on the Slack client directly; reach optional "+
						"capabilities through unpacedSlack so the pacing chokepoint stays "+
						"the only way a write reaches Slack",
					path, line,
				)
				return true
			}
			if !isUnpacedSlackCall(assertion.X) {
				return true
			}
			found++
			for _, method := range assertedMethods(assertion.Type, named) {
				if _, allowed := slackOptionalCapabilities[method]; !allowed {
					t.Errorf(
						"%s:%d reaches past the pacer for %s. If it spends a channel's "+
							"message-posting budget it belongs on slackui.API where the pacer "+
							"records it; if it does not, add it to slackOptionalCapabilities "+
							"with the reason",
						path, line, method,
					)
				}
			}
			return true
		})
	}
	// Every allowlisted capability is reached from somewhere today. If that stops
	// being true the list is stale, and a stale allowlist is how a guard quietly
	// stops guarding.
	if found < len(slackOptionalCapabilities) {
		t.Errorf(
			"found %d assertions past the pacer for %d allowlisted capabilities; "+
				"either a call site was rewritten or this guard is no longer looking at anything",
			found, len(slackOptionalCapabilities),
		)
	}
}

// namedInterfaceMethods maps this package's named interface types to their
// method names, so an assertion written as a named type resolves like an inline
// one.
func namedInterfaceMethods(files map[string]*ast.File) map[string][]string {
	named := make(map[string][]string)
	for _, file := range files {
		ast.Inspect(file, func(node ast.Node) bool {
			spec, ok := node.(*ast.TypeSpec)
			if !ok {
				return true
			}
			definition, isInterface := spec.Type.(*ast.InterfaceType)
			if !isInterface {
				return true
			}
			named[spec.Name.Name] = interfaceMethodNames(definition)
			return true
		})
	}
	return named
}

func interfaceMethodNames(definition *ast.InterfaceType) []string {
	var methods []string
	for _, field := range definition.Methods.List {
		for _, name := range field.Names {
			methods = append(methods, name.Name)
		}
	}
	return methods
}

func assertedMethods(expr ast.Expr, named map[string][]string) []string {
	switch shape := expr.(type) {
	case *ast.InterfaceType:
		return interfaceMethodNames(shape)
	case *ast.Ident:
		return named[shape.Name]
	}
	return nil
}

func isSlackClientSelector(expr ast.Expr) bool {
	selector, ok := expr.(*ast.SelectorExpr)
	return ok && selector.Sel != nil && selector.Sel.Name == "slack"
}

func isUnpacedSlackCall(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	ident, isIdent := call.Fun.(*ast.Ident)
	return isIdent && ident.Name == "unpacedSlack"
}

// The guard above reads this package's sources from the test's working
// directory. If that ever stops being the package directory it would find
// nothing and pass, so check the assumption rather than trust it.
func TestSlackPacingGuardReadsThisPackage(t *testing.T) {
	if _, err := os.Stat("slack_pacing.go"); err != nil {
		t.Fatalf("the pacing guard cannot see its own package sources: %v", err)
	}
}
