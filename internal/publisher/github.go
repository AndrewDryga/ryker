package publisher

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
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
)

const maxCommandOutput = 1 << 20

var unsafeSlug = regexp.MustCompile(`[^a-z0-9]+`)
var fullGitOID = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)

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
		return runGit(ctx, work, nil, input, args...)
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
	if _, err := runGit(ctx, work, commitEnv, nil, "commit", "--quiet", "-m", message); err != nil {
		return result, fmt.Errorf("create reviewed publication commit: %w", err)
	}
	commit, err := run(nil, "rev-parse", "HEAD")
	if err != nil {
		return result, err
	}
	result.CommitSHA = strings.TrimSpace(commit)

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
		env := gitAuthEnv(token)
		if _, err := runGit(
			ctx, work, env, nil, "push", "--quiet",
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
	return status, nil
}

type commitCheckSummary struct {
	state  string
	total  int
	passed int
	failed int
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
		} `json:"check_runs"`
	}
	path := "/repos/" + repository + "/commits/" + sha + "/check-runs?per_page=100"
	if err := g.api(ctx, token, http.MethodGet, path, nil, &checkRuns); err != nil {
		return commitCheckSummary{}, fmt.Errorf("inspect GitHub checks: %w", err)
	}
	var combined struct {
		Statuses []struct {
			State string `json:"state"`
		} `json:"statuses"`
	}
	path = "/repos/" + repository + "/commits/" + sha + "/status"
	if err := g.api(ctx, token, http.MethodGet, path, nil, &combined); err != nil {
		return commitCheckSummary{}, fmt.Errorf("inspect GitHub commit statuses: %w", err)
	}
	result := commitCheckSummary{}
	pending := 0
	for _, check := range checkRuns.CheckRuns {
		result.total++
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
	return result, nil
}

func (g *GitHub) token(ctx context.Context) (string, error) {
	if g.cfg.TokenEnv != "" {
		if token := strings.TrimSpace(os.Getenv(g.cfg.TokenEnv)); token != "" {
			return token, nil
		}
	}
	if g.cfg.UseCLIAuth {
		command := exec.CommandContext(ctx, "gh", "auth", "token", "--hostname", "github.com")
		output, err := command.Output()
		if err != nil {
			return "", errors.New("GitHub credential is unavailable from the configured environment and gh CLI")
		}
		if token := strings.TrimSpace(string(output)); token != "" {
			return token, nil
		}
	}
	return "", fmt.Errorf("GitHub credential environment variable %s is not set", g.cfg.TokenEnv)
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

func gitAuthEnv(token string) []string {
	value := base64.StdEncoding.EncodeToString([]byte("x-access-token:" + token))
	return []string{
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http.https://github.com/.extraheader",
		"GIT_CONFIG_VALUE_0=AUTHORIZATION: basic " + value,
		"GIT_TERMINAL_PROMPT=0",
	}
}

func runGit(
	ctx context.Context,
	work string,
	extraEnv []string,
	input []byte,
	args ...string,
) (string, error) {
	command := exec.CommandContext(ctx, "git", append([]string{"-C", work}, args...)...)
	command.Env = append(os.Environ(), extraEnv...)
	if input != nil {
		command.Stdin = bytes.NewReader(input)
	}
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	err := command.Run()
	if output.Len() > maxCommandOutput {
		return "", errors.New("git output exceeded 1 MiB")
	}
	if err != nil {
		return "", fmt.Errorf("git %s: %s", args[0], strings.TrimSpace(output.String()))
	}
	return output.String(), nil
}

func (g *GitHub) remoteRef(
	ctx context.Context,
	work string,
	token string,
	remoteURL string,
	branch string,
) (string, error) {
	output, err := runGit(
		ctx, work, gitAuthEnv(token), nil,
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
}

func (g *GitHub) ensureDraftPR(
	ctx context.Context,
	token string,
	request Request,
	result Result,
) (pullRequest, error) {
	title := safeTitle(request.Incident.Title)
	body := publicationBody(request, result)
	if request.Existing.PRNumber > 0 {
		var existing pullRequest
		path := "/repos/" + request.Repository.GitHubRepository + "/pulls/" +
			strconv.Itoa(request.Existing.PRNumber)
		if err := g.api(ctx, token, http.MethodGet, path, nil, &existing); err != nil {
			return pullRequest{}, err
		}
		if !existing.Draft || existing.Head.Ref != result.HeadBranch {
			return pullRequest{}, errors.New("recorded pull request is no longer the expected draft")
		}
		var updated pullRequest
		err := g.api(ctx, token, http.MethodPatch, path, map[string]any{
			"title": title,
			"body":  body,
			"base":  request.Repository.GitHubBaseBranch,
		}, &updated)
		return updated, err
	}

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

func publicationBody(request Request, result Result) string {
	return fmt.Sprintf(
		"## Responder task\n\n%s\n\n## Publication proof\n\n"+
			"- Coop session: `%s`\n- Reviewed parent: `%s`\n- Reviewed tree: `%s`\n"+
			"- Publication commit: `%s`\n- Gate: `%s`\n- Rebase: `%s`\n\n"+
			"This is a draft PR. Responder did not merge, deploy, sign, or change infrastructure.\n",
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
