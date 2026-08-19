package slackinput

import "strings"

// PermanentError reports Slack addressing and installation failures that will
// have the same answer on every retry.
func PermanentError(err error) bool {
	if err == nil {
		return false
	}
	detail := strings.ToLower(strings.TrimSpace(err.Error()))
	for _, marker := range []string{
		"channel_not_found", "user_not_found", "users_not_found",
		"message_not_found", "is_archived", "invalid_auth", "not_authed",
		"account_inactive", "token_revoked", "missing_scope",
		"not_allowed_token_type",
	} {
		if strings.Contains(detail, marker) {
			return true
		}
	}
	return false
}
