defmodule Ryker.GitHub.ReviewFixesTest do
  use Ryker.DataCase, async: false
  import Ecto.Changeset, only: [change: 2]
  alias Ryker.Delivery.JSONClient
  alias Ryker.Fixtures.GitHubActions, as: ActionFixture
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.GitHub.ReviewFixes
  alias Ryker.{Repo, Settings, Work}

  defmodule Requester do
    def request(
          _http,
          :get,
          "/repos/example/repository/collaborators/example-writer/permission",
          nil,
          _headers
        ) do
      send(self(), :permission_checked)

      {:ok,
       %{
         status: 200,
         body: %{"permission" => "write", "user" => %{"id" => Process.get(:writer_id, 123)}}
       }}
    end

    def request(http, :post, "/graphql", %{"query" => query}, _headers) do
      send(self(), :thread_checked)

      data =
        if String.contains?(query, "mutation"),
          do: %{
            "resolveReviewThread" => %{"thread" => %{"id" => "thread-one", "isResolved" => true}}
          },
          else: %{"node" => Process.get(:current_thread)}

      if String.contains?(query, "mutation") && http.token_provider.() != {:ok, "resolve-token"} do
        # Four retries on the published fixes failed because GitHub also checks contents write.
        {:ok, %{status: 200, body: %{"errors" => [%{"type" => "FORBIDDEN"}]}}}
      else
        {:ok, %{status: 200, body: %{"data" => data}}}
      end
    end
  end

  setup do
    %{publication: publication} =
      PublicationFixture.published!("review-fix-#{Ecto.UUID.generate()}")

    target = ActionFixture.publication_target()

    session =
      Work.Session
      |> Repo.get!(publication.session_id)
      |> change(publication_target: target)
      |> Repo.update!()

    publication =
      publication
      |> change(
        review_document:
          Map.put(publication.review_document, "parent_head", target["head_commit"])
      )
      |> Repo.update!()

    {:ok, settings} = Settings.initialize("control-plane:local")

    {:ok, settings} =
      Settings.save_github(
        %{enabled: true, app_id: 1234},
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
          name: "github-main",
          repository_ref: "ryker",
          repository_id: 17,
          installation_id: 41,
          ryker_actor_id: 30
        },
        settings.installation.revision,
        "control-plane:local"
      )

    Process.put(:current_thread, ActionFixture.review_thread(target, publication.commit_sha))

    http = %JSONClient{
      base_url: "https://api.github.com",
      finch: Ryker.CoopFinch,
      receive_timeout: 1000,
      token_provider: fn -> {:ok, "scoped-token"} end
    }

    configured = %{
      repository_full_name: "example/repository",
      repository_id: 17,
      review_client: %{http: http, requester: Requester},
      resolution_client: %{
        http: %{http | token_provider: fn -> {:ok, "resolve-token"} end},
        requester: Requester
      }
    }

    %{binding: %{session: session}, publication: publication, configured: configured}
  end

  test "only a selected, published, checked finding resolves with a current writer", %{
    binding: binding,
    configured: configured
  } do
    args = %{
      "thread_id" => "thread-one",
      "verification" => "The empty-input test passes on the published commit."
    }

    assert {:ok, %{"status" => "resolved", "verification" => verification}} =
             ReviewFixes.resolve(binding, args, configured)

    assert verification == args["verification"]
    assert_received :permission_checked
    assert_received :thread_checked
    assert_received :thread_checked

    assert ReviewFixes.resolve(binding, %{args | "thread_id" => "unselected"}, configured) ==
             {:error, :review_fix_not_verified}

    refute_received :permission_checked
    Process.put(:writer_id, 124)
    assert ReviewFixes.resolve(binding, args, configured) == {:error, :actor_not_authorized}
    assert_received :permission_checked
    refute_received :thread_checked
    Process.put(:writer_id, 123)

    assert ReviewFixes.resolve(binding, args, %{
             configured
             | resolution_client: configured.review_client
           }) == {:error, :thread_resolution_forbidden}
  end

  # The selected fixes were published and checked, but GitHub briefly returned
  # the old PR head. Four later resolution calls could never clear that receipt.
  test "an old push observation is rechecked against the current published head", %{
    binding: binding,
    publication: publication,
    configured: configured
  } do
    fixture =
      File.read!("testdata/github/review-resolution-after-push-observation.json")
      |> Jason.decode!()

    receipt =
      Map.put(publication.publication_receipt, "target_observation", fixture["observation"])

    publication
    |> change(
      publication_receipt: receipt,
      publication_receipt_fingerprint: Ryker.Publication.Receipt.fingerprint(receipt)
    )
    |> Repo.update!()

    assert {:ok, %{"status" => "resolved"}} =
             ReviewFixes.resolve(binding, fixture["request"], configured)

    assert_received :permission_checked
    assert_received :thread_checked
    assert_received :thread_checked

    Process.put(
      :current_thread,
      put_in(
        Process.get(:current_thread),
        ["pullRequest", "headRefOid"],
        String.duplicate("f", 40)
      )
    )

    assert ReviewFixes.resolve(binding, fixture["request"], configured) ==
             {:error, :review_changed}

    assert_received :permission_checked
    assert_received :thread_checked
    refute_received :thread_checked
  end

  test "an unpublished or unverified candidate never touches review threads", %{
    binding: binding,
    publication: publication,
    configured: configured
  } do
    args = %{"thread_id" => "thread-one", "verification" => "Checked."}

    for attributes <- [
          [
            status: :publish_pending,
            publication_receipt: nil,
            publication_receipt_fingerprint: nil,
            published_at: nil,
            published_delivery_receipt: nil,
            published_delivery_receipt_fingerprint: nil
          ],
          [review_document: Map.put(publication.review_document, "gate", "none")],
          [
            review_document:
              Map.put(publication.review_document, "parent_head", String.duplicate("f", 40))
          ]
        ] do
      changed = publication |> change(attributes) |> Repo.update!()
      assert {:error, reason} = ReviewFixes.resolve(binding, args, configured)
      assert reason in [:review_fix_not_published, :review_fix_not_verified]
      refute_received :permission_checked
      refute_received :thread_checked
      original = attributes |> Keyword.keys() |> Map.new(&{&1, Map.fetch!(publication, &1)})
      changed |> change(original) |> Repo.update!()
    end
  end
end
