defmodule Ryker.CredoChecks.BoundaryChecksTest do
  # Fixture coverage for the checks that keep each layer to its job: queries
  # only in query modules (IL-1, IL-2), a row read as `{:ok, row}` (IL-5),
  # pure query modules (IL-6), schemas of fields only (IL-7), pure changeset
  # modules (IL-8), web modules that neither query nor build changesets,
  # money never in a float (IL-12), preloads named by query helpers, an
  # `Ecto.Enum` for a fixed set of strings, whole hashes on the console, and
  # LiveView subscriptions only once connected (IL-18). Each gets a probe it
  # must flag and a compliant probe it must not.
  use ExUnit.Case, async: true
  import Ryker.CredoCheckProbe

  @context "lib/ryker/sprockets.ex"
  @query "lib/ryker/sprockets/sprocket/query.ex"
  @changeset "lib/ryker/sprockets/sprocket/changeset.ex"
  @console "lib/ryker/control_plane/sprockets_page.ex"
  @live "lib/ryker/control_plane/sprockets_live.ex"

  setup_all do
    load()
  end

  describe "Ryker.Checks.IL01NoInlineEctoDsl" do
    test "flags the query DSL outside a query module" do
      source = """
      defmodule Ryker.Sprockets do
        import Ecto.Query

        def recent, do: Ecto.Query.from(s in Sprocket, limit: 5)
      end
      """

      assert triggers(il01(), source, @context) == ["Ecto.Query.from", "import Ecto.Query"]
      assert [issue | _] = issues(il01(), source, @context)
      assert issue.check == il01()
      assert issue.message =~ "IL-1"
    end

    test "allows the DSL in a query module and a query type in any spec" do
      query = """
      defmodule Ryker.Sprockets.Sprocket.Query do
        import Ecto.Query

        def all, do: from(sprockets in Sprocket, as: :sprockets)
      end
      """

      spec = """
      defmodule Ryker.Sprockets do
        @spec recent() :: Ecto.Query.t()
        def recent, do: Sprocket.Query.all()
      end
      """

      assert issues(il01(), query, @query) == []
      assert issues(il01(), spec, @context) == []
    end

    # Every read starts at a Query module; one that starts at the schema reads
    # every row the way no Query module says (Emisar IL-1: every queryable
    # starts at `Schema.Query.fun()`).
    test "flags a read that starts at a schema instead of its Query module" do
      source = """
      defmodule Ryker.Sprockets do
        def every, do: Repo.all(Sprocket)
        def counted, do: Sprocket |> Repo.aggregate(:count)
        def any?, do: Ryker.Repo.exists?(Sprocket)
        def through_query, do: Repo.all(Sprocket.Query.all())
        def written(rows), do: Repo.insert_all(Sprocket, rows)
      end
      """

      assert triggers(il01(), source, @context) ==
               ["Repo.all(Schema)", "Repo.exists?(Schema)", "Schema |> Repo.aggregate"]
    end
  end

  describe "Ryker.Checks.IL02NoRepoGet" do
    test "flags every Repo.get form in lib" do
      source = """
      defmodule Ryker.Sprockets do
        def one(id), do: Repo.get(Sprocket, id)
        def one!(id), do: Repo.get!(Sprocket, id)
        def named(name), do: Ryker.Repo.get_by(Sprocket, name: name)
        def named!(name), do: Repo.get_by!(Sprocket, name: name)
      end
      """

      assert triggers(il02(), source, @context) ==
               ["Repo.get", "Repo.get!", "Repo.get_by", "Repo.get_by!"]

      assert [issue | _] = issues(il02(), source, @context)
      assert issue.check == il02()
      assert issue.message =~ "IL-2"
    end

    test "allows a lookup through a query module, Repo itself, and tests" do
      context = """
      defmodule Ryker.Sprockets do
        def one(id), do: id |> Sprocket.Query.by_id() |> Repo.fetch()
      end
      """

      direct = """
      defmodule Ryker.Repo do
        def lookup(schema, id), do: Ryker.Repo.get(schema, id)
      end
      """

      assert issues(il02(), context, @context) == []
      assert issues(il02(), direct, "lib/ryker/repo.ex") == []
      assert issues(il02(), direct, "test/ryker/sprockets_test.exs") == []
    end
  end

  describe "Ryker.Checks.IL05TaggedReads" do
    test "flags a public function that answers a row or nil" do
      source = """
      defmodule Ryker.Sprockets do
        def by_id(id), do: id |> Sprocket.Query.by_id() |> Repo.one()

        def named(name) when is_binary(name) do
          query = Sprocket.Query.by_name(name)
          Ryker.Repo.one(query)
        end

        def oldest, do: Repo.one(Sprocket.Query.ordered_by_oldest(), timeout: 5_000)
      end
      """

      assert triggers(il05(), source, @context) == ["by_id", "named", "oldest"]
      assert [issue | _] = issues(il05(), source, @context)
      assert issue.check == il05()
      assert issue.message =~ "IL-5"
    end

    test "allows a fetch, a selected value, a private read, and query modules" do
      source = """
      defmodule Ryker.Sprockets do
        def fetch(id), do: id |> Sprocket.Query.by_id() |> Repo.fetch()
        def name(id), do: id |> Sprocket.Query.by_id() |> Sprocket.Query.select_names() |> Repo.one()
        def next_due_at(since), do: Repo.one(Sprocket.Query.select_next_due_after(since))
        def one!(id), do: id |> Sprocket.Query.by_id() |> Repo.one!()
        defp quiet(id), do: id |> Sprocket.Query.by_id() |> Repo.one()
      end
      """

      query = """
      defmodule Ryker.Sprockets.Sprocket.Query do
        def first(queryable), do: Repo.one(queryable)
      end
      """

      assert issues(il05(), source, @context) == []
      assert issues(il05(), query, @query) == []
      assert issues(il05(), source, "test/ryker/sprockets_test.exs") == []
    end
  end

  describe "Ryker.Checks.IL06QueryModulePure" do
    test "flags a Repo call inside a query module" do
      source = """
      defmodule Ryker.Sprockets.Sprocket.Query do
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
      defmodule Ryker.Sprockets.Sprocket.Query do
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

  describe "Ryker.Checks.IL07SchemaFieldsOnly" do
    # Twelve settings schemas built their own changesets until 2026-10-07,
    # beside session evidence and feedback signals: the shape this keeps out.
    test "flags changeset logic in a schema module" do
      source = """
      defmodule Ryker.Sprockets.Sprocket do
        use Ryker, :schema
        import Ecto.Changeset

        schema "sprockets" do
          field(:name, :string)
        end

        def changeset(sprocket, attributes) do
          sprocket
          |> cast(attributes, [:name])
          |> validate_required([:name])
          |> Validation.validate_known(:name, [], :unknown)
        end

        def insert(attributes), do: Ecto.Changeset.change(%__MODULE__{}, attributes)
      end
      """

      assert triggers(il07(), source, "lib/ryker/sprockets/sprocket.ex") == [
               "Ecto.Changeset.change",
               "Validation.validate_known",
               "cast",
               "def changeset",
               "def insert",
               "validate_required"
             ]

      assert [issue | _] = issues(il07(), source, "lib/ryker/sprockets/sprocket.ex")
      assert issue.message =~ "IL-7"
    end

    test "allows a schema's own helpers and a changeset module's builders" do
      schema = """
      defmodule Ryker.Sprockets.Sprocket do
        use Ryker, :schema

        schema "sprockets" do
          field(:teeth, :integer)
        end

        def toothed?(%__MODULE__{teeth: teeth}), do: teeth > 0
        def teeth(value), do: Ecto.Type.cast(:integer, value)
      end
      """

      changeset = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        import Ecto.Changeset

        def insert(attributes), do: %Sprocket{} |> cast(attributes, [:teeth]) |> checked()
        def update(sprocket, attributes), do: sprocket |> cast(attributes, [:teeth]) |> checked()
        defp checked(changeset), do: validate_required(changeset, [:teeth])
      end
      """

      assert issues(il07(), schema, "lib/ryker/sprockets/sprocket.ex") == []
      assert issues(il07(), changeset, @changeset) == []
    end
  end

  describe "Ryker.Checks.IL08ChangesetPure" do
    test "flags a Repo call inside a changeset module" do
      source = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        import Ecto.Changeset

        def insert(attributes) do
          taken = Repo.exists?(Sprocket.Query.named(attributes.name))
          %Sprocket{} |> cast(attributes, [:name]) |> put_change(:taken, taken)
        end
      end
      """

      assert [issue] = issues(il08(), source, @changeset)
      assert issue.trigger == "Repo.exists?"
      assert issue.line_no == 5
      assert issue.message =~ "IL-8"
    end

    test "allows a grouped Repo alias, and Repo calls outside changeset modules" do
      grouped = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        alias Ryker.Repo.{Filter, Paginator}
        def insert(attributes), do: Ecto.Changeset.change(%Sprocket{}, attributes)
      end
      """

      context = """
      defmodule Ryker.Sprockets do
        def create(attributes), do: attributes |> Sprocket.Changeset.insert() |> Repo.insert()
      end
      """

      assert issues(il08(), grouped, @changeset) == []
      assert issues(il08(), context, @context) == []
    end
  end

  describe "Ryker.Checks.IL08ValidationInChangesets" do
    # Fourteen modules that read and wrote the database validated rows
    # themselves until 2026-10-07: workers, placements, commands, platform
    # actions, weekly reports, operator actions and admission sessions.
    test "flags validation in a module that calls Repo" do
      source = """
      defmodule Ryker.Sprockets do
        import Ecto.Changeset, only: [cast: 3]

        def create(attributes) do
          %Sprocket{}
          |> Ecto.Changeset.cast(attributes, [:name])
          |> Ecto.Changeset.validate_required([:name])
          |> Ecto.Changeset.unique_constraint(:name)
          |> Repo.insert()
        end
      end
      """

      assert triggers(il08_validation(), source, @context) == [
               "Ecto.Changeset.cast",
               "Ecto.Changeset.unique_constraint",
               "Ecto.Changeset.validate_required",
               "import Ecto.Changeset"
             ]
    end

    test "allows a context's bare change, a helper without Repo, and a changeset module" do
      context = """
      defmodule Ryker.Sprockets do
        def rename(sprocket, name),
          do: sprocket |> Ecto.Changeset.change(name: name) |> Repo.update()
      end
      """

      helper = """
      defmodule Ryker.Sprockets.Validation do
        import Ecto.Changeset
        def validate_teeth(changeset), do: validate_number(changeset, :teeth, greater_than: 0)
      end
      """

      changeset = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        import Ecto.Changeset
        def insert(attributes), do: %Sprocket{} |> cast(attributes, [:name]) |> unique_constraint(:name)
      end
      """

      assert issues(il08_validation(), context, @context) == []
      assert issues(il08_validation(), helper, "lib/ryker/sprockets/validation.ex") == []
      assert issues(il08_validation(), changeset, @changeset) == []
    end
  end

  describe "Ryker.Checks.WebNoRepoCalls" do
    # The running-system card read workers and the clock itself until
    # 2026-10-07; every other page reads through a projection.
    test "flags a Repo call in a module that uses a Phoenix web behaviour" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.Repo

        def fetch, do: %{sprockets: Sprocket.Query.all() |> Repo.all(), now: Repo.now!()}
      end
      """

      assert triggers(web_repo(), source, @console) == ["Repo.all", "Repo.now!"]
      assert [issue | _] = issues(web_repo(), source, @console)
      assert issue.message =~ "projection"
    end

    test "allows a projection's reads and a grouped Repo alias in a component" do
      projection = """
      defmodule Ryker.ControlPlane.SprocketsProjection do
        def fetch, do: Sprocket.Query.all() |> Repo.all()
      end
      """

      component = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.Repo.{Filter, Paginator}
        def render(assigns), do: assigns
      end
      """

      assert issues(web_repo(), projection, "lib/ryker/control_plane/sprockets_projection.ex") ==
               []

      assert issues(web_repo(), component, @console) == []
    end
  end

  describe "Ryker.Checks.WebNoChangesetConstruction" do
    test "flags a web module that builds or imports a changeset" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsLive do
        use Phoenix.LiveView
        import Ecto.Changeset, only: [cast: 3]

        def handle_event("save", params, socket) do
          changeset = Sprocket.Changeset.insert(params)
          {:noreply, assign(socket, :form, Ecto.Changeset.add_error(changeset, :name, "taken"))}
        end
      end
      """

      assert triggers(web_changeset(), source, @live) == [
               "Ecto.Changeset.add_error",
               "Sprocket.Changeset.insert",
               "import Ecto.Changeset"
             ]
    end

    test "allows reading a changeset in a web module and building one in a context" do
      component = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        def name(changeset), do: Ecto.Changeset.get_field(changeset, :name)
      end
      """

      context = """
      defmodule Ryker.Sprockets do
        import Ecto.Changeset
        def create(attributes), do: attributes |> Sprocket.Changeset.insert() |> Repo.insert()
      end
      """

      assert issues(web_changeset(), component, @console) == []
      assert issues(web_changeset(), context, @context) == []
    end
  end

  describe "Ryker.Checks.IL12NoFloatMoney" do
    test "flags a money-named :float schema field" do
      source = """
      defmodule Ryker.Accounting.Entry do
        use Ryker, :schema

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
        use Ryker, :schema

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
      defmodule Ryker.Sprockets.Sprocket.Changeset do
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
      defmodule Ryker.Sprockets.Sprocket.Changeset do
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
      defmodule Ryker.Sprockets.Sprocket.Changeset do
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
        def update(sprocket, attrs), do: Sprocket.Changeset.update(sprocket, Map.take(attrs, [:name]))
        def scrub(params), do: Map.drop(params, [:id])
        def rename(sprocket, attrs), do: Sprocket.Changeset.update(sprocket, attrs |> Map.take([:name]))
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

  describe "Ryker.Checks.CrossContextDeepAlias" do
    # Until 2026-10-08 lib held 1,533 aliases of other contexts' modules, so
    # `Turn` could be anyone's turn until the reader found the alias.
    test "flags an alias reaching into another context" do
      source = """
      defmodule Ryker.Sprockets.Spinner do
        alias Ryker.Work.Turn
        alias Ryker.Episodes.Episode, as: Request
        alias Ryker.Slack.{Names, TaskCards}
        alias Ryker.{CanonicalJSON, Settings.Environment}
      end
      """

      assert triggers(deep_alias(), source, "lib/ryker/sprockets/spinner.ex") == [
               "Ryker.Episodes",
               "Ryker.Settings",
               "Ryker.Slack",
               "Ryker.Work"
             ]
    end

    test "allows the own context's modules, top-level modules and Repo" do
      source = """
      defmodule Ryker.Sprockets.Spinner do
        alias Ryker.Sprockets.{Gear, Tooth}
        alias Ryker.Sprockets.Gear.Query
        alias Ryker.{Repo, Work}
        alias Ryker.Repo.Something
        alias Ryker.Slack
      end
      """

      assert issues(deep_alias(), source, "lib/ryker/sprockets/spinner.ex") == []

      assert issues(
               deep_alias(),
               "defmodule Ryker.T do\n  alias Ryker.Work.Turn\nend\n",
               "test/t.exs"
             ) == []
    end
  end

  describe "Ryker.Checks.WebNoNestedDomainCalls" do
    # Until 2026-10-08 the console called 30 functions below a context 93
    # times, three of them channel writes made straight from a LiveView.
    test "flags a fully qualified nested domain call" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component

        def place(ref), do: Ryker.Slack.Names.destination(ref)
      end
      """

      assert triggers(web_nested(), source, @console) == ["Slack.Names.destination"]
    end

    test "flags a nested call through the context alias, a deep alias, as: and a group" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.Settings
        alias Ryker.Slack.Names
        alias Ryker.Work.ExecutionTarget, as: Target
        alias Ryker.Schedules.{ScheduleCadence, Schedule}

        def refs(environment), do: Settings.Environment.repository_refs(environment)
        def place(ref), do: Names.destination(ref)
        def model(target), do: Target.present(target)
        def zone(name), do: ScheduleCadence.zone_name(name)
      end
      """

      assert triggers(web_nested(), source, @console) == [
               "Schedules.ScheduleCadence.zone_name",
               "Settings.Environment.repository_refs",
               "Slack.Names.destination",
               "Work.ExecutionTarget.present"
             ]
    end

    test "flags a captured nested function and a runtime t/0, not a t/0 in a type" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.Slack

        @type participation :: Slack.ChannelConfigurations.t()

        def change, do: &Slack.ChannelConfigurations.change_participation/1
        def rebuild, do: Slack.ChannelConfigurations.t()
      end
      """

      assert triggers(web_nested(), source, @console) == [
               "Slack.ChannelConfigurations.change_participation",
               "Slack.ChannelConfigurations.t"
             ]
    end

    test "flags a nested call written inside a ~H template, on the template's line" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.Episodes

        def render(assigns) do
          ~H\"""
          <ul>
            <li :for={state <- @states}>{Episodes.Words.label(state)}</li>
          </ul>
          \"""
        end
      end
      """

      assert [issue] = issues(web_nested(), source, @console)
      assert issue.trigger == "Episodes.Words.label"
      assert issue.line_no == 8
    end

    test "allows top-level contexts, the console's own modules, structs and types" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsPage do
        use Phoenix.Component
        alias Ryker.ControlPlane.Paths
        alias Ryker.Episodes
        alias Ryker.Slack
        alias Ryker.Work

        @spec place(String.t()) :: String.t()
        def place(ref), do: Slack.destination_name(ref)
        def state(state), do: Episodes.label(state)
        def link(id), do: Paths.request(id)
        def running?(%Work.Turn{state: :running}), do: true
        def running?(_turn), do: false

        def render(assigns), do: ~H"<span>{Slack.destination_name(@ref)}</span>"
      end
      """

      assert triggers(web_nested(), source, @console) == []
    end

    test "ignores a module that is not a web module" do
      source = """
      defmodule Ryker.ControlPlane.SprocketsProjection do
        def place(ref), do: Ryker.Slack.Names.destination(ref)
      end
      """

      assert issues(web_nested(), source, "lib/ryker/control_plane/sprockets_projection.ex") ==
               []
    end
  end

  describe "Ryker.Checks.UseRykerRole" do
    # Until 2026-10-08 each of 107 schemas, 140 Query and 59 Changeset modules
    # spelled out its own Ecto imports and attributes; a schema that forgot
    # `@foreign_key_type` or a timestamp type differed silently.
    test "flags a data module that takes its role from Ecto directly" do
      schema = """
      defmodule Ryker.Sprockets.Sprocket do
        use Ecto.Schema

        schema "sprockets" do
          field(:name, :string)
        end
      end
      """

      query = """
      defmodule Ryker.Sprockets.Sprocket.Query do
        import Ecto.Query

        def all, do: from(sprockets in Ryker.Sprockets.Sprocket, as: :sprockets)
      end
      """

      changeset = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        import Ecto.Changeset

        def insert(attributes), do: cast(%Ryker.Sprockets.Sprocket{}, attributes, [:name])
      end
      """

      assert triggers(role(), schema, "lib/ryker/sprockets/sprocket.ex") == [
               "defmodule",
               "use Ecto.Schema"
             ]

      assert triggers(role(), query, @query) == ["defmodule", "import Ecto.Query"]
      assert triggers(role(), changeset, @changeset) == ["defmodule", "import Ecto.Changeset"]
      assert [issue | _] = issues(role(), query, @query)
      assert issue.message =~ "use Ryker"
    end

    test "flags a role in a module that does not play it" do
      source = """
      defmodule Ryker.Sprockets do
        use Ryker, :query

        def recent, do: from(sprockets in Ryker.Sprockets.Sprocket, limit: 5)
      end
      """

      assert triggers(role(), source, @context) == ["use Ryker, :query"]
    end

    test "allows each role in its own module, and an embedded value object on Ecto" do
      schema = """
      defmodule Ryker.Sprockets.Sprocket do
        use Ryker, :schema
        @primary_key {:ref, :string, autogenerate: false}

        schema "sprockets" do
          timestamps()
        end
      end
      """

      query = """
      defmodule Ryker.Sprockets.Sprocket.Query do
        use Ryker, :query

        def all, do: from(sprockets in Ryker.Sprockets.Sprocket, as: :sprockets)
      end
      """

      changeset = """
      defmodule Ryker.Sprockets.Sprocket.Changeset do
        use Ryker, :changeset

        def insert(attributes), do: cast(%Ryker.Sprockets.Sprocket{}, attributes, [:ref])
      end
      """

      embedded = """
      defmodule Ryker.Sprockets.Settings do
        use Ecto.Schema
        @primary_key false

        embedded_schema do
          field(:teeth, :integer)
        end
      end
      """

      assert issues(role(), schema, "lib/ryker/sprockets/sprocket.ex") == []
      assert issues(role(), query, @query) == []
      assert issues(role(), changeset, @changeset) == []
      assert issues(role(), embedded, "lib/ryker/sprockets/settings.ex") == []
    end
  end

  defp map_take_drop, do: check("ContextNoMapTakeDrop")
  defp crypto_boundary, do: check("ContextCryptoBoundary")
  defp il01, do: check("IL01NoInlineEctoDsl")
  defp il02, do: check("IL02NoRepoGet")
  defp il05, do: check("IL05TaggedReads")
  defp il06, do: check("IL06QueryModulePure")
  defp il07, do: check("IL07SchemaFieldsOnly")
  defp il08, do: check("IL08ChangesetPure")
  defp il08_validation, do: check("IL08ValidationInChangesets")
  defp web_repo, do: check("WebNoRepoCalls")
  defp web_changeset, do: check("WebNoChangesetConstruction")
  defp il12, do: check("IL12NoFloatMoney")
  defp preload_opts, do: check("NoPreloadInRepoOpts")
  defp enum_over_inclusion, do: check("EnumOverValidateInclusion")
  defp hash_slice, do: check("NoHashPrefixSlice")
  defp subscribe, do: check("SubscribeNeedsConnected")
  defp role, do: check("UseRykerRole")
  defp web_nested, do: check("WebNoNestedDomainCalls")
  defp deep_alias, do: check("CrossContextDeepAlias")
end
