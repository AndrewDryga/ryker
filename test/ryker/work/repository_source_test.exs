defmodule Ryker.Work.RepositorySourceTest do
  use ExUnit.Case, async: true

  alias Ryker.Work.RepositorySource

  @default_commit String.duplicate("a", 40)
  @selected_commit String.duplicate("b", 40)
  @base_commit String.duplicate("c", 40)
  @admitted_tree String.duplicate("d", 40)

  describe "the request union" do
    test "the four exact selector shapes are the whole authorized request language" do
      assert RepositorySource.parse(%{"kind" => "default"}) == {:ok, %{"kind" => "default"}}

      assert RepositorySource.parse(%{"kind" => "branch", "name" => "feature/payments"}) ==
               {:ok, %{"kind" => "branch", "name" => "feature/payments"}}

      assert RepositorySource.parse(%{"kind" => "pull_request", "number" => 514}) ==
               {:ok, %{"kind" => "pull_request", "number" => 514}}

      sha = String.duplicate("0123456789abcdef", 2) <> String.duplicate("0", 8)

      assert RepositorySource.parse(%{"kind" => "commit", "sha" => sha}) ==
               {:ok, %{"kind" => "commit", "sha" => sha}}

      assert RepositorySource.default() == %{"kind" => "default"}
    end

    test "a malformed selector is refused instead of normalized into something adjacent" do
      malformed = [
        {nil, :kind},
        {"default", :kind},
        {%{}, :kind},
        {%{"kind" => "Default"}, :kind},
        {%{"kind" => "tag", "name" => "v1"}, :kind},
        {%{"kind" => "default", "name" => "main"}, :fields},
        {%{"kind" => "branch"}, :fields},
        {%{"kind" => "branch", "name" => "main", "sha" => @default_commit}, :fields},
        {%{"kind" => "branch", "name" => ""}, :name},
        {%{"kind" => "branch", "name" => "refs/heads/main"}, :name},
        {%{"kind" => "branch", "name" => "-delete"}, :name},
        {%{"kind" => "branch", "name" => "feature/../escape"}, :name},
        {%{"kind" => "branch", "name" => "feature//double"}, :name},
        {%{"kind" => "branch", "name" => "feature/.hidden"}, :name},
        {%{"kind" => "branch", "name" => "feature/x.lock"}, :name},
        {%{"kind" => "branch", "name" => "feature/x@{now}"}, :name},
        {%{"kind" => "branch", "name" => "feature x"}, :name},
        {%{"kind" => "branch", "name" => "feature/x~1"}, :name},
        {%{"kind" => "branch", "name" => "feature/x^"}, :name},
        {%{"kind" => "branch", "name" => "feature:x"}, :name},
        {%{"kind" => "branch", "name" => "feature/x?"}, :name},
        {%{"kind" => "branch", "name" => "feature/x*"}, :name},
        {%{"kind" => "branch", "name" => "feature/x[0]"}, :name},
        {%{"kind" => "branch", "name" => "feature\\x"}, :name},
        {%{"kind" => "branch", "name" => "feature/x\t"}, :name},
        {%{"kind" => "branch", "name" => "@"}, :name},
        {%{"kind" => "branch", "name" => "trailing/"}, :name},
        {%{"kind" => "branch", "name" => "trailing."}, :name},
        {%{"kind" => "branch", "name" => String.duplicate("b", 256)}, :name},
        {%{"kind" => "branch", "name" => "café"}, :name},
        {%{"kind" => "pull_request", "number" => 0}, :number},
        {%{"kind" => "pull_request", "number" => -1}, :number},
        {%{"kind" => "pull_request", "number" => 10_000_001}, :number},
        {%{"kind" => "pull_request", "number" => "514"}, :number},
        {%{"kind" => "pull_request", "number" => 5.0}, :number},
        {%{"kind" => "commit", "sha" => String.duplicate("a", 7)}, :sha},
        {%{"kind" => "commit", "sha" => String.duplicate("a", 39)}, :sha},
        {%{"kind" => "commit", "sha" => String.duplicate("a", 41)}, :sha},
        {%{"kind" => "commit", "sha" => String.duplicate("A", 40)}, :sha},
        {%{"kind" => "commit", "sha" => "HEAD"}, :sha},
        {%{"kind" => "commit", "sha" => String.duplicate("g", 40)}, :sha}
      ]

      for {value, field} <- malformed do
        assert RepositorySource.parse(value) == {:error, {:invalid_repository_source, field}},
               "expected #{inspect(value)} to be refused as #{inspect(field)}"
      end
    end

    test "a 64-character lowercase object id is accepted and an abbreviation is not" do
      sha256 = String.duplicate("9f", 32)

      assert {:ok, %{"kind" => "commit", "sha" => ^sha256}} =
               RepositorySource.parse(%{"kind" => "commit", "sha" => sha256})

      assert RepositorySource.parse(%{"kind" => "commit", "sha" => String.slice(sha256, 0, 12)}) ==
               {:error, {:invalid_repository_source, :sha}}
    end

    test "the caller cannot smuggle a repository, remote, path or raw ref into the request" do
      for value <- [
            %{"kind" => "branch", "name" => "main", "remote" => "upstream"},
            %{"kind" => "branch", "name" => "main", "repository" => "other"},
            %{"kind" => "default", "url" => "https://example.invalid/repo.git"},
            %{"kind" => "commit", "sha" => @default_commit, "path" => "/tmp/repo"},
            %{"kind" => "ref", "ref" => "refs/heads/main"}
          ] do
        assert {:error, {:invalid_repository_source, _field}} = RepositorySource.parse(value)
      end
    end

    test "the derived ref is the only thing a selector may name on the remote" do
      assert RepositorySource.derived_ref(%{"kind" => "default"}) == nil

      assert RepositorySource.derived_ref(%{"kind" => "branch", "name" => "feature/payments"}) ==
               "refs/heads/feature/payments"

      assert RepositorySource.derived_ref(%{"kind" => "pull_request", "number" => 514}) ==
               "refs/pull/514/head"

      assert RepositorySource.derived_ref(%{"kind" => "commit", "sha" => @default_commit}) == nil
    end
  end

  describe "the operation identity" do
    test "the same operation identity with a different selector conflicts" do
      branch = %{"kind" => "branch", "name" => "feature/payments"}

      assert RepositorySource.same?(branch, %{"kind" => "branch", "name" => "feature/payments"})
      refute RepositorySource.same?(branch, %{"kind" => "branch", "name" => "feature/billing"})
      refute RepositorySource.same?(branch, %{"kind" => "default"})
      refute RepositorySource.same?(branch, nil)
      refute RepositorySource.same?(nil, %{"kind" => "default"})
      assert RepositorySource.same?(nil, nil)

      refute RepositorySource.same?(
               %{"kind" => "pull_request", "number" => 514},
               %{"kind" => "pull_request", "number" => 515}
             )
    end
  end

  describe "the version 1 binding" do
    test "a resolved branch binding carries the exact request, refs, commits and proof time" do
      assert {:ok, binding} = RepositorySource.parse_binding(branch_binding())
      assert binding == branch_binding()
      assert binding["version"] == 1
    end

    test "a default binding pins the configured default identity for both selected and default" do
      assert {:ok, _binding} = RepositorySource.parse_binding(default_binding())

      assert RepositorySource.parse_binding(
               Map.put(default_binding(), "selected_commit", @selected_commit)
             ) == {:error, {:invalid_repository_source_binding, :selected_commit}}

      assert RepositorySource.parse_binding(
               Map.put(default_binding(), "selected_ref", "refs/heads/other")
             ) == {:error, {:invalid_repository_source_binding, :selected_ref}}
    end

    test "a commit binding has no selected ref and pins the requested object id" do
      binding = commit_binding()
      assert {:ok, ^binding} = RepositorySource.parse_binding(binding)

      assert RepositorySource.parse_binding(Map.put(binding, "selected_ref", "refs/heads/main")) ==
               {:error, {:invalid_repository_source_binding, :selected_ref}}

      assert RepositorySource.parse_binding(Map.put(binding, "selected_commit", @default_commit)) ==
               {:error, {:invalid_repository_source_binding, :selected_commit}}
    end

    test "a pull request binding keeps its number and optional trusted expected head" do
      binding = pull_request_binding()
      assert {:ok, ^binding} = RepositorySource.parse_binding(binding)

      with_expected = Map.put(binding, "pull_request_expected_head", @selected_commit)
      assert {:ok, ^with_expected} = RepositorySource.parse_binding(with_expected)

      # Trusted ingress may have attached the head it observed to the request
      # itself; Coop echoes it, and it is evidence about the resolved head rather
      # than part of the selector identity.
      echoed =
        Map.put(binding, "requested", %{
          "expected_head_commit" => @selected_commit,
          "kind" => "pull_request",
          "number" => 514
        })

      assert {:ok, ^binding} = RepositorySource.parse_binding(echoed)

      assert RepositorySource.parse_binding(
               Map.put(binding, "pull_request_expected_head", @default_commit)
             ) == {:error, {:invalid_repository_source_binding, :pull_request_expected_head}}

      assert RepositorySource.parse_binding(
               put_in(echoed, ["requested", "expected_head_commit"], @default_commit)
             ) == {:error, {:invalid_repository_source_binding, :pull_request_expected_head}}

      assert RepositorySource.parse_binding(
               Map.put(branch_binding(), "pull_request_expected_head", @selected_commit)
             ) == {:error, {:invalid_repository_source_binding, :pull_request_expected_head}}

      assert RepositorySource.parse_binding(Map.put(binding, "pull_request_number", 99)) ==
               {:error, {:invalid_repository_source_binding, :pull_request_number}}

      assert RepositorySource.parse_binding(Map.delete(binding, "pull_request_number")) ==
               {:error, {:invalid_repository_source_binding, :pull_request_number}}
    end

    # Coop migrates a pre-selector pull-request session into this shape from its
    # durable columns, which prove every field except a tree it never recorded.
    # Such a session has no persisted request on this side, and only then may
    # the tree be absent.
    test "only a historical binding with no persisted request may omit the admitted tree" do
      migrated = Map.delete(pull_request_binding(), "admitted_tree")

      assert RepositorySource.parse_binding(migrated) ==
               {:error, {:invalid_repository_source_binding, :admitted_tree}}

      assert RepositorySource.reconcile(migrated, %{"kind" => "pull_request", "number" => 514}) ==
               {:error, {:invalid_repository_source_binding, :admitted_tree}}

      assert RepositorySource.reconcile(migrated, nil) == {:ok, migrated}
    end

    test "a binding whose derived ref disagrees with its request is refused" do
      assert RepositorySource.parse_binding(
               Map.put(branch_binding(), "selected_ref", "refs/heads/other")
             ) == {:error, {:invalid_repository_source_binding, :selected_ref}}

      assert RepositorySource.parse_binding(Map.put(branch_binding(), "kind", "commit")) ==
               {:error, {:invalid_repository_source_binding, :kind}}
    end

    test "a binding outside its exact fields, version or bounds is refused" do
      malformed = [
        {Map.put(branch_binding(), "version", 2), :version},
        {Map.put(branch_binding(), "extra", true), :fields},
        {Map.delete(branch_binding(), "admitted_tree"), :admitted_tree},
        {Map.delete(branch_binding(), "base_commit"), :fields},
        {Map.put(branch_binding(), "remote_identity", ""), :remote_identity},
        {Map.put(branch_binding(), "remote_identity", String.duplicate("o", 257)),
         :remote_identity},
        {Map.put(branch_binding(), "default_ref", "main"), :default_ref},
        {Map.put(branch_binding(), "default_commit", "abc"), :default_commit},
        {Map.put(branch_binding(), "base_commit", "abc"), :base_commit},
        {Map.put(branch_binding(), "admitted_tree", "abc"), :admitted_tree},
        {Map.put(branch_binding(), "resolved_at", "2026-09-11 08:00:00"), :resolved_at},
        {Map.put(branch_binding(), "resolved_at", "2026-09-11T08:00:00+02:00"), :resolved_at},
        {Map.put(branch_binding(), "requested", %{"kind" => "tag"}), :requested},
        {%{}, :fields},
        {nil, :fields}
      ]

      for {value, field} <- malformed do
        assert RepositorySource.parse_binding(value) ==
                 {:error, {:invalid_repository_source_binding, field}},
               "expected #{inspect(value)} to be refused as #{inspect(field)}"
      end
    end

    test "a binding must answer the exact authorized request that was persisted" do
      assert RepositorySource.reconcile(
               branch_binding(),
               %{"kind" => "branch", "name" => "feature/payments"}
             ) == {:ok, branch_binding()}

      assert RepositorySource.reconcile(
               branch_binding(),
               %{"kind" => "branch", "name" => "feature/billing"}
             ) == {:error, {:invalid_repository_source_binding, :requested}}

      assert RepositorySource.reconcile(branch_binding(), %{"kind" => "default"}) ==
               {:error, {:invalid_repository_source_binding, :requested}}

      assert RepositorySource.reconcile(nil, %{"kind" => "default"}) ==
               {:error, {:invalid_repository_source_binding, :fields}}

      assert RepositorySource.reconcile(branch_binding(), nil) == {:ok, branch_binding()}
      assert RepositorySource.reconcile(nil, nil) == {:ok, nil}
    end
  end

  describe "the model-facing schema" do
    test "the request schema offers exactly the four authorized shapes" do
      schema = RepositorySource.json_schema()
      built = JSV.build!(schema)

      for value <- [
            %{"kind" => "default"},
            %{"kind" => "branch", "name" => "feature/payments"},
            %{"kind" => "pull_request", "number" => 514},
            %{"kind" => "commit", "sha" => @default_commit}
          ] do
        assert {:ok, _valid} = JSV.validate(value, built)
      end

      for value <- [
            %{"kind" => "tag", "name" => "v1"},
            %{"kind" => "branch"},
            %{"kind" => "branch", "name" => "main", "remote" => "upstream"},
            %{"kind" => "commit", "sha" => String.duplicate("A", 40)},
            %{"kind" => "pull_request", "number" => 0}
          ] do
        assert {:error, _invalid} = JSV.validate(value, built)
      end
    end

    test "every schema-valid request is accepted by the parser and the reverse holds" do
      built = JSV.build!(RepositorySource.json_schema())

      for value <- [
            %{"kind" => "default"},
            %{"kind" => "branch", "name" => "release/2026.09"},
            %{"kind" => "pull_request", "number" => 1},
            %{"kind" => "commit", "sha" => String.duplicate("f", 64)}
          ] do
        assert {:ok, _valid} = JSV.validate(value, built)
        assert {:ok, ^value} = RepositorySource.parse(value)
      end
    end
  end

  defp branch_binding do
    %{
      "admitted_tree" => @admitted_tree,
      "base_commit" => @base_commit,
      "default_commit" => @default_commit,
      "default_ref" => "refs/heads/main",
      "kind" => "branch",
      "remote_identity" => "origin",
      "requested" => %{"kind" => "branch", "name" => "feature/payments"},
      "resolved_at" => "2026-09-11T08:00:00Z",
      "selected_commit" => @selected_commit,
      "selected_ref" => "refs/heads/feature/payments",
      "version" => 1
    }
  end

  defp default_binding do
    %{
      "admitted_tree" => @admitted_tree,
      "base_commit" => @default_commit,
      "default_commit" => @default_commit,
      "default_ref" => "refs/heads/main",
      "kind" => "default",
      "remote_identity" => "origin",
      "requested" => %{"kind" => "default"},
      "resolved_at" => "2026-09-11T08:00:00Z",
      "selected_commit" => @default_commit,
      "selected_ref" => "refs/heads/main",
      "version" => 1
    }
  end

  defp commit_binding do
    %{
      "admitted_tree" => @admitted_tree,
      "base_commit" => @base_commit,
      "default_commit" => @default_commit,
      "default_ref" => "refs/heads/main",
      "kind" => "commit",
      "remote_identity" => "origin",
      "requested" => %{"kind" => "commit", "sha" => @selected_commit},
      "resolved_at" => "2026-09-11T08:00:00Z",
      "selected_commit" => @selected_commit,
      "selected_ref" => nil,
      "version" => 1
    }
  end

  defp pull_request_binding do
    %{
      "admitted_tree" => @admitted_tree,
      "base_commit" => @base_commit,
      "default_commit" => @default_commit,
      "default_ref" => "refs/heads/main",
      "kind" => "pull_request",
      "pull_request_number" => 514,
      "remote_identity" => "origin",
      "requested" => %{"kind" => "pull_request", "number" => 514},
      "resolved_at" => "2026-09-11T08:00:00Z",
      "selected_commit" => @selected_commit,
      "selected_ref" => "refs/pull/514/head",
      "version" => 1
    }
  end
end
