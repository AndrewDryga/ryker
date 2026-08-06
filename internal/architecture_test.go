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
	"Store":   285,
}

// lineBudget caps non-test source lines per package.
//
// internal/service is over any reasonable size and the budget only stops it
// drifting further. The identified extraction is the offline evaluation family
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
var lineBudget = map[string]int{
	"service":    28000,
	"store":      14000,
	"localstate": 250,
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
	"publisher":     {"service", "store", "slackui", "httpapi", "app"},
	"localstate":    {"service", "store", "httpapi", "app", "publisher", "coop", "config"},
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
			total += strings.Count(string(data), "\n")
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
