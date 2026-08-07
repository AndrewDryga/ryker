// Package internal holds the architecture invariants that no single package
// can check for itself: which packages may import which, and how large the two
// broad types are allowed to be.
//
// These are ratchets, not aspirations. The budgets are set just above today's
// counts so ordinary work is unaffected, but growing Service or Store further
// requires deliberately raising a number in this file — which is the moment to
// extract a sub-package instead. Lowering a budget after an extraction is
// always welcome and never needs discussion.
package internal_test

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

const modulePath = "github.com/AndrewDryga/responder/"

// methodBudget caps the *exported* receiver-method count of the two broad
// types. Exported methods are the surface other packages depend on, and that
// surface is what makes a type hard to split. Unexported helpers are excluded
// deliberately: turning a free function into a method to give it access to the
// injected clock is a refactor, not new API, and should not trip this budget.
// See the package comment: raising an entry is a decision, not a formality.
var methodBudget = map[string]int{
	"Service": 12,
	// Raised from 290 for the standing-assignment layer: seven methods for a
	// capability that did not exist, in its own file, with its own tests. That
	// is feature growth rather than the drift this budget exists to catch —
	// see the package comment. The next raise should come with an extraction.
	"Store": 300,
}

// lineBudget caps non-test source lines per package.
//
// internal/service is over any reasonable size and the budget only stops it
// drifting further. Every entry here is a ratchet: lower it when a package
// shrinks, in the same commit, so the number tracks reality rather than
// becoming a floor to grow into. Raising one is a decision that needs a reason
// written beside it — that has happened once, during the decision-logic
// refactors, and was earned back by extracting internal/localstate.
//
// The identified extraction is the offline evaluation family
// — live_evaluation.go, evaluation.go, evaluation_quality.go,
// scenario_evaluation.go, and quality_calibration.go, together 3,759 lines with
// zero *Service methods, none of which runs in the service at all.
//
// It cannot move yet: those files reference 57 unexported service symbols,
// mostly the watch-decision and agent-report types and their validators.
// Exporting all 57 would widen the package's API instead of narrowing it, so
// the decision domain has to become its own package first. That is the next
// extraction, and this number comes down again when it lands.
//
// The process-local coordination state moved to internal/localstate, which is
// how this budget came back to 28000 after the decision-logic refactors.
//
// A note on margin, learned twice the hard way: a budget set near the exact
// current count is a tripwire, not a ratchet. The next legitimate feature trips
// it, and the pressure to "just bump it" is highest precisely when the change
// is justified — which is how a guard becomes a rubber stamp.
//
// These numbers exist to stop DRIFT, not to tax features. The working rule:
// leave a few hundred lines of margin, tighten hard after an extraction, and
// leave it alone while features land. The guard has done its job — it forced
// internal/localstate, internal/provider and internal/recall out of this
// package rather than letting it absorb them — and it only keeps working if
// tripping it means something.
// Re-baselined when the count switched from every line to code lines only.
// Each is roughly 5% above today's count: enough that ordinary work never
// touches it, little enough that a package quietly absorbing a new
// responsibility does.
var lineBudget = map[string]int{
	"service":    24400,
	"store":      14000,
	"localstate": 400,
	"provider":   120,
	"recall":     400,
	// channelsetup reads what an operator is asking for about a channel.
	"channelsetup": 235,
	// memory owns what may be remembered, for how long, and who may see it.
	"memory": 364,
	// schedule owns recurrence arithmetic and schedule validation.
	"schedule": 291,
	// publication tracks a published PR through checks, merge and deployment.
	"publication": 392,
	// decision owns the shapes a model result arrives in and the rules for
	// reading one, so the evaluation family can reach them without the runtime.
	"decision": 2161,
	// investigation owns the contract and, since the completion validators moved
	// beside it, the rules that check a result against that contract.
	"investigation": 1800,
}

// forbiddenImports records the dependency direction. Each package maps to the
// internal packages it must never import, keeping the layering acyclic and
// stopping the domain and persistence layers from depending on presentation.
var forbiddenImports = map[string][]string{
	"core":          {"config", "coop", "emisar", "publisher", "service", "slackui", "store", "webhook", "httpapi", "app"},
	"store":         {"service", "slackui", "publisher", "httpapi", "app", "emisar"},
	"slackui":       {"service", "store", "httpapi", "app", "publisher"},
	"coop":          {"service", "store", "slackui", "httpapi", "app"},
	"emisar":        {"service", "store", "slackui", "httpapi", "app"},
	"webhook":       {"service", "store", "slackui", "httpapi", "app"},
	"episode":       {"service", "store", "slackui", "httpapi", "app"},
	"investigation": {"service", "store", "slackui", "httpapi", "app"},
	"decision":      {"service", "store", "httpapi", "app", "publisher", "coop"},
	"publication":   {"service", "httpapi", "app", "coop", "decision"},
	"schedule":      {"service", "store", "httpapi", "app", "coop", "publisher", "slackui"},
	"memory":        {"service", "httpapi", "app", "coop", "publisher", "slackui"},
	"channelsetup":  {"service", "store", "httpapi", "app", "coop", "publisher"},
	"publisher":     {"service", "store", "slackui", "httpapi", "app"},
	"localstate":    {"service", "store", "httpapi", "app", "publisher", "coop", "config"},
	"provider":      {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "core"},
	"recall":        {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config"},
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// goPackages walks internal/ and returns each package's non-test files.
func goPackages(t *testing.T) map[string][]string {
	t.Helper()
	root := filepath.Join(repoRoot(t), "internal")
	packages := make(map[string][]string)
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		name := filepath.Base(filepath.Dir(path))
		packages[name] = append(packages[name], path)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return packages
}

func TestPackageDependencyDirection(t *testing.T) {
	packages := goPackages(t)
	for name, forbidden := range forbiddenImports {
		files, ok := packages[name]
		if !ok {
			t.Fatalf("package %q named in forbiddenImports no longer exists; update this test", name)
		}
		banned := make(map[string]bool, len(forbidden))
		for _, item := range forbidden {
			banned[item] = true
		}
		for _, path := range files {
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				t.Fatal(err)
			}
			for _, spec := range file.Imports {
				value, err := strconv.Unquote(spec.Path.Value)
				if err != nil {
					t.Fatal(err)
				}
				if !strings.HasPrefix(value, modulePath+"internal/") {
					continue
				}
				imported := strings.TrimPrefix(value, modulePath+"internal/")
				if banned[imported] {
					t.Errorf(
						"%s imports internal/%s: %s must not depend on it",
						strings.TrimPrefix(path, repoRoot(t)+"/"), imported, name,
					)
				}
			}
		}
	}
}

func TestBroadTypeMethodBudget(t *testing.T) {
	packages := goPackages(t)
	counts := make(map[string]int)
	for _, files := range packages {
		for _, path := range files {
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Recv == nil || len(fn.Recv.List) == 0 {
					continue
				}
				expr := fn.Recv.List[0].Type
				if star, isStar := expr.(*ast.StarExpr); isStar {
					expr = star.X
				}
				ident, isIdent := expr.(*ast.Ident)
				if !isIdent {
					continue
				}
				if _, tracked := methodBudget[ident.Name]; tracked && fn.Name.IsExported() {
					counts[ident.Name]++
				}
			}
		}
	}
	for name, budget := range methodBudget {
		count := counts[name]
		if count == 0 {
			t.Fatalf("type %q named in methodBudget was not found; update this test", name)
		}
		if count > budget {
			t.Errorf(
				"%s has %d methods, over its budget of %d.\n"+
					"Extract a cohesive area into its own type or package rather than raising this.",
				name, count, budget,
			)
		}
	}
}

// codeLines counts lines that carry code, skipping blanks and comments.
//
// The budget exists to stop a package absorbing responsibility, and comments
// are not responsibility. Counting them meant that naming and explaining an
// extracted phase — the exact change the budget is supposed to encourage —
// pushed the package toward its limit, which is backwards.
func codeLines(source string) int {
	count := 0
	inBlockComment := false
	for _, line := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case inBlockComment:
			if strings.Contains(trimmed, "*/") {
				inBlockComment = false
			}
		case trimmed == "" || strings.HasPrefix(trimmed, "//"):
		case strings.HasPrefix(trimmed, "/*"):
			inBlockComment = !strings.Contains(trimmed, "*/")
		default:
			count++
		}
	}
	return count
}

func TestPackageLineBudget(t *testing.T) {
	packages := goPackages(t)
	for name, budget := range lineBudget {
		files, ok := packages[name]
		if !ok {
			t.Fatalf("package %q named in lineBudget no longer exists; update this test", name)
		}
		total := 0
		for _, path := range files {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			total += codeLines(string(data))
		}
		if total > budget {
			t.Errorf(
				"package internal/%s has %d non-test lines, over its budget of %d.\n"+
					"Split a cohesive area into its own package rather than raising this.",
				name, total, budget,
			)
		}
	}
}

// stringSliceAllowlist names the few places a raw byte slice over a string is
// correct: fixed-width hex digests and identifiers whose alphabet is ASCII by
// construction. Everything else must go through core.TruncateUTF8.
var stringSliceAllowlist = map[string]bool{
	"internal/publisher/github.go":             true, // slug is ASCII by regex construction
	"internal/service/publication_followup.go": true, // 7-char hex SHA prefix
	"internal/slackui/message.go":              true, // hex digest + ShortID over an ASCII id
	"internal/core/text.go":                    true, // the safe truncation helper itself
	"internal/coop/client.go":                  true, // prompt elision walks rune boundaries itself
}

// Slicing a string on a byte boundary splits multi-byte runes, which reaches
// operators as a replacement character and corrupts anything that re-encodes
// the value as JSON. The whole codebase was cleaned of this once and it came
// back in new code, so it is now a build-time rule rather than a convention.
func TestNoRawStringSlicing(t *testing.T) {
	packages := goPackages(t)
	root := repoRoot(t)
	for _, files := range packages {
		for _, path := range files {
			relative := strings.TrimPrefix(path, root+"/")
			if stringSliceAllowlist[relative] {
				continue
			}
			fset := token.NewFileSet()
			file, err := parser.ParseFile(fset, path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			info := stringTypedLocals(file)
			ast.Inspect(file, func(node ast.Node) bool {
				slice, ok := node.(*ast.SliceExpr)
				if !ok {
					return true
				}
				ident, isIdent := slice.X.(*ast.Ident)
				if !isIdent || !info[ident.Name] || !truncatingBound(slice) {
					return true
				}
				t.Errorf(
					"%s:%d: %s is a string sliced on a byte boundary; use core.TruncateUTF8 "+
						"(or add the file to stringSliceAllowlist with a reason)",
					relative, fset.Position(slice.Pos()).Line, ident.Name,
				)
				return true
			})
		}
	}
}

// truncatingBound reports whether a slice expression is a truncation — no low
// bound, and a high bound that is a size rather than an offset found inside the
// string. Slicing at a strings.Index result is rune-aligned and safe; slicing
// at a byte count is not.
func truncatingBound(slice *ast.SliceExpr) bool {
	if slice.Low != nil || slice.High == nil || slice.Slice3 {
		return false
	}
	var literal func(ast.Expr) bool
	literal = func(expr ast.Expr) bool {
		switch value := expr.(type) {
		case *ast.BasicLit:
			return value.Kind == token.INT
		case *ast.BinaryExpr:
			return literal(value.X) && literal(value.Y)
		case *ast.ParenExpr:
			return literal(value.X)
		case *ast.Ident:
			name := strings.ToLower(value.Name)
			return strings.HasPrefix(name, "max") || strings.HasPrefix(name, "limit") ||
				strings.HasSuffix(name, "bytes") || strings.HasSuffix(name, "limit") ||
				strings.HasSuffix(name, "max")
		}
		return false
	}
	return literal(slice.High)
}

// stringTypedLocals reports identifiers declared as string in this file, which
// is enough to catch the pattern without full type checking.
func stringTypedLocals(file *ast.File) map[string]bool {
	names := map[string]bool{}
	record := func(name string, typ ast.Expr) {
		if ident, ok := typ.(*ast.Ident); ok && ident.Name == "string" {
			names[name] = true
		}
	}
	ast.Inspect(file, func(node ast.Node) bool {
		switch decl := node.(type) {
		case *ast.ValueSpec:
			for _, name := range decl.Names {
				if decl.Type != nil {
					record(name.Name, decl.Type)
				}
			}
		case *ast.Field:
			for _, name := range decl.Names {
				record(name.Name, decl.Type)
			}
		case *ast.AssignStmt:
			for index, lhs := range decl.Lhs {
				ident, ok := lhs.(*ast.Ident)
				if !ok || index >= len(decl.Rhs) {
					continue
				}
				if literal, isLiteral := decl.Rhs[index].(*ast.BasicLit); isLiteral &&
					literal.Kind == token.STRING {
					names[ident.Name] = true
				}
				if call, isCall := decl.Rhs[index].(*ast.CallExpr); isCall {
					if fn, isSelector := call.Fun.(*ast.SelectorExpr); isSelector {
						if pkg, isPkg := fn.X.(*ast.Ident); isPkg && pkg.Name == "strings" {
							names[ident.Name] = true
						}
					}
				}
			}
		}
		return true
	})
	return names
}
