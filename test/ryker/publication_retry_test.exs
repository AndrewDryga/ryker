defmodule Ryker.PublicationRetryTest do
  use ExUnit.Case, async: true
  alias Ryker.PublicationRetry

  test "publication retries carry finite facts and never provider payloads" do
    assert PublicationRetry.reason(%{
             "error_code" => "publication_grant_failed",
             "error_detail" => "Publication stage: grant. HTTP status: 503."
           }) == {:publication_worker_retry, "publication_grant_failed", 503}

    assert PublicationRetry.reason(%{
             "error_code" => "publication_git_push_failed",
             "error_detail" => "private-token-and-provider-body"
           }) == {:publication_worker_retry, "publication_git_push_failed", 0}

    assert PublicationRetry.diagnosis("publication_grant_failed", 503) == %{
             code: "publication_grant_failed",
             http_status: 503,
             stage: "requesting a fresh publication token"
           }

    assert PublicationRetry.reason(%{}) == nil
    assert PublicationRetry.reason(%{"error_code" => "private-provider-body"}) == nil
    assert PublicationRetry.diagnosis("publication_grant_failed", 999) == nil
  end
end
