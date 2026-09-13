defmodule Ryker.Publication.FollowupExecutorTest do
  use ExUnit.Case, async: true

  alias Ryker.Publication.FollowupExecutor

  defmodule API do
    def get_publication_status(_client, _repository, _number), do: {:ok, %{"state" => "open"}}
  end

  defmodule RaisingAPI do
    def get_publication_status(_client, _repository, _number), do: raise("GitHub adapter crashed")
  end

  defmodule ThrowingAPI do
    def get_publication_status(_client, _repository, _number), do: throw(:adapter_threw)
  end

  defmodule KilledAPI do
    def get_publication_status(_client, _repository, _number),
      do: Process.exit(self(), :kill)
  end

  defmodule SlowAPI do
    def get_publication_status(_client, _repository, _number) do
      Process.sleep(375)
      {:ok, %{"state" => "open"}}
    end
  end

  defmodule Custody do
    def admit_wakeup(_event_ref, _lease_ref), do: {:error, :not_used}
    def confirm_delivery(_event_ref, _lease_ref, _receipt), do: {:error, :not_used}
    def delivery_request(_event), do: {:error, :not_used}

    def reconcile_verification(_publication_ref, _lease_ref, _interval_seconds),
      do: {:ok, %{verification: :recorded}}

    def renew_delivery(_event_ref, _lease_ref, _lease_seconds), do: {:ok, %{}}
    def renew_poll(_publication_ref, _lease_ref, _lease_seconds), do: {:ok, %{}}
    def store_poll(_publication_ref, _lease_ref, status, _interval_seconds), do: {:ok, status}
  end

  defmodule FailingCustody do
    def admit_wakeup(_event_ref, _lease_ref), do: {:error, :delivery_lease_lost}
    def confirm_delivery(_event_ref, _lease_ref, _receipt), do: {:error, :not_used}
    def delivery_request(_event), do: {:error, :not_used}

    def reconcile_verification(_publication_ref, _lease_ref, _interval_seconds),
      do: {:error, :verification_lease_lost}

    def renew_delivery(_event_ref, _lease_ref, _lease_seconds),
      do: {:error, :delivery_lease_lost}

    def renew_poll(_publication_ref, _lease_ref, _lease_seconds),
      do: {:error, :poll_lease_lost}

    def store_poll(_publication_ref, _lease_ref, _status, _interval_seconds),
      do: {:error, :not_used}
  end

  test "polling and verification keep the exact claim and lease settings" do
    claim = poll_claim()

    assert {:ok, %{phase: :poll, followup: %{"state" => "open"}}} =
             FollowupExecutor.run_poll(claim, options())

    verifying = put_in(claim.followup.verification_event_ref, "lifecycle:event:1")

    assert {:ok, %{phase: :verification, followup: %{verification: :recorded}}} =
             FollowupExecutor.run_poll(verifying, options())

    assert FollowupExecutor.run_poll(
             verifying,
             options(custody: FailingCustody)
           ) == {:error, :verification_lease_lost}
  end

  test "slow callbacks renew while crashes remain structured and bounded" do
    claim = poll_claim()

    assert {:ok, %{phase: :poll}} =
             FollowupExecutor.run_poll(claim, options(api: SlowAPI, lease_seconds: 1))

    assert FollowupExecutor.run_poll(claim, options(api: RaisingAPI)) ==
             {:error, {:publication_followup_callback_crashed, "GitHub adapter crashed"}}

    assert FollowupExecutor.run_poll(claim, options(api: ThrowingAPI)) ==
             {:error, {:publication_followup_callback_crashed, :throw, :adapter_threw}}

    assert FollowupExecutor.run_poll(claim, options(api: KilledAPI)) ==
             {:error, {:publication_followup_callback_exit, :killed}}

    assert FollowupExecutor.run_poll(claim, options(custody: FailingCustody)) ==
             {:error, :poll_lease_lost}

    assert FollowupExecutor.run_poll(
             claim,
             options(api: SlowAPI, custody: FailingCustody, lease_seconds: 1)
           ) == {:error, :poll_lease_lost}
  end

  test "invalid claims and executor authority fail before any adapter call" do
    assert FollowupExecutor.run_poll(%{}, options()) ==
             {:error, {:invalid_publication_followup_executor, :claim}}

    assert FollowupExecutor.run_delivery(%{}, options()) ==
             {:error, {:invalid_publication_followup_executor, :claim}}

    delivery_claim = %{event: %{ref: "lifecycle:event:1"}, lease_ref: "lease:1"}

    assert FollowupExecutor.run_delivery(delivery_claim, options(custody: FailingCustody)) ==
             {:error, :delivery_lease_lost}

    assert FollowupExecutor.run_poll(poll_claim(), :invalid) ==
             {:error, {:invalid_publication_followup_executor, :options}}

    assert FollowupExecutor.run_poll(poll_claim(), api: API, api: API) ==
             {:error, {:invalid_publication_followup_executor, :options}}

    assert FollowupExecutor.run_poll(poll_claim(), adapters: %{}, api: API, client: nil) ==
             {:error, {:invalid_publication_followup_executor, :settings}}

    assert FollowupExecutor.run_poll(poll_claim(), api: API, client: nil) ==
             {:error, {:invalid_publication_followup_executor, :options}}
  end

  defp poll_claim do
    %{
      followup: %{verification_event_ref: nil, verified_at: nil},
      lease_ref: "lease:1",
      publication: %{
        github_repository: "acme/ryker",
        pull_request_number: 91,
        ref: "publication:1"
      }
    }
  end

  defp options(overrides \\ []) do
    [
      adapters: %{"slack" => :unused},
      api: API,
      client: nil,
      custody: Custody,
      interval_seconds: 120,
      lease_seconds: 60
    ]
    |> Keyword.merge(overrides)
  end
end
