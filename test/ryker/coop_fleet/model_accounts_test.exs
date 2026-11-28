defmodule Ryker.CoopFleet.ModelAccountsTest do
  use Ryker.DataCase, async: false
  alias Ryker.{Config, Credentials, Settings}
  alias Ryker.CoopFleet.ModelAccounts

  setup do
    Config.put_override(:credential_key, :binary.copy(<<41>>, 32))

    document = %{
      "version" => 1,
      "provider" => "claude",
      "selection" => "claude-oauth",
      "credential" => "old-access-token-canary",
      "refresh_token" => "old-refresh-token-canary",
      "principal" => "account:organization",
      "scopes" => ["user:inference"],
      "expires_at" => DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()
    }

    {:ok, _metadata} = ModelAccounts.put("claude", "work", document, "test")
    :ok
  end

  test "account status belongs to the configured workspace" do
    {:ok, snapshot} = Settings.initialize("control-plane:local")
    assert ModelAccounts.statuses("other-workspace") == {:error, :model_workspace_not_configured}
    assert {:ok, statuses} = ModelAccounts.statuses(snapshot.work.workspace_ref)
    assert Map.keys(statuses) == snapshot.work.model_accounts
    refute inspect(statuses) =~ "canary"
  end

  test "status is redacted and never renews access, including expired refreshable OAuth" do
    {:ok, before} = Credentials.fetch(:model_account, "claude:work")
    assert ModelAccounts.status("claude@work") == %{state: :configured, method: "claude-oauth"}
    assert {:ok, ^before} = Credentials.fetch(:model_account, "claude:work")

    expired =
      Jason.decode!(before)
      |> Map.drop(["epoch"])
      |> Map.put("expires_at", DateTime.to_iso8601(DateTime.add(Ryker.Repo.now!(), -60)))

    {:ok, _} = ModelAccounts.put("claude", "work", expired, "test")
    assert %{state: :configured} = ModelAccounts.status("claude@work")
    refute inspect(ModelAccounts.status("claude@work")) =~ "canary"
    assert %{state: :missing} = ModelAccounts.status("codex@absent")
  end

  test "status distinguishes provider refusal from missing access" do
    assert ModelAccounts.prepare("claude", "work", fn _ -> {:error, :refused} end) ==
             {:error, :model_account_refused}

    assert %{state: :refused} = ModelAccounts.status("claude@work")
    :ok = ModelAccounts.remove("claude", "work", "test")
    assert ModelAccounts.status("claude@work") == %{state: :missing}
  end

  test "a normal OAuth refresh keeps the account epoch and publishes the rotated grant" do
    {:ok, before} = ModelAccounts.current("claude", "work")

    assert {:ok, next} =
             ModelAccounts.prepare("claude", "work", fn document ->
               assert document["refresh_token"] == "old-refresh-token-canary"

               {:ok,
                ~s({"access_token":"issued-access-token-canary","refresh_token":"issued-refresh-token-canary","expires_in":3600})}
             end)

    assert next["epoch"] == before["epoch"]
    assert next["credential"] == "issued-access-token-canary"
    assert next["refresh_token"] == "issued-refresh-token-canary"
    refute Map.has_key?(next, "renewal")
    assert {:ok, metadata} = ModelAccounts.metadata("claude", "work")
    refute Jason.encode!(metadata) =~ "issued-access-token"
  end

  test "an invalid successful renewal stays encrypted and is completed without replay" do
    answer =
      ~s({"access_token":"retained-access-token-canary","refresh_token":"retained-refresh-token-canary","expires_in":"invalid"})

    assert ModelAccounts.prepare("claude", "work", fn _ -> {:ok, answer} end) ==
             {:error, :model_issued_response_needs_reconciliation}

    assert ModelAccounts.prepare("claude", "work", fn _ ->
             flunk("replayed a renewal after receiving issued credentials")
           end) == {:error, :model_issued_response_needs_reconciliation}

    {:ok, encoded} = Credentials.fetch(:model_account, "claude:work")
    document = Jason.decode!(encoded)
    assert document["renewal"]["response"] == answer
    assert "retained-access-token-canary" in Credentials.redaction_values()
    assert "retained-refresh-token-canary" in Credentials.redaction_values()
    assert %{state: :needs_reconciliation} = ModelAccounts.status("claude@work")
  end

  test "malformed issued tokens keep the exact response for reconciliation" do
    answer =
      Jason.encode!(%{
        "access_token" => "issued\nunsafe-canary",
        "refresh_token" => "rotated-safe-canary",
        "expires_in" => 3600
      })

    assert ModelAccounts.prepare("claude", "work", fn _ -> {:ok, answer} end) ==
             {:error, :model_issued_response_needs_reconciliation}

    {:ok, encoded} = Credentials.fetch(:model_account, "claude:work")
    assert Jason.decode!(encoded)["renewal"]["response"] == answer
  end

  test "only an explicit provider grant refusal invalidates the saved login" do
    {:ok, saved} = Credentials.fetch(:model_account, "claude:work")

    for {status, body, reason} <- [
          {400, ~s({"error":"invalid_grant"}), :refused},
          {401, ~s({"error":{"code":"refresh_token_reused"}}), :refused},
          {400, ~s({"error":"invalid_request"}), :uncertain},
          {403, ~s({"error":"invalid_grant"}), :uncertain},
          {401, "not json", :uncertain}
        ] do
      stream = fn _request, _pool, _timeout, _limit -> {:ok, %{status: status, body: body}} end

      assert Ryker.CoopFleet.ModelAccountProvider.refresh(Jason.decode!(saved), stream) ==
               {:error, reason}
    end
  end

  test "one renewal owns the account while concurrent readers use the still valid access" do
    owner = self()

    refresh =
      Task.async(fn ->
        ModelAccounts.prepare("claude", "work", fn _ ->
          send(owner, {:renewal_entered, self()})

          receive do
            :continue -> {:ok, ~s({"access_token":"new-access-token-canary","expires_in":3600})}
          end
        end)
      end)

    assert_receive {:renewal_entered, pid}

    assert {:ok, current} =
             ModelAccounts.prepare("claude", "work", fn _ -> flunk("concurrent refresh") end)

    assert current["credential"] == "old-access-token-canary"
    send(pid, :continue)
    assert {:ok, next} = Task.await(refresh)
    assert next["credential"] == "new-access-token-canary"
  end

  test "a response from an old epoch cannot overwrite a newly selected account" do
    owner = self()

    refresh =
      Task.async(fn ->
        ModelAccounts.prepare("claude", "work", fn _ ->
          send(owner, {:renewal_entered, self()})

          receive do
            :continue -> {:ok, ~s({"access_token":"old-epoch-issued-canary","expires_in":3600})}
          end
        end)
      end)

    assert_receive {:renewal_entered, pid}

    assert {:ok, _metadata} =
             ModelAccounts.put(
               "claude",
               "work",
               %{
                 "version" => 1,
                 "provider" => "claude",
                 "selection" => "apikey",
                 "credential" => "replacement-api-key-canary"
               },
               "test"
             )

    send(pid, :continue)
    assert Task.await(refresh) == {:error, :model_account_changed}
    assert {:ok, current} = ModelAccounts.current("claude", "work")
    assert current["credential"] == "replacement-api-key-canary"
  end
end
