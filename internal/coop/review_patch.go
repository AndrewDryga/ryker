package coop

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
)

type ReviewPatchReader interface {
	ReviewPatch(context.Context, string) (ReviewPatchArtifact, error)
}

func CompleteReviewPatch(
	ctx context.Context,
	review Review,
	client any,
) (Review, error) {
	if review.PatchBytes == 0 || review.PatchDigest == "" {
		if review.PatchTruncated || len(review.Patch) == 0 {
			return review, errors.New("Coop review did not bind a complete patch artifact")
		}
		return review, nil
	}
	if int64(len(review.Patch)) != review.PatchBytes || review.PatchTruncated {
		reader, ok := client.(ReviewPatchReader)
		if !ok {
			return review, errors.New("Coop client cannot retrieve the complete review patch")
		}
		artifact, err := reader.ReviewPatch(ctx, review.PatchArtifactID)
		if err != nil {
			return review, err
		}
		if artifact.Digest != "" && artifact.Digest != review.PatchDigest {
			return review, errors.New("Coop review patch ETag does not match the review dossier")
		}
		review.Patch = artifact.Patch
	}
	if int64(len(review.Patch)) != review.PatchBytes {
		return review, fmt.Errorf(
			"Coop review patch is %d bytes, expected %d",
			len(review.Patch), review.PatchBytes,
		)
	}
	digest := sha256.Sum256(review.Patch)
	if hex.EncodeToString(digest[:]) != review.PatchDigest {
		return review, errors.New("Coop review patch digest does not match the review dossier")
	}
	review.PatchTruncated = false
	return review, nil
}
