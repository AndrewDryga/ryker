package publisher

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/hermeticgit"
)

const maxCommandOutput = hermeticgit.MaxOutput
const maxPullRequestDiff = 2 << 20

var unsafeSlug = regexp.MustCompile(`[^a-z0-9]+`)
var fullGitOID = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)
var githubRepository = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

var credentialPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b`),
	regexp.MustCompile(`\bxapp-[A-Za-z0-9-]{10,}\b`),
	regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}\b`),
	regexp.MustCompile(`\bAKIA[A-Z0-9]{16}\b`),
	regexp.MustCompile(`\bemk-[A-Za-z0-9_-]{10,}\b`),
	regexp.MustCompile(`-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----`),
}

type Request struct {
	StateDir   string
	Incident   core.Incident
	Repository config.Repository
	Review     coop.Review
	Existing   core.Publication
}

type Result struct {
	HeadBranch string
	CommitSHA  string
	RemoteSHA  string
	PRNumber   int
	PRURL      string
}

// PullRequestContext is an authenticated, immutable snapshot of the material a
// reviewer needs. It deliberately excludes mutable controls: Responder may read
// private PRs without gaining permission to comment, approve, merge, or push.
type PullRequestContext struct {
	Repository     string
	Number         int
	URL            string
	Title          string
	Body           string
	State          string
	Draft          bool
	Merged         bool
	Author         string
	BaseRef        string
	BaseSHA        string
	BaseRepository string
	HeadRef        string
	HeadSHA        string
	HeadRepository string
	ChangedFiles   int
	Additions      int
	Deletions      int
	Diff           string
	DiffTruncated  bool
	Comments       []PullRequestComment
	Reviews        []PullRequestReview
	ReviewComments []PullRequestReviewComment
	Warnings       []string
}

type PullRequestComment struct {
	Author string
	Body   string
}

type PullRequestReview struct {
	Author string
	State  string
	Body   string
}

type PullRequestReviewComment struct {
	Author string
	Body   string
	Path   string
	Line   int
	Side   string
}

type GitHub struct {
	cfg       config.GitHubConfig
	client    *http.Client
	remoteURL func(string) string
	secrets   [][]byte
}

func New(cfg config.GitHubConfig, secrets ...string) *GitHub {
	exactSecrets := make([][]byte, 0, len(secrets))
	for _, secret := range secrets {
		if len(secret) >= 8 {
			exactSecrets = append(exactSecrets, []byte(secret))
		}
	}
	return &GitHub{
		cfg: cfg,
		client: &http.Client{
			Timeout: 30 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		remoteURL: func(repository string) string {
			return "https://github.com/" + repository + ".git"
		},
		secrets: exactSecrets,
	}
}

func (g *GitHub) Enabled() bool {
	return g != nil && g.cfg.Enabled
}

func (g *GitHub) HeadBranch(
	incident core.Incident,
	existing core.Publication,
) (string, error) {
	if !g.Enabled() {
		return "", errors.New("GitHub draft PR publishing is not enabled")
	}
	if existing.HeadBranch != "" {
		if !validRefComponent(existing.HeadBranch) {
			return "", errors.New("stored draft PR branch is invalid")
		}
		return existing.HeadBranch, nil
	}
	branch := g.branchName(incident)
	if !validRefComponent(branch) {
		return "", errors.New("generated draft PR branch is invalid")
	}
	return branch, nil
}

func (g *GitHub) Ready(ctx context.Context) error {
	if !g.Enabled() {
		return nil
	}
	token, err := g.token(ctx)
	if err != nil {
		return err
	}
	var identity struct {
		Login string `json:"login"`
	}
	if err := g.api(ctx, token, http.MethodGet, "/user", nil, &identity); err != nil {
		return err
	}
	if strings.TrimSpace(identity.Login) == "" {
		return errors.New("GitHub authentication returned no account login")
	}
	return nil
}

// PullRequestContext reads an exact PR through the same authenticated GitHub
// adapter used for publication. This is also the private-repository path; no
// unauthenticated browser lookup is attempted.
func (g *GitHub) PullRequestContext(
	ctx context.Context,
	repository string,
	number int,
) (PullRequestContext, error) {
	var result PullRequestContext
	if !g.Enabled() {
		return result, errors.New("GitHub access is not enabled")
	}
	if !githubRepository.MatchString(repository) || number < 1 {
		return result, errors.New("GitHub pull request reference is invalid")
	}
	token, err := g.token(ctx)
	if err != nil {
		return result, err
	}
	path := "/repos/" + repository + "/pulls/" + strconv.Itoa(number)
	var pull struct {
		Number       int    `json:"number"`
		HTMLURL      string `json:"html_url"`
		Title        string `json:"title"`
		Body         string `json:"body"`
		State        string `json:"state"`
		Draft        bool   `json:"draft"`
		Merged       bool   `json:"merged"`
		ChangedFiles int    `json:"changed_files"`
		Additions    int    `json:"additions"`
		Deletions    int    `json:"deletions"`
		User         struct {
			Login string `json:"login"`
		} `json:"user"`
		Base struct {
			Ref  string `json:"ref"`
			SHA  string `json:"sha"`
			Repo struct {
				FullName string `json:"full_name"`
			} `json:"repo"`
		} `json:"base"`
		Head struct {
			Ref  string `json:"ref"`
			SHA  string `json:"sha"`
			Repo struct {
				FullName string `json:"full_name"`
			} `json:"repo"`
		} `json:"head"`
	}
	if err := g.api(ctx, token, http.MethodGet, path, nil, &pull); err != nil {
		return result, fmt.Errorf("read pull request: %w", err)
	}
	diff, truncated, err := g.apiRaw(
		ctx, token, http.MethodGet, path, "application/vnd.github.v3.diff", maxPullRequestDiff,
	)
	if err != nil {
		return result, fmt.Errorf("read pull request diff: %w", err)
	}
	result = PullRequestContext{
		Repository: repository, Number: pull.Number, URL: pull.HTMLURL,
		Title: pull.Title, Body: pull.Body, State: pull.State, Draft: pull.Draft,
		Merged: pull.Merged, Author: pull.User.Login,
		BaseRef: pull.Base.Ref, BaseSHA: pull.Base.SHA, BaseRepository: pull.Base.Repo.FullName,
		HeadRef: pull.Head.Ref, HeadSHA: pull.Head.SHA, HeadRepository: pull.Head.Repo.FullName,
		ChangedFiles: pull.ChangedFiles, Additions: pull.Additions,
		Deletions: pull.Deletions, Diff: string(diff), DiffTruncated: truncated,
	}
	var comments []struct {
		Body string `json:"body"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := g.api(
		ctx, token, http.MethodGet,
		"/repos/"+repository+"/issues/"+strconv.Itoa(number)+"/comments?per_page=100",
		nil, &comments,
	); err == nil {
		for _, comment := range comments {
			result.Comments = append(result.Comments, PullRequestComment{
				Author: comment.User.Login, Body: comment.Body,
			})
		}
	} else {
		result.Warnings = append(result.Warnings, "PR conversation was unavailable: "+err.Error())
	}
	var reviews []struct {
		Body  string `json:"body"`
		State string `json:"state"`
		User  struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := g.api(
		ctx, token, http.MethodGet, path+"/reviews?per_page=100", nil, &reviews,
	); err == nil {
		for _, review := range reviews {
			result.Reviews = append(result.Reviews, PullRequestReview{
				Author: review.User.Login, State: review.State, Body: review.Body,
			})
		}
	} else {
		result.Warnings = append(result.Warnings, "PR reviews were unavailable: "+err.Error())
	}
	var reviewComments []struct {
		Body string `json:"body"`
		Path string `json:"path"`
		Line int    `json:"line"`
		Side string `json:"side"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := g.api(
		ctx, token, http.MethodGet, path+"/comments?per_page=100", nil, &reviewComments,
	); err == nil {
		for _, comment := range reviewComments {
			result.ReviewComments = append(result.ReviewComments, PullRequestReviewComment{
				Author: comment.User.Login, Body: comment.Body, Path: comment.Path,
				Line: comment.Line, Side: comment.Side,
			})
		}
	} else {
		result.Warnings = append(result.Warnings, "Inline review comments were unavailable: "+err.Error())
	}
	return result, nil
}

func (g *GitHub) Publish(ctx context.Context, request Request) (Result, error) {
	var result Result
	if !g.Enabled() {
		return result, errors.New("GitHub draft PR publishing is not enabled")
	}
	if !request.Review.Publishable {
		return result, fmt.Errorf(
			"Coop review is not publishable: %s",
			strings.Join(request.Review.NotPublishableReasons, "; "),
		)
	}
	if request.Review.PatchTruncated || len(request.Review.Patch) == 0 {
		return result, errors.New("Coop review did not provide a complete patch")
	}
	if request.Review.PatchBytes > 0 &&
		int64(len(request.Review.Patch)) != request.Review.PatchBytes {
		return result, errors.New("Coop review patch size does not match its dossier")
	}
	if request.Review.PatchDigest != "" {
		digest := sha256.Sum256(request.Review.Patch)
		if hex.EncodeToString(digest[:]) != request.Review.PatchDigest {
			return result, errors.New("Coop review patch digest does not match its dossier")
		}
	}
	if !fullGitOID.MatchString(request.Review.ParentHead) ||
		!fullGitOID.MatchString(request.Review.CandidateTree) {
		return result, errors.New("Coop review contains an invalid Git object ID")
	}
	for _, secret := range g.secrets {
		if bytes.Contains(request.Review.Patch, secret) {
			return result, errors.New("reviewed patch contains a configured secret")
		}
	}
	for _, pattern := range credentialPatterns {
		if pattern.Match(request.Review.Patch) {
			return result, errors.New("reviewed patch contains a credential-shaped secret")
		}
	}
	if request.Repository.Path == "" || request.Repository.GitHubRepository == "" {
		return result, errors.New("repository publishing binding is incomplete")
	}
	branch, err := g.HeadBranch(request.Incident, request.Existing)
	if err != nil {
		return result, err
	}
	result.HeadBranch = branch
	token, err := g.token(ctx)
	if err != nil {
		return result, err
	}
	work, err := os.MkdirTemp(request.StateDir, "publication-*")
	if err != nil {
		return result, fmt.Errorf("create isolated publication checkout: %w", err)
	}
	defer os.RemoveAll(work)
	if err := os.Chmod(work, 0o700); err != nil {
		return result, err
	}
	run := func(input []byte, args ...string) (string, error) {
		return hermeticgit.Run(ctx, work, "", nil, input, args...)
	}
	if _, err := run(nil, "init", "--quiet"); err != nil {
		return result, err
	}
	if _, err := run(nil, "remote", "add", "source", request.Repository.Path); err != nil {
		return result, err
	}
	if _, err := run(nil, "fetch", "--quiet", "--no-tags", "source", request.Review.ParentHead); err != nil {
		return result, fmt.Errorf("fetch reviewed parent commit: %w", err)
	}
	if _, err := run(nil, "checkout", "--quiet", "--detach", request.Review.ParentHead); err != nil {
		return result, err
	}
	if _, err := run(request.Review.Patch, "apply", "--index", "--binary", "--whitespace=error-all", "-"); err != nil {
		return result, fmt.Errorf("apply reviewed patch: %w", err)
	}
	tree, err := run(nil, "write-tree")
	if err != nil {
		return result, err
	}
	tree = strings.TrimSpace(tree)
	if tree != request.Review.CandidateTree {
		return result, fmt.Errorf(
			"reviewed tree mismatch: Coop approved %s, isolated checkout produced %s",
			request.Review.CandidateTree, tree,
		)
	}
	commitEnv := []string{
		"GIT_AUTHOR_NAME=" + g.cfg.CommitName,
		"GIT_AUTHOR_EMAIL=" + g.cfg.CommitEmail,
		"GIT_COMMITTER_NAME=" + g.cfg.CommitName,
		"GIT_COMMITTER_EMAIL=" + g.cfg.CommitEmail,
		"GIT_AUTHOR_DATE=" + request.Incident.CreatedAt.UTC().Format(time.RFC3339),
		"GIT_COMMITTER_DATE=" + request.Incident.CreatedAt.UTC().Format(time.RFC3339),
	}
	message := safeTitle(request.Incident.Title) + "\n\n" +
		"Prepared by Emisar Responder from Coop review " + request.Review.OperationID + "."
	if _, err := hermeticgit.Run(
		ctx, work, "", commitEnv, nil, "commit", "--quiet", "-m", message,
	); err != nil {
		return result, fmt.Errorf("create reviewed publication commit: %w", err)
	}
	commit, err := run(nil, "rev-parse", "HEAD")
	if err != nil {
		return result, err
	}
	result.CommitSHA = strings.TrimSpace(commit)
	if request.Existing.PRNumber > 0 {
		if _, err := g.existingPullRequest(
			ctx, token, request, request.Existing.RemoteSHA, result.CommitSHA,
		); err != nil {
			return result, err
		}
	}

	remoteURL := g.remoteURL(request.Repository.GitHubRepository)
	remoteSHA, err := g.remoteRef(ctx, work, token, remoteURL, branch)
	if err != nil {
		return result, err
	}
	switch {
	case remoteSHA == result.CommitSHA:
		result.RemoteSHA = remoteSHA
	case request.Existing.RemoteSHA == "" && remoteSHA != "":
		return result, fmt.Errorf(
			"publication branch %q already exists at an unrecorded commit; refusing to overwrite it",
			branch,
		)
	case request.Existing.RemoteSHA != "" && remoteSHA != request.Existing.RemoteSHA:
		return result, fmt.Errorf(
			"publication branch %q changed outside Responder; expected %s, found %s",
			branch, request.Existing.RemoteSHA, remoteSHA,
		)
	default:
		lease := "refs/heads/" + branch + ":" + request.Existing.RemoteSHA
		env := hermeticgit.AuthEnv(token)
		if _, err := hermeticgit.Run(
			ctx, work, "", env, nil, "push", "--quiet",
			"--force-with-lease="+lease,
			remoteURL, result.CommitSHA+":refs/heads/"+branch,
		); err != nil {
			return result, fmt.Errorf("push reviewed publication branch: %w", err)
		}
		result.RemoteSHA = result.CommitSHA
	}

	pr, err := g.ensureDraftPR(ctx, token, request, result)
	if err != nil {
		return result, err
	}
	result.PRNumber = pr.Number
	result.PRURL = pr.HTMLURL
	return result, nil
}

func (g *GitHub) VerifyPublication(
	ctx context.Context,
	publication core.Publication,
) error {
	if !g.Enabled() {
		return errors.New("GitHub publication verification is not enabled")
	}
	if publication.Repository == "" || publication.PRNumber < 1 ||
		publication.HeadBranch == "" || !fullGitOID.MatchString(publication.RemoteSHA) {
		return errors.New("publication proof is incomplete")
	}
	token, err := g.token(ctx)
	if err != nil {
		return err
	}
	var current pullRequest
	path := "/repos/" + publication.Repository + "/pulls/" +
		strconv.Itoa(publication.PRNumber)
	if err := g.api(ctx, token, http.MethodGet, path, nil, &current); err != nil {
		return fmt.Errorf("verify published pull request: %w", err)
	}
	if current.Number != publication.PRNumber ||
		current.Head.Ref != publication.HeadBranch ||
		current.Head.SHA != publication.RemoteSHA {
		return fmt.Errorf(
			"published pull request no longer preserves branch %q at %s",
			publication.HeadBranch,
			publication.RemoteSHA,
		)
	}
	if current.HTMLURL == "" {
		return errors.New("published pull request has no canonical URL")
	}
	return nil
}

func (g *GitHub) PublicationStatus(
	ctx context.Context,
	publication core.Publication,
) (core.PublicationLifecycleStatus, error) {
	if !g.Enabled() {
		return core.PublicationLifecycleStatus{}, errors.New("GitHub publication status is not enabled")
	}
	if publication.Repository == "" || publication.PRNumber < 1 {
		return core.PublicationLifecycleStatus{}, errors.New("publication identity is incomplete")
	}
	token, err := g.token(ctx)
	if err != nil {
		return core.PublicationLifecycleStatus{}, err
	}
	var current pullRequest
	path := "/repos/" + publication.Repository + "/pulls/" +
		strconv.Itoa(publication.PRNumber)
	if err := g.api(ctx, token, http.MethodGet, path, nil, &current); err != nil {
		return core.PublicationLifecycleStatus{}, fmt.Errorf("inspect published pull request: %w", err)
	}
	status := core.PublicationLifecycleStatus{
		PRState: current.State, Draft: current.Draft, HeadSHA: current.Head.SHA,
		MergeSHA: current.MergeCommitSHA, MergedAt: current.MergedAt,
	}
	if current.Merged {
		status.PRState = "merged"
	}
	if status.HeadSHA == "" {
		status.HeadSHA = publication.RemoteSHA
	}
	if status.HeadSHA == "" {
		status.ChecksState = "unknown"
		return status, nil
	}
	checks, err := g.commitChecks(ctx, token, publication.Repository, status.HeadSHA)
	if err != nil {
		return core.PublicationLifecycleStatus{}, err
	}
	status.ChecksState = checks.state
	status.ChecksTotal = checks.total
	status.ChecksPassed = checks.passed
	status.ChecksFailed = checks.failed
	status.ChecksURL = checks.url
	return status, nil
}

type commitCheckSummary struct {
	state  string
	total  int
	passed int
	failed int
	url    string
}

func (g *GitHub) commitChecks(
	ctx context.Context,
	token string,
	repository string,
	sha string,
) (commitCheckSummary, error) {
	var checkRuns struct {
		CheckRuns []struct {
			Status     string `json:"status"`
			Conclusion string `json:"conclusion"`
			DetailsURL string `json:"details_url"`
		} `json:"check_runs"`
	}
	path := "/repos/" + repository + "/commits/" + sha + "/check-runs?per_page=100"
	if err := g.api(ctx, token, http.MethodGet, path, nil, &checkRuns); err != nil {
		return commitCheckSummary{}, fmt.Errorf("inspect GitHub checks: %w", err)
	}
	var combined struct {
		Statuses []struct {
			State     string `json:"state"`
			TargetURL string `json:"target_url"`
		} `json:"statuses"`
	}
	path = "/repos/" + repository + "/commits/" + sha + "/status"
	if err := g.api(ctx, token, http.MethodGet, path, nil, &combined); err != nil {
		return commitCheckSummary{}, fmt.Errorf("inspect GitHub commit statuses: %w", err)
	}
	result := commitCheckSummary{}
	pending := 0
	sharedRunURL := ""
	allShareRun := true
	recordRun := func(value string) {
		current := githubWorkflowRunURL(value)
		if current == "" {
			allShareRun = false
			return
		}
		if sharedRunURL == "" {
			sharedRunURL = current
			return
		}
		if sharedRunURL != current {
			allShareRun = false
		}
	}
	for _, check := range checkRuns.CheckRuns {
		result.total++
		recordRun(check.DetailsURL)
		if check.Status != "completed" || check.Conclusion == "" {
			pending++
			continue
		}
		switch check.Conclusion {
		case "success", "neutral", "skipped":
			result.passed++
		default:
			result.failed++
		}
	}
	for _, check := range combined.Statuses {
		result.total++
		recordRun(check.TargetURL)
		switch check.State {
		case "success":
			result.passed++
		case "failure", "error":
			result.failed++
		default:
			pending++
		}
	}
	switch {
	case result.failed > 0:
		result.state = "failing"
	case pending > 0:
		result.state = "pending"
	case result.total > 0:
		result.state = "passing"
	default:
		result.state = "none"
	}
	if allShareRun {
		result.url = sharedRunURL
	}
	return result, nil
}

func githubWorkflowRunURL(value string) string {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return ""
	}
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	for index := 0; index+2 < len(parts); index++ {
		if parts[index] != "actions" || parts[index+1] != "runs" {
			continue
		}
		if _, err := strconv.ParseUint(parts[index+2], 10, 64); err != nil {
			return ""
		}
		parsed.Path = "/" + strings.Join(parts[:index+3], "/")
		parsed.RawPath = ""
		parsed.RawQuery = ""
		parsed.Fragment = ""
		return parsed.String()
	}
	return ""
}

func (g *GitHub) token(ctx context.Context) (string, error) { return Token(ctx, g.cfg) }

// Token reads the GitHub credential the configuration names.
//
// Exported because internal/repomirror fetches managed clones with the same
// credential and must read it the same way. Two readers of one secret is one
// thing; two rules for where that secret lives is how a deployment that moved
// from an environment variable to the gh CLI keeps publishing and quietly stops
// fetching.
func Token(ctx context.Context, cfg config.GitHubConfig) (string, error) {
	if cfg.TokenEnv != "" {
		if token := strings.TrimSpace(os.Getenv(cfg.TokenEnv)); token != "" {
			return token, nil
		}
	}
	if cfg.UseCLIAuth {
		command := exec.CommandContext(ctx, "gh", "auth", "token", "--hostname", "github.com")
		output, err := command.Output()
		if err != nil {
			return "", errors.New("GitHub credential is unavailable from the configured environment and gh CLI")
		}
		if token := strings.TrimSpace(string(output)); token != "" {
			return token, nil
		}
	}
	return "", fmt.Errorf("GitHub credential environment variable %s is not set", cfg.TokenEnv)
}

func (g *GitHub) branchName(incident core.Incident) string {
	slug := strings.Trim(unsafeSlug.ReplaceAllString(strings.ToLower(incident.Title), "-"), "-")
	if len(slug) > 42 {
		slug = strings.TrimRight(slug[:42], "-")
	}
	if slug == "" {
		slug = "change"
	}
	id := incident.ID
	if len(id) > 10 {
		id = id[len(id)-10:]
	}
	return g.cfg.BranchPrefix + "/" + slug + "-" + id
}

func validRefComponent(value string) bool {
	return value != "" &&
		!strings.HasPrefix(value, "-") &&
		!strings.HasPrefix(value, "/") &&
		!strings.HasSuffix(value, "/") &&
		!strings.HasSuffix(value, ".") &&
		!strings.Contains(value, "..") &&
		!strings.Contains(value, "@{") &&
		!strings.ContainsAny(value, " ~^:?*[\\\r\n\t")
}

// ResolveTree returns the tree object ID for commit in the checkout at path. It
// is the one supported way to ask git a question about a repository outside the
// publication flow, so every git invocation stays hermetic and every object ID
// is validated before it reaches a command line.
func (g *GitHub) ResolveTree(ctx context.Context, path, commit string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("repository checkout path is required")
	}
	if !fullGitOID.MatchString(commit) {
		return "", fmt.Errorf("%q is not a full Git object ID", commit)
	}
	output, err := hermeticgit.Run(
		ctx, path, "", nil, nil,
		"rev-parse", "--verify", "--end-of-options", commit+"^{tree}",
	)
	if err != nil {
		return "", err
	}
	tree := strings.TrimSpace(output)
	if !fullGitOID.MatchString(tree) {
		return "", errors.New("git returned an unexpected tree object ID")
	}
	return tree, nil
}

func (g *GitHub) remoteRef(
	ctx context.Context,
	work string,
	token string,
	remoteURL string,
	branch string,
) (string, error) {
	output, err := hermeticgit.Run(
		ctx, work, "", hermeticgit.AuthEnv(token), nil,
		"ls-remote", "--heads", remoteURL, "refs/heads/"+branch,
	)
	if err != nil {
		return "", fmt.Errorf("inspect publication branch: %w", err)
	}
	fields := strings.Fields(output)
	if len(fields) == 0 {
		return "", nil
	}
	if len(fields) != 2 || fields[1] != "refs/heads/"+branch {
		return "", errors.New("GitHub returned an unexpected publication branch response")
	}
	return fields[0], nil
}

type pullRequest struct {
	Number         int       `json:"number"`
	HTMLURL        string    `json:"html_url"`
	State          string    `json:"state"`
	Draft          bool      `json:"draft"`
	Merged         bool      `json:"merged"`
	MergeCommitSHA string    `json:"merge_commit_sha"`
	MergedAt       time.Time `json:"merged_at"`
	Head           struct {
		Ref string `json:"ref"`
		SHA string `json:"sha"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
}

func (g *GitHub) ensureDraftPR(
	ctx context.Context,
	token string,
	request Request,
	result Result,
) (pullRequest, error) {
	if request.Existing.PRNumber > 0 {
		// A successful lease-protected push can become visible through Git before
		// GitHub's pull-request API updates head.sha. Both values are bound: the old
		// head is the recorded lease and the new head is the commit we just pushed.
		return g.existingPullRequest(
			ctx, token, request, request.Existing.RemoteSHA, result.RemoteSHA,
		)
	}

	title := safeTitle(request.Incident.Title)
	body := publicationBody(request, result)
	var existing []pullRequest
	owner, _, _ := strings.Cut(request.Repository.GitHubRepository, "/")
	query := "?state=open&head=" + url.QueryEscape(owner+":"+result.HeadBranch)
	if err := g.api(
		ctx, token, http.MethodGet,
		"/repos/"+request.Repository.GitHubRepository+"/pulls"+query,
		nil, &existing,
	); err != nil {
		return pullRequest{}, err
	}
	if len(existing) > 1 {
		return pullRequest{}, errors.New("multiple pull requests use the publication branch")
	}
	if len(existing) == 1 {
		if !existing[0].Draft {
			return pullRequest{}, errors.New("publication branch already has a non-draft pull request")
		}
		return existing[0], nil
	}
	var created pullRequest
	err := g.api(ctx, token, http.MethodPost,
		"/repos/"+request.Repository.GitHubRepository+"/pulls",
		map[string]any{
			"title": title,
			"head":  result.HeadBranch,
			"base":  request.Repository.GitHubBaseBranch,
			"body":  body,
			"draft": true,
		}, &created)
	return created, err
}

func (g *GitHub) existingPullRequest(
	ctx context.Context,
	token string,
	request Request,
	expectedHeads ...string,
) (pullRequest, error) {
	var existing pullRequest
	path := "/repos/" + request.Repository.GitHubRepository + "/pulls/" +
		strconv.Itoa(request.Existing.PRNumber)
	if err := g.api(ctx, token, http.MethodGet, path, nil, &existing); err != nil {
		return pullRequest{}, err
	}
	headMatches := false
	for _, expected := range expectedHeads {
		headMatches = headMatches || existing.Head.SHA == expected
	}
	if existing.Number != request.Existing.PRNumber || existing.HTMLURL == "" ||
		existing.HTMLURL != request.Existing.PRURL || existing.State != "open" ||
		existing.Merged || existing.Head.Ref != request.Existing.HeadBranch ||
		!headMatches ||
		existing.Base.Ref != request.Repository.GitHubBaseBranch {
		return pullRequest{}, errors.New("recorded pull request is no longer the expected open branch, head, and base")
	}
	return existing, nil
}

func publicationBody(request Request, result Result) string {
	return fmt.Sprintf(
		"## Responder task\n\n%s\n\n## Publication proof\n\n"+
			"- Coop session: `%s`\n- Reviewed parent: `%s`\n- Reviewed tree: `%s`\n"+
			"- Publication commit: `%s`\n- Gate: `%s`\n- Rebase: `%s`\n",
		safeTitle(request.Incident.Title),
		request.Incident.CoopSessionID,
		request.Review.ParentHead,
		request.Review.CandidateTree,
		result.CommitSHA,
		request.Review.Gate,
		request.Review.Rebase,
	)
}

func safeTitle(value string) string {
	value = strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	value = strings.Join(strings.Fields(value), " ")
	value = strings.ReplaceAll(value, "@", "@ ")
	if runes := []rune(value); len(runes) > 200 {
		value = strings.TrimSpace(string(runes[:200]))
	}
	if value == "" {
		return "Responder engineering task"
	}
	return value
}

func (g *GitHub) api(
	ctx context.Context,
	token string,
	method string,
	path string,
	body any,
	result any,
) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(
		ctx, method, strings.TrimRight(g.cfg.APIURL, "/")+path, reader,
	)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	response, err := g.client.Do(req)
	if err != nil {
		return fmt.Errorf("call GitHub: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxCommandOutput+1))
	if err != nil {
		return err
	}
	if len(data) > maxCommandOutput {
		return errors.New("GitHub response exceeded 1 MiB")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(data, &failure)
		return fmt.Errorf("GitHub API %d: %s", response.StatusCode, strings.TrimSpace(failure.Message))
	}
	if result == nil {
		return nil
	}
	if err := json.Unmarshal(data, result); err != nil {
		return fmt.Errorf("decode GitHub response: %w", err)
	}
	return nil
}

func (g *GitHub) apiRaw(
	ctx context.Context,
	token string,
	method string,
	path string,
	accept string,
	limit int64,
) ([]byte, bool, error) {
	req, err := http.NewRequestWithContext(
		ctx, method, strings.TrimRight(g.cfg.APIURL, "/")+path, nil,
	)
	if err != nil {
		return nil, false, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	response, err := g.client.Do(req)
	if err != nil {
		return nil, false, fmt.Errorf("call GitHub: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, false, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, false, fmt.Errorf("GitHub API %d", response.StatusCode)
	}
	if int64(len(data)) > limit {
		return data[:limit], true, nil
	}
	return data, false, nil
}
