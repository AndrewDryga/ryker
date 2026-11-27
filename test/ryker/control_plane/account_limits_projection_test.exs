defmodule Ryker.ControlPlane.AccountLimitsProjectionTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.AccountLimitsProjection

  @now ~U[2026-11-21 01:10:00Z]

  test "controller access is separate from allowance evidence" do
    entries =
      AccountLimitsProjection.controller_entries(%{
        "codex@ready" => %{state: :configured},
        "claude@missing" => %{state: :missing},
        "claude@refused" => %{state: :refused},
        "codex@unreadable" => %{state: :unavailable}
      })

    assert entries["codex@ready"].state == :unavailable
    assert entries["codex@ready"].windows == []
    assert entries["claude@missing"].state == :not_signed_in
    assert entries["claude@refused"].state == :sign_in_again
    assert entries["codex@unreadable"].state == :access_unavailable
  end

  defp account(name, fields) do
    Map.merge(
      %{
        "account" => name,
        "sign_in" => "signed_in",
        "checked_at" => "2026-11-21T01:05:00Z",
        "attempted_at" => "2026-11-21T01:05:00Z",
        "error" => nil,
        "plan" => "pro",
        "auth" => nil,
        "note" => nil,
        "limits" => [],
        "reset_credits" => nil
      },
      fields
    )
  end

  defp limit(name, fields) do
    Map.merge(
      %{
        "name" => name,
        "used_percent" => nil,
        "remaining" => nil,
        "resets_at" => nil,
        "available" => nil,
        "note" => nil
      },
      fields
    )
  end

  defp entries(accounts, now \\ @now),
    do: AccountLimitsProjection.entries([%{accounts: accounts}], now)

  # Andrew's task, 2026-11-20: "5-hour limit · 18% left · resets in 42 min".
  test "each window says how much is left and when it resets, in the provider's own units" do
    resets = "2026-11-21T01:52:00Z"

    %{"codex@personal" => entry} =
      entries([
        account("codex@personal", %{
          "limits" => [
            limit("5-hour", %{"used_percent" => 82, "resets_at" => resets}),
            limit("Weekly", %{"used_percent" => 40.4}),
            limit("Fable 5", %{"used_percent" => 3}),
            limit("Credits", %{"remaining" => "unlimited"}),
            limit("Weekly credits", %{"remaining" => "12.50"}),
            limit("Monthly credits", %{"remaining" => "45229.7698855000"}),
            limit("Daily credits", %{"remaining" => "300.0"}),
            limit("Extra usage", %{"note" => "disabled"})
          ],
          "reset_credits" => %{"available" => 2, "expires_at" => ["2026-12-21T03:00:00Z"]}
        })
      ])

    assert entry.state == :current
    assert entry.plan == "pro"
    assert entry.checked_at == ~U[2026-11-21 01:05:00Z]

    assert Enum.map(entry.windows, &{&1.label, &1.detail}) == [
             {"5-hour limit", "18% left"},
             {"Weekly limit", "60% left"},
             {"Fable 5", "97% left"},
             {"Credits", "unlimited"},
             {"Weekly credits", "12.50 left"},
             {"Monthly credits", "45,229.77 left"},
             {"Daily credits", "300 left"},
             {"Extra usage", "disabled"}
           ]

    assert hd(entry.windows).resets_at == ~U[2026-11-21 01:52:00Z]
    assert entry.resets == %{available: 2, expires_at: [~U[2026-12-21 03:00:00Z]]}
    assert entry.used_up == nil
  end

  # A model whose account is out of a window says so beside its account.
  test "a window the provider closed, or one used in full, is used up" do
    %{"codex@personal" => entry} =
      entries([
        account("codex@personal", %{
          "limits" => [
            limit("Weekly", %{"used_percent" => 40}),
            limit("5-hour", %{"used_percent" => 100, "resets_at" => "2026-11-21T01:52:00Z"})
          ]
        })
      ])

    assert entry.used_up.label == "5-hour limit"
    assert entry.used_up.detail == "used up"

    %{"codex@other" => closed} =
      entries([
        account("codex@other", %{
          "limits" => [limit("Weekly", %{"used_percent" => 70, "available" => false})]
        })
      ])

    assert closed.used_up.label == "Weekly limit"
    assert closed.credits == nil

    # An account out of its window can still spend credits it has left: say so
    # beside it rather than read as blocked (VA1, 2026-11-21: every model said
    # "Weekly limit used up" while 59,231.90 credits were left).
    %{"codex@funded" => funded} =
      entries([
        account("codex@funded", %{
          "limits" => [
            limit("Weekly", %{"used_percent" => 100}),
            limit("Credits", %{"remaining" => "59231.9000"})
          ]
        })
      ])

    assert funded.used_up.label == "Weekly limit"
    assert {funded.credits.label, funded.credits.detail} == {"Credits", "59,231.90 left"}
  end

  # The worker reads every five minutes; a check four reads old, or one whose
  # latest read failed, may no longer hold.
  test "a check gone old, or a failed read, keeps its figures as going stale" do
    usable = [limit("5-hour", %{"used_percent" => 10})]

    assert entries([account("codex@a", %{"limits" => usable})], ~U[2026-11-21 01:25:00Z])[
             "codex@a"
           ].state ==
             :current

    assert entries([account("codex@a", %{"limits" => usable})], ~U[2026-11-21 01:25:01Z])[
             "codex@a"
           ].state ==
             :stale

    failed =
      account("codex@a", %{
        "limits" => usable,
        "attempted_at" => "2026-11-21T01:09:00Z",
        "error" => "unavailable"
      })

    assert %{state: :stale, windows: [_window]} = entries([failed])["codex@a"]
  end

  test "an account with nothing reported says its limit is unavailable, or why" do
    assert entries([
             account("claude@work", %{
               "sign_in" => "not_signed_in",
               "checked_at" => nil,
               "attempted_at" => nil,
               "plan" => nil
             })
           ])[
             "claude@work"
           ].state == :not_signed_in

    assert entries([account("claude@work", %{"sign_in" => "sign_in_again"})])["claude@work"].state ==
             :sign_in_again

    assert entries([account("codex@key", %{"auth" => "API key", "plan" => nil})])["codex@key"]
           |> Map.take([:state, :auth]) ==
             %{state: :unavailable, auth: "API key"}

    assert entries([
             account("codex@never", %{"checked_at" => nil, "attempted_at" => nil, "plan" => nil})
           ])[
             "codex@never"
           ].state == :unavailable
  end

  # Two workers may hold the same account; its newer check is the one shown.
  test "an account held by two workers shows its newer check once" do
    older =
      account("codex@shared", %{
        "checked_at" => "2026-11-21T00:50:00Z",
        "attempted_at" => "2026-11-21T00:50:00Z",
        "plan" => "old"
      })

    newer = account("codex@shared", %{"plan" => "new"})

    for reports <- [
          [%{accounts: [older]}, %{accounts: [newer]}],
          [%{accounts: [newer]}, %{accounts: [older]}]
        ] do
      assert %{"codex@shared" => %{plan: "new"}} = AccountLimitsProjection.entries(reports, @now)
    end
  end
end
