defmodule Ryker.CredoChecks.RuntimeSafetyChecksTest do
  # Fixture coverage for the checks that guard runtime behaviour: the process
  # dictionary, unsafe deserialization, silent `match?` value tests,
  # count-against-zero reads, timestamp truncation in changesets, the vendor
  # wrapper seam and inline PubSub broadcasts. Each gets a probe it must flag
  # and a compliant probe it must not.
  use ExUnit.Case, async: true

  import Ryker.CredoCheckProbe

  @context "lib/ryker/sprockets.ex"
  @changeset "lib/ryker/sprockets/sprocket_changeset.ex"
  @test_file "test/ryker/sprockets_test.exs"

  setup_all do
    load()
  end

  describe "Ryker.Checks.NoProcessDictionary" do
    test "flags Process.put stashing ambient state" do
      source = """
      defmodule Ryker.Sprockets do
        def act_for(viewer), do: Process.put(:viewer, viewer)
      end
      """

      assert [issue] = issues(process_dictionary(), source, @context)
      assert issue.check == process_dictionary()
      assert issue.trigger == "Process.put"
      assert issue.line_no == 2
      assert issue.message =~ "explicit argument"
    end

    test "allows threading the actor and reading the dictionary" do
      source = """
      defmodule Ryker.Sprockets do
        def save(sprocket, actor_ref), do: Repo.update(change(sprocket, actor_ref: actor_ref))
        def callers, do: Process.get(:"$callers")
      end
      """

      assert issues(process_dictionary(), source, @context) == []
    end

    test "ignores test sources" do
      source = """
      defmodule Ryker.SprocketsTest do
        def stash(viewer), do: Process.put(:viewer, viewer)
      end
      """

      assert issues(process_dictionary(), source, @test_file) == []
    end
  end

  describe "Ryker.Checks.NoUnsafeDeserialization" do
    test "flags :erlang.binary_to_term even with :safe" do
      source = """
      defmodule Ryker.Sprockets do
        def decode(cursor), do: :erlang.binary_to_term(cursor, [:safe])
      end
      """

      assert [issue] = issues(unsafe_deserialization(), source, @context)
      assert issue.check == unsafe_deserialization()
      assert issue.trigger == ":erlang.binary_to_term"
      assert issue.line_no == 2
      assert issue.message =~ "size"
    end

    test "flags the non-executable variant and runtime code evaluation" do
      source = """
      defmodule Ryker.Sprockets do
        def decode(cursor), do: Plug.Crypto.non_executable_binary_to_term(cursor, [:safe])
        def evaluate(code), do: Code.eval_string(code)
        def evaluate_quoted(ast), do: Code.eval_quoted(ast)
      end
      """

      assert triggers(unsafe_deserialization(), source, @context) == [
               "Code.eval_quoted",
               "Code.eval_string",
               "Plug.Crypto.non_executable_binary_to_term"
             ]
    end

    test "allows a bounded Base64 and Jason decode" do
      source = """
      defmodule Ryker.Sprockets do
        def decode(cursor) do
          with {:ok, json} <- Base.url_decode64(cursor, padding: false),
               true <- byte_size(json) <= 512 do
            Jason.decode(json)
          end
        end
      end
      """

      assert issues(unsafe_deserialization(), source, @context) == []
    end
  end

  describe "Ryker.Checks.MatchOnMapFieldValue" do
    test "flags a match? testing a field value through a bare map pattern" do
      source = """
      defmodule Ryker.Sprockets do
        def secure?(config), do: match?(%{public_https: true}, config)
      end
      """

      assert [issue] = issues(match_on_value(), source, @context)
      assert issue.check == match_on_value()
      assert issue.trigger == "match?"
      assert issue.line_no == 2
      assert issue.message =~ "silently always-false"
    end

    test "allows shape tests and a struct pattern the compiler checks" do
      source = """
      defmodule Ryker.Sprockets do
        def ok?(result), do: match?({:ok, _}, result)
        def turn?(value), do: match?(%Turn{}, value)
        def settings?(result), do: match?({:ok, %{}}, result)
        def blocked?(turn), do: match?(%Turn{status: :blocked}, turn)
      end
      """

      assert issues(match_on_value(), source, @context) == []
    end
  end

  describe "Ryker.Checks.RepoExistsOverCount" do
    test "flags a count compared against zero" do
      source = """
      defmodule Ryker.Sprockets do
        def any?(queryable), do: Repo.aggregate(queryable, :count) > 0
      end
      """

      assert [issue] = issues(exists_over_count(), source, @context)
      assert issue.check == exists_over_count()
      assert issue.trigger == "Repo.aggregate"
      assert issue.line_no == 2
      assert issue.message =~ "Repo.exists?"
    end

    test "flags the reversed and the piped spellings" do
      source = """
      defmodule Ryker.Sprockets do
        def none?(queryable), do: 0 == Ryker.Repo.aggregate(queryable, :count)
        def any?(queryable), do: queryable |> Repo.aggregate(:count) > 0
      end
      """

      assert triggers(exists_over_count(), source, @context) == [
               "Repo.aggregate",
               "Repo.aggregate"
             ]
    end

    test "allows Repo.exists? and a count compared against a real threshold" do
      source = """
      defmodule Ryker.Sprockets do
        def any?(queryable), do: Repo.exists?(queryable)
        def crowded?(queryable), do: Repo.aggregate(queryable, :count) > 5
      end
      """

      assert issues(exists_over_count(), source, @context) == []
    end

    test "leaves aggregates other than a count alone" do
      source = """
      defmodule Ryker.Sprockets do
        def owes?(queryable), do: Repo.aggregate(queryable, :sum, :amount) > 0
        def any?(queryable), do: queryable |> Repo.aggregate(:max, :seq) == 0
      end
      """

      assert issues(exists_over_count(), source, @context) == []
    end

    test "does not lint tests" do
      source = """
      defmodule Ryker.SprocketsTest do
        def any?(queryable), do: Repo.aggregate(queryable, :count) > 0
      end
      """

      assert issues(exists_over_count(), source, @test_file) == []
    end
  end

  describe "Ryker.Checks.ChangesetNoTruncate" do
    test "flags any truncate inside a changeset module" do
      source = """
      defmodule Ryker.Sprockets.SprocketChangeset do
        import Ecto.Changeset

        def delete(sprocket), do: change(sprocket, deleted_at: DateTime.truncate(stamp(), :second))
      end
      """

      assert [issue] = issues(changeset_truncate(), source, @changeset)
      assert issue.check == changeset_truncate()
      assert issue.trigger == "DateTime.truncate"
      assert issue.line_no == 4
      assert issue.message =~ ":utc_datetime_usec"
    end

    test "allows a truncate outside a changeset module" do
      source = """
      defmodule Ryker.Sprockets do
        def coarse(row), do: DateTime.truncate(row.inserted_at, :second)
      end
      """

      assert issues(changeset_truncate(), source, @context) == []
    end
  end

  describe "Ryker.Checks.VendorViaWrapper" do
    test "flags a raw HTTP client call outside a wrapper" do
      source = """
      defmodule Ryker.Sprockets do
        def fetch(request), do: Finch.request(request, Ryker.CoopFinch)
      end
      """

      assert [issue] = issues(vendor_wrapper(), source, @context)
      assert issue.check == vendor_wrapper()
      assert issue.trigger == "Finch.request"
      assert issue.line_no == 2
      assert issue.message =~ "IL-19"
    end

    test "flags every known raw client" do
      source = """
      defmodule Ryker.Sprockets do
        def a(url), do: Req.get!(url)
        def b(url), do: HTTPoison.get(url)
        def c(url), do: Tesla.get(url)
      end
      """

      assert triggers(vendor_wrapper(), source, @context) == [
               "HTTPoison.get",
               "Req.get!",
               "Tesla.get"
             ]
    end

    test "allows the client module itself, the pool's child spec and a wrapped call" do
      raw = """
      defmodule Ryker.Delivery.HTTPClient do
        def stream(request), do: Finch.stream(request, Ryker.CoopFinch, [], fn _, acc -> acc end)
      end
      """

      wrapped = """
      defmodule Ryker.Sprockets do
        def fetch(url), do: Ryker.Delivery.JSONClient.get(url)
      end
      """

      assert issues(vendor_wrapper(), raw, "lib/ryker/delivery/http_client.ex") == []
      assert issues(vendor_wrapper(), raw, "lib/ryker/application.ex") == []
      assert issues(vendor_wrapper(), wrapped, @context) == []
    end
  end

  describe "Ryker.Checks.InlineBroadcast" do
    test "flags a PubSub.broadcast at a mutation site" do
      source = """
      defmodule Ryker.Feedback do
        def record(entry) do
          Ryker.PubSub.broadcast(topic(entry), {:feedback_recorded, entry.id})
        end
      end
      """

      assert [issue] = issues(inline_broadcast(), source, "lib/ryker/feedback.ex")
      assert issue.check == inline_broadcast()
      assert issue.trigger == "PubSub.broadcast"
      assert issue.line_no == 3
      assert issue.message =~ "named per-event broadcast_"
    end

    test "allows a publish inside its own broadcast_* function" do
      source = """
      defmodule Ryker.Feedback do
        def record(entry), do: broadcast_feedback_recorded(entry)

        defp broadcast_feedback_recorded(entry) do
          Ryker.PubSub.broadcast(topic(entry), {:feedback_recorded, entry.id})
        end
      end
      """

      assert issues(inline_broadcast(), source, "lib/ryker/feedback.ex") == []
    end

    test "ignores the PubSub module itself" do
      source = """
      defmodule Ryker.PubSub do
        def publish(topic, message), do: Ryker.PubSub.broadcast(topic, message)
      end
      """

      assert issues(inline_broadcast(), source, "lib/ryker/pubsub.ex") == []
    end
  end

  defp process_dictionary, do: check("NoProcessDictionary")
  defp unsafe_deserialization, do: check("NoUnsafeDeserialization")
  defp match_on_value, do: check("MatchOnMapFieldValue")
  defp exists_over_count, do: check("RepoExistsOverCount")
  defp changeset_truncate, do: check("ChangesetNoTruncate")
  defp vendor_wrapper, do: check("VendorViaWrapper")
  defp inline_broadcast, do: check("InlineBroadcast")
end
