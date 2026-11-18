defmodule Ryker.BrowserTestsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Artifacts
  alias Ryker.BrowserTests
  alias Ryker.ControlPlane.BrowserResults
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.{WorkerJob, WorkSessions}
  alias Ryker.Records
  alias Ryker.Settings
  alias Ryker.StateTools
  alias Ryker.Work

  defmodule Reader do
    def request(http, :get, "/user", nil, _headers) do
      {:ok, token} = http.token_provider.()

      if token == "revoked-token",
        do: {:ok, %{status: 401, body: %{}}},
        else: {:ok, %{status: 200, body: %{"id" => 7, "login" => "viewer", "type" => "User"}}}
    end

    def request(http, :get, "/repos/example/repository", nil, _headers) do
      {:ok, token} = http.token_provider.()

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => if(token == "wrong-repository", do: 18, else: 17),
           "permissions" => %{"pull" => token != "no-access-token", "push" => false}
         }
       }}
    end
  end

  setup do
    {:ok, settings} = Settings.initialize("control-plane:local")

    {:ok, settings} =
      Settings.save_github(
        %{enabled: true, app_id: 12},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "ryker", github_repository: "example/repository"},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "repository-app",
          repository_ref: "ryker",
          repository_id: 17,
          installation_id: 41,
          ryker_actor_id: 30
        },
        settings.installation.revision,
        "control-plane:local"
      )

    :ok
  end

  test "GitHub attachments get a protected stable link only when repository sign-in is configured" do
    binding = work!()
    github_episode = %{binding.episode | destination_transport: "github"}
    refute Artifacts.Outputs.delivery_supported?(github_episode)
    settings = Settings.fetch!()

    assert {:ok, _settings} =
             Settings.save_github(
               %{oauth_client_id: "example-oauth-client"},
               settings.installation.revision,
               "control-plane:local"
             )

    assert {:ok, _credential} =
             Ryker.Credentials.put(
               :github_oauth_secret,
               "primary",
               "example-oauth-secret",
               "control-plane:local"
             )

    Ryker.Config.put_override(:control_public_url, "https://ryker.example.test")
    assert Artifacts.Outputs.delivery_supported?(github_episode)

    select!(binding, ["selected"])
    projection = Artifacts.Shares.projections([binding.turn.id])[binding.turn.id]
    linked = Artifacts.Shares.append(String.duplicate("x", 20_000), projection.suffix)

    assert linked =~ "https://ryker.example.test/github/actions/results/#{binding.turn.id}"
    assert String.length(linked) < 24_096
    refute linked =~ "example-oauth-secret"
    Ryker.Config.put_override(:control_public_url, nil)
    refute Artifacts.Outputs.delivery_supported?(github_episode)
  end

  test "reports keep failed and untested outcomes immutable and scoped to the producing turn" do
    binding = work!()
    report = document()
    assert {:ok, first} = StateTools.Tools.call("record_browser_test", report, binding: binding)
    assert {:ok, ^first} = BrowserTests.record(report, binding)
    [saved] = BrowserTests.reports(binding.turn.id)
    assert saved.document == report
    assert saved.source["github_repository_id"] == 17
    assert BrowserTests.reports(Repo.generate_id()) == []
    stale = put_in(binding.turn.lease_ref, "stale-lease")
    assert BrowserTests.record(report, stale) == {:error, :state_tools_binding_not_authorized}
    assert {:ok, _second} = BrowserTests.record(Map.put(report, "title", "Retry"), binding)
    assert BrowserTests.reports(binding.turn.id) |> hd() |> Map.fetch!(:document) == report
    projection = Artifacts.Shares.projections([binding.turn.id])[binding.turn.id]
    summary = Artifacts.Shares.append("Menu checked.", projection.suffix)
    assert summary =~ "1 failed"
    assert summary =~ "1 untested"
    assert summary =~ "0 passed"

    assert {:ok, _third} = BrowserTests.record(Map.put(report, "title", "Final check"), binding)

    assert BrowserTests.record(Map.put(report, "title", "Extra"), binding) ==
             {:error, :browser_report_limit}

    assert {:ok, ^first} = BrowserTests.record(report, binding)
  end

  test "private images require current repository Read access and exact selected ownership" do
    binding = work!()
    assert {:ok, _report} = BrowserTests.record(document(), binding)
    # The existing product artwork stands in for image bytes in this custody test.
    data = File.read!(Application.app_dir(:ryker, "priv/static/brand/avatar.png"))

    metadata = %{
      "id" => "artifact:browser:menu",
      "name" => "menu.png",
      "media_type" => "image/png",
      "bytes" => byte_size(data),
      "sha256" => Ryker.Crypto.sha256_hex(data),
      "data" => data
    }

    assert {:ok, [_artifact]} = Artifacts.Outputs.put_many(binding.turn.id, [metadata])

    assert {:ok, before} =
             Artifacts.shared_results(binding.turn.id, "reader-token", requester: Reader)

    assert before.artifacts == []
    select!(binding, [metadata["id"]])

    assert {:ok, result} =
             Artifacts.shared_results(binding.turn.id, "reader-token", requester: Reader)

    assert hd(result.artifacts).data == data
    assert result.missing_images == 0

    image_conn = Plug.Test.conn(:get, "/github/actions/results/#{binding.turn.id}/images/menu")

    image_conn = %{
      image_conn
      | path_params: %{"turn" => binding.turn.id, "ref" => metadata["id"]}
    }

    image = BrowserResults.call(image_conn, :result_image, "reader-token", requester: Reader)
    assert image.status == 200
    assert image.resp_body == data
    assert Plug.Conn.get_resp_header(image, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(image, "content-type") == ["image/png"]
    revoked = BrowserResults.call(image_conn, :result_image, "revoked-token", requester: Reader)
    assert revoked.status == 404
    refute revoked.resp_body == data

    wrong_file = %{
      image_conn
      | path_params: %{"turn" => binding.turn.id, "ref" => "artifact:another-turn"}
    }

    assert BrowserResults.call(wrong_file, :result_image, "reader-token", requester: Reader).status ==
             404

    for token <- ["no-access-token", "wrong-repository", "revoked-token"] do
      assert Artifacts.shared_results(binding.turn.id, token, requester: Reader) ==
               {:error, :shared_results_unavailable}
    end

    assert Ryker.GitHubActions.authorize("repository-app", "reader-token", requester: Reader) ==
             {:error, :repository_access_required}

    html = result |> BrowserResults.html() |> IO.iodata_to_binary()
    assert html =~ "Failed"
    assert html =~ "Untested"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    assert html =~ "menu.png"
    changed = %{hd(result.artifacts) | sha256: String.duplicate("0", 64)}
    mismatch = BrowserResults.html(%{result | artifacts: [changed]}) |> IO.iodata_to_binary()
    assert mismatch =~ "Screenshot not retained yet or expired"
    refute mismatch =~ ">Open menu.png</a>"
    assert html =~ "task. Ryker verifies"
    Repo.delete_all(Artifacts.OutputArtifact.Query.by_turn_id(binding.turn.id))

    assert {:ok, expired} =
             Artifacts.shared_results(binding.turn.id, "reader-token", requester: Reader)

    assert expired.missing_images == 1
    assert IO.iodata_to_binary(BrowserResults.html(expired)) =~ "expired or are unavailable"
    assert hd(expired.reports).document == document()
  end

  test "an accepted result cannot add new browser evidence and invalid reports cannot claim success" do
    binding = work!()
    invalid = put_in(document(), ["cases", Access.at(0), "screenshot"], "../outside.png")
    assert BrowserTests.record(invalid, binding) == {:error, :invalid_browser_report}
    missing_digest = put_in(document(), ["cases", Access.at(0), "screenshot_sha256"], nil)
    assert BrowserTests.record(missing_digest, binding) == {:error, :invalid_browser_report}
    future = Map.put(document(), "observed_at", "9999-01-01T00:00:00Z")
    assert BrowserTests.record(future, binding) == {:error, :invalid_browser_report}
    assert BrowserTests.reports(binding.turn.id) == []
    candidate = "{}"
    digest = Ryker.Crypto.sha256_hex(candidate)

    Repo.update_all(Work.Turn.Query.by_id(binding.turn.id),
      set: [
        candidate: candidate,
        candidate_sha256: digest,
        candidate_attempt: 1,
        validation_intent: %{"verdict" => "accept"},
        validation_intent_fingerprint: digest
      ]
    )

    assert BrowserTests.record(document(), binding) ==
             {:error, :state_tools_binding_not_authorized}
  end

  defp select!(binding, refs) do
    Repo.update_all(Work.Turn.Query.by_id(binding.turn.id),
      set: [delivery_document: %{"outcome" => %{"artifact_refs" => refs}}]
    )
  end

  defp work! do
    id = Repo.generate_id()

    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "browser-test:#{id}",
          native_input_id: "browser-test:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} =
      WorkSessions.pin_episode(transition.episode.id, "test-policy", String.duplicate("a", 64),
        repository_ref: "ryker"
      )

    {:ok, claim} = Work.Custody.claim_next("browser:#{id}", 60)
    session = WorkerJob.pin!(claim.session)

    %{
      episode: claim.episode,
      session: session,
      turn: claim.turn,
      state_token: Records.token(claim.turn)
    }
  end

  defp document do
    case_data = %{
      "name" => "Mobile menu <script>",
      "status" => "failed",
      "steps" => ["Open menu", "Close menu"],
      "expected" => "Menu closes",
      "observed" => "Menu remains visible",
      "viewport" => %{"width" => 390, "height" => 844},
      "screenshot" => "menu.png",
      "screenshot_sha256" =>
        Ryker.Crypto.sha256_hex(
          File.read!(Application.app_dir(:ryker, "priv/static/brand/avatar.png"))
        )
    }

    %{
      "title" => "Mobile menu",
      "observed_at" => "2026-11-17T10:00:00Z",
      "revision" => %{
        "commit" => String.duplicate("a", 40),
        "tree" => String.duplicate("b", 40),
        "dirty" => true
      },
      "cases" => [
        case_data,
        %{
          case_data
          | "name" => "Keyboard navigation",
            "status" => "untested",
            "observed" => "Not exercised",
            "screenshot" => nil,
            "screenshot_sha256" => nil
        }
      ]
    }
  end
end
