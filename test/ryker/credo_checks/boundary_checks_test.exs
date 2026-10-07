defmodule Ryker.CredoChecks.BoundaryChecksTest do
  # Fixture coverage for the checks that keep each layer to its job: pure query
  # modules (IL-6), money never in a float (IL-12), preloads named by query
  # helpers, an `Ecto.Enum` for a fixed set of strings, whole hashes on the
  # console, and LiveView subscriptions only once connected (IL-18). Each gets
  # a probe it must flag and a compliant probe it must not.
  use ExUnit.Case, async: true
  import Ryker.CredoCheckProbe

  @context "lib/ryker/sprockets.ex"
  @query "lib/ryker/sprockets/sprocket_query.ex"
  @changeset "lib/ryker/sprockets/sprocket_changeset.ex"
  @console "lib/ryker/control_plane/sprockets_page.ex"
  @live "lib/ryker/control_plane/sprockets_live.ex"

  setup_all do
    load()
  end

  describe "Ryker.Checks.IL06QueryModulePure" do
    test "flags a Repo call inside a query module" do
      source = """
      defmodule Ryker.Sprockets.SprocketQuery do
        import Ecto.Query

        def load(queryable), do: Repo.all(queryable)
      end
      """

      assert [issue] = issues(il06(), source, @query)
      assert issue.check == il06()
      assert issue.trigger == "Repo.all"
      assert issue.line_no == 4
      assert issue.message =~ "IL-6"
    end

    test "allows a grouped Ryker.Repo alias, which is not a Repo call" do
      source = """
      defmodule Ryker.Sprockets.SprocketQuery do
        import Ecto.Query
        alias Ryker.Repo.{Filter, Paginator}

        def all, do: from(sprocket in Sprocket, as: :sprocket)
      end
      """

      assert issues(il06(), source, @query) == []
    end

    test "ignores a Repo call outside a query module" do
      source = """
      defmodule Ryker.Sprockets do
        def load(queryable), do: Repo.all(queryable)
      end
      """

      assert issues(il06(), source, @context) == []
    end
  end

  describe "Ryker.Checks.IL12NoFloatMoney" do
    test "flags a money-named :float schema field" do
      source = """
      defmodule Ryker.Accounting.Entry do
        use Ecto.Schema

        schema "accounting_entries" do
          field :amount_due, :float
        end
      end
      """

      assert [issue] = issues(il12(), source, "lib/ryker/accounting/entry.ex")
      assert issue.check == il12()
      assert issue.trigger == "field :amount_due"
      assert issue.line_no == 5
      assert issue.message =~ "IL-12"
    end

    test "flags a money-named :float migration column and leaves other names alone" do
      source = """
      defmodule Ryker.Repo.Migrations.CreateEntries do
        def change do
          create table(:entries) do
            add :price, :float
            add :tax_rate, :float
            add :latency, :float
          end
        end
      end
      """

      assert triggers(il12(), source, "priv/repo/migrations/20260101000000_create_entries.exs") ==
               ["add :price", "add :tax_rate"]
    end

    test "allows :decimal and integer cents" do
      source = """
      defmodule Ryker.Accounting.Entry do
        use Ecto.Schema

        schema "accounting_entries" do
          field :amount_cents, :integer
          field :tax_rate, :decimal
        end
      end
      """

      assert issues(il12(), source, "lib/ryker/accounting/entry.ex") == []
    end
  end

  describe "Ryker.Checks.NoPreloadInRepoOpts" do
    test "flags a preload put into Repo options and a literal preload: argument" do
      source = """
      defmodule Ryker.Sprockets do
        def list(opts), do: Repo.all(all(), Keyword.put(opts, :preload, [:owner]))
        def fetch(id), do: Repo.get_by(Sprocket, [id: id], preload: [:owner])
      end
      """

      assert triggers(preload_opts(), source, @context) == [
               "Keyword.put(:preload)",
               "Repo.get_by(preload:)"
             ]

      assert [issue | _] = issues(preload_opts(), source, @context)
      assert issue.check == preload_opts()
      assert issue.message =~ "with_preloaded_"
    end

    test "allows popping the caller's preload and mapping it to query helpers" do
      source = """
      defmodule Ryker.Sprockets do
        def list(opts) do
          {preload, opts} = Keyword.pop(opts, :preload, [])
          all() |> preloaded(preload) |> Repo.all(opts)
        end
      end
      """

      assert issues(preload_opts(), source, @context) == []
    end
  end

  describe "Ryker.Checks.EnumOverValidateInclusion" do
    test "flags validate_inclusion over a literal list of strings" do
      source = """
      defmodule Ryker.Sprockets.SprocketChangeset do
        import Ecto.Changeset

        def insert(attributes) do
          changeset = cast(%Sprocket{}, attributes, [:kind])
          validate_inclusion(changeset, :kind, ["alpha", "beta"])
        end
      end
      """

      assert [issue] = issues(enum_over_inclusion(), source, @changeset)
      assert issue.check == enum_over_inclusion()
      assert issue.trigger == "validate_inclusion"
      assert issue.line_no == 6
      assert issue.message =~ "Ecto.Enum"
    end

    test "flags the qualified, piped and attribute spellings and names the right field" do
      source = """
      defmodule Ryker.Sprockets.SprocketChangeset do
        import Ecto.Changeset

        @tiers ~w(gold silver)

        def insert(changeset) do
          changeset
          |> validate_inclusion(:kind, ["alpha", "beta"])
          |> validate_inclusion(:mode, ["fast", "slow"], message: "unsupported")
          |> Ecto.Changeset.validate_inclusion(:tier, @tiers)
          |> validate_inclusion(:shape, ~w(round square))
        end
      end
      """

      flagged =
        enum_over_inclusion() |> issues(source, @changeset) |> Enum.sort_by(& &1.line_no)

      assert [kind, mode, tier, shape] = flagged
      assert {kind.line_no, kind.message =~ ":kind"} == {8, true}
      assert {mode.line_no, mode.message =~ ":mode"} == {9, true}
      assert {tier.line_no, tier.message =~ ":tier"} == {10, true}
      assert {shape.line_no, shape.message =~ ":shape"} == {11, true}
    end

    # A transition that allows only some of an `Ecto.Enum`'s values names them
    # as atoms, which a `:string` field could never match: fourteen of these
    # read as violations once the check first ran here (2026-10-06).
    test "allows a runtime value set and an Ecto.Enum narrowed to some of its atoms" do
      source = """
      defmodule Ryker.Sprockets.SprocketChangeset do
        import Ecto.Changeset

        def confirm(changeset, allowed_kinds) do
          changeset
          |> validate_inclusion(:kind, allowed_kinds)
          |> validate_inclusion(:mode, modes(), message: "unsupported")
          |> validate_inclusion(:status, [:confirmed])
          |> validate_inclusion(:state, ~w(pending active)a)
        end
      end
      """

      assert issues(enum_over_inclusion(), source, @changeset) == []
    end

    test "ignores a module that is not a changeset" do
      source = """
      defmodule Ryker.Sprockets do
        def insert(changeset), do: validate_inclusion(changeset, :kind, ["alpha"])
      end
      """

      assert issues(enum_over_inclusion(), source, @context) == []
    end
  end

  describe "Ryker.Checks.NoHashPrefixSlice" do
    test "flags a hash sliced to a fixed prefix" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        def short(sha), do: String.slice(sha, 0, 16)
      end
      """

      assert [issue] = issues(hash_slice(), source, @console)
      assert issue.check == hash_slice()
      assert issue.trigger == "String.slice"
      assert issue.line_no == 2
      assert issue.message =~ "hash/id is hard-sliced"
    end

    test "flags a digest read off a field, and the range and piped spellings" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        def a(version), do: String.slice(version.payload_digest, 0, 12)
        def b(sha), do: String.slice(sha, 0..15)
        def c(sha), do: sha |> String.slice(0, 16)
        def d(title), do: title |> String.slice(0, 80)
      end
      """

      assert triggers(hash_slice(), source, @console) ==
               ["String.slice", "String.slice", "String.slice"]
    end

    test "allows the full value and a prose truncation, and ignores the contexts" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        def full(sha), do: sha
        def teaser(title), do: String.slice(title, 0, 80)
      end
      """

      context = """
      defmodule Ryker.Sprockets do
        def short(sha), do: String.slice(sha, 0, 16)
      end
      """

      assert issues(hash_slice(), source, @console) == []
      assert issues(hash_slice(), context, @context) == []
    end
  end

  describe "Ryker.Checks.SubscribeNeedsConnected" do
    test "flags a mount/3 that subscribes without a connected? guard" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsLive do
        def mount(_params, _session, socket) do
          Ryker.Episodes.subscribe_episodes()
          {:ok, socket}
        end
      end
      """

      assert [issue] = issues(subscribe(), source, @live)
      assert issue.check == subscribe()
      assert issue.trigger == "subscribe"
      assert issue.line_no == 2
      assert issue.message =~ "IL-18"
    end

    test "allows a mount guarded by connected?/1" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsLive do
        def mount(_params, _session, socket) do
          if connected?(socket), do: Ryker.Episodes.subscribe_episodes()
          {:ok, socket}
        end
      end
      """

      assert issues(subscribe(), source, @live) == []
    end

    test "ignores a subscribe outside mount and outside a LiveView" do
      handle_event = """
      defmodule Ryker.ControlPlane.SprocketsLive do
        def handle_event("watch", _params, socket) do
          Ryker.Episodes.subscribe_episodes()
          {:noreply, socket}
        end
      end
      """

      not_live = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        def mount(_params, _session, socket) do
          Ryker.Episodes.subscribe_episodes()
          {:ok, socket}
        end
      end
      """

      assert issues(subscribe(), handle_event, @live) == []
      assert issues(subscribe(), not_live, @console) == []
    end
  end

  describe "Ryker.Checks.ContextNoMapTakeDrop" do
    test "flags Map.take/Map.drop pre-filtering the input attrs, piped or not" do
      source = """
      defmodule Ryker.Sprockets do
        def update(sprocket, attrs), do: SprocketChangeset.update(sprocket, Map.take(attrs, [:name]))
        def scrub(params), do: Map.drop(params, [:id])
        def rename(sprocket, attrs), do: SprocketChangeset.update(sprocket, attrs |> Map.take([:name]))
      end
      """

      assert triggers(map_take_drop(), source, @context) == [
               "Map.drop(params, …)",
               "Map.take(attrs, …)",
               "attrs |> Map.take(…)"
             ]

      assert [issue | _] = issues(map_take_drop(), source, @context)
      assert issue.check == map_take_drop()
      assert issue.message =~ "cast/3"
    end

    test "allows Map.take/drop on a payload, and ignores the console" do
      payloads = """
      defmodule Ryker.Sprockets do
        def summarize(payload), do: Map.take(payload, [:status])
        def redact(config), do: Map.drop(config, [:secret])
      end
      """

      console = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        def scrub(params), do: Map.drop(params, [:id])
      end
      """

      assert issues(map_take_drop(), payloads, @context) == []
      assert issues(map_take_drop(), console, @console) == []
    end
  end

  describe "Ryker.Checks.ContextCryptoBoundary" do
    test "flags inline :crypto and Base.url_encode64 in a context" do
      source = """
      defmodule Ryker.Sprockets do
        def mint, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      end
      """

      assert triggers(crypto_boundary(), source, @context) == [
               ":crypto.strong_rand_bytes",
               "Base.url_encode64"
             ]

      assert [issue | _] = issues(crypto_boundary(), source, @context)
      assert issue.check == crypto_boundary()
      assert issue.message =~ "Ryker.Crypto"
    end

    test "allows Ryker.Crypto and non-secret encoding, and ignores Ryker.Crypto itself" do
      source = """
      defmodule Ryker.Sprockets do
        def mint, do: Ryker.Crypto.random_secret(32)
        def fingerprint(bytes), do: Base.encode16(bytes, case: :lower)
      end
      """

      crypto = """
      defmodule Ryker.Crypto do
        def random_bytes(size), do: :crypto.strong_rand_bytes(size)
      end
      """

      assert issues(crypto_boundary(), source, @context) == []
      assert issues(crypto_boundary(), crypto, "lib/ryker/crypto.ex") == []
    end
  end

  defp map_take_drop, do: check("ContextNoMapTakeDrop")
  defp crypto_boundary, do: check("ContextCryptoBoundary")
  defp il06, do: check("IL06QueryModulePure")
  defp il12, do: check("IL12NoFloatMoney")
  defp preload_opts, do: check("NoPreloadInRepoOpts")
  defp enum_over_inclusion, do: check("EnumOverValidateInclusion")
  defp hash_slice, do: check("NoHashPrefixSlice")
  defp subscribe, do: check("SubscribeNeedsConnected")
end
