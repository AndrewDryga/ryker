defmodule Ryker.PeopleTest do
  # Andrew, 2026-09-30: Ryker should learn about people "passively ...
  # without approvals (like when you mentioned when it's your birthday or
  # what is your favorite tv show etc)". What it learns is only ever about
  # the person who said it, is used only where it may be, and is forgotten
  # when they take it back, edit or delete the message, an operator forgets
  # them, or the channel goes. The learning pass's answer is constructed here:
  # these tests hold the host to what it does with any answer.
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.People
  alias Ryker.People.PersonFact
  alias Ryker.Repo
  alias Ryker.Slack.ChannelConfigurations
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput

  setup do
    workspace = "T#{System.unique_integer([:positive])}"
    %{workspace: workspace, public: channel!(workspace, "CPUBLIC", false), now: Repo.now!()}
  end

  test "what a person says about themselves is kept under their name, from their own message only",
       %{workspace: workspace, public: public} do
    alice = said!(workspace, "CPUBLIC", "UALICE", "My birthday is on 12 March, by the way")
    alerts = said!(workspace, "CPUBLIC", "AALERTS", "Deploy finished", kind: :app)

    learn!([alice, alerts], [
      item(alice, "birthday", "Birthday is 12 March."),
      item(alerts, "favourite-tv-show", "Favourite TV show is The Expanse."),
      %{"source_input_id" => Ecto.UUID.generate(), "key" => "preferred-name", "fact" => "Al."}
    ])

    assert People.about("slack:user:UALICE", public) == ["Birthday is 12 March."]
    assert Enum.map(People.people(), & &1.person_ref) == ["slack:user:UALICE"]
  end

  test "a later statement replaces an earlier one, and an earlier one changes nothing",
       %{workspace: workspace, public: public, now: now} do
    kyiv = said!(workspace, "CPUBLIC", "UBOB", "I'm on Kyiv time", at: ago(now, 120))
    lisbon = said!(workspace, "CPUBLIC", "UBOB", "Moved to Lisbon!", at: ago(now, 60))

    learn!([lisbon], [item(lisbon, "time-zone", "Works on Lisbon time.")])
    learn!([kyiv], [item(kyiv, "time-zone", "Works on Kyiv time.")])

    assert People.about("slack:user:UBOB", public) == ["Works on Lisbon time."]
  end

  test "a person taking a fact back forgets it, and the message it came from never teaches it again",
       %{workspace: workspace, public: public, now: now} do
    told = said!(workspace, "CPUBLIC", "UCARA", "my birthday is 2 May", at: ago(now, 120))
    learn!([told], [item(told, "birthday", "Birthday is 2 May.")])

    took_back = said!(workspace, "CPUBLIC", "UCARA", "forget my birthday", at: ago(now, 60))
    learn!([took_back], [item(took_back, "birthday", nil)])
    assert People.about("slack:user:UCARA", public) == []
    assert kinds("slack:user:UCARA") == [:forgotten]

    learn!([told], [item(told, "birthday", "Birthday is 2 May.")])
    assert People.about("slack:user:UCARA", public) == []

    again = said!(workspace, "CPUBLIC", "UCARA", "fine, it's 2 May", at: DateTime.add(now, 60))
    learn!([again], [item(again, "birthday", "Birthday is 2 May.")])
    assert People.about("slack:user:UCARA", public) == ["Birthday is 2 May."]
    assert kinds("slack:user:UCARA") == ["birthday"]
  end

  # A forgotten fact kept its kind, such as "medical-leave", which says what
  # was forgotten (2026-10-04 review). It keeps only a digest of it, which
  # still stops anything said before from teaching it again.
  test "a fact an operator forgets keeps no word of what it was about",
       %{workspace: workspace, public: public, now: now} do
    told = said!(workspace, "CPUBLIC", "UERIN", "I'm on leave for surgery", at: ago(now, 60))
    learn!([told], [item(told, "medical-leave", "On leave for surgery.")])
    [fact] = People.facts("slack:user:UERIN")

    assert People.forget_fact(fact.id) == {:ok, 1}
    assert kinds("slack:user:UERIN") == [:forgotten]

    learn!([told], [item(told, "medical-leave", "On leave for surgery.")])
    assert People.about("slack:user:UERIN", public) == []
  end

  test "what an operator forgot stays forgotten against anything said before, and is learned again after",
       %{workspace: workspace, public: public, now: now} do
    told = said!(workspace, "CPUBLIC", "UDAN", "I love tea", at: ago(now, 120))
    also = said!(workspace, "CPUBLIC", "UDAN", "tea is the best", at: ago(now, 60))
    learn!([told], [item(told, "favourite-drink", "Loves tea.")])

    assert People.forget_person("slack:user:UDAN") == {:ok, 1}
    learn!([told, also], [item(also, "favourite-drink", "Loves tea.")])
    assert People.about("slack:user:UDAN", public) == []

    later = said!(workspace, "CPUBLIC", "UDAN", "coffee now", at: DateTime.add(now, 60))
    learn!([later], [item(later, "favourite-drink", "Drinks coffee now.")])
    assert People.about("slack:user:UDAN", public) == ["Drinks coffee now."]
  end

  # Andrew, 2026-09-30, on his People page: "add way to forget individual facts".
  test "forgetting one fact keeps the rest, and only something said later brings it back",
       %{workspace: workspace, public: public, now: now} do
    told =
      said!(workspace, "CPUBLIC", "UFAY", "I love tea, birthday is 3 June", at: ago(now, 120))

    learn!([told], [
      item(told, "birthday", "Birthday is 3 June."),
      item(told, "favourite-drink", "Loves tea.")
    ])

    [birthday] = Enum.filter(People.facts("slack:user:UFAY"), &(&1.key == "birthday"))
    assert People.forget_fact(birthday.id) == {:ok, 1}
    assert People.about("slack:user:UFAY", public) == ["Loves tea."]

    learn!([told], [item(told, "birthday", "Birthday is 3 June.")])
    assert People.about("slack:user:UFAY", public) == ["Loves tea."]

    later = said!(workspace, "CPUBLIC", "UFAY", "it's 3 June!", at: DateTime.add(now, 60))
    learn!([later], [item(later, "birthday", "Birthday is 3 June.")])

    assert Enum.sort(People.about("slack:user:UFAY", public)) == [
             "Birthday is 3 June.",
             "Loves tea."
           ]
  end

  # Said in a direct message or a private channel, it stays there; said
  # where the whole workspace reads, it may be used wherever that person asks.
  test "a fact said somewhere private is used only there", %{workspace: workspace, public: public} do
    private = channel!(workspace, "CPRIVATE", true)
    direct = "slack:#{workspace}:DDIRECT"

    name = said!(workspace, "DDIRECT", "UERIN", "call me Rin please")
    show = said!(workspace, "CPUBLIC", "UERIN", "Severance is my favourite show")
    learn!([name], [item(name, "preferred-name", "Likes to be called Rin.")])
    learn!([show], [item(show, "favourite-tv-show", "Favourite TV show is Severance.")])

    assert People.about("slack:user:UERIN", direct) ==
             ["Favourite TV show is Severance.", "Likes to be called Rin."]

    assert People.about("slack:user:UERIN", public) == ["Favourite TV show is Severance."]
    assert People.about("slack:user:UERIN", private) == ["Favourite TV show is Severance."]
    assert People.about("slack:user:USOMEONE", direct) == []
  end

  test "editing or deleting the message forgets what it taught",
       %{workspace: workspace, public: public} do
    edited =
      said!(workspace, "CPUBLIC", "UFAY", "My birthday is 7 July", message: "1790000001.000100")

    deleted =
      said!(workspace, "CPUBLIC", "UGUS", "My birthday is 9 June", message: "1790000002.000100")

    learn!([edited], [item(edited, "birthday", "Birthday is 7 July.")])
    learn!([deleted], [item(deleted, "birthday", "Birthday is 9 June.")])

    revise!(workspace, "UFAY", edited, "1790000001.000100", :edit, %{
      "text" => "My birthday is 8 July"
    })

    revise!(workspace, "UGUS", deleted, "1790000002.000100", :delete, %{})

    assert People.about("slack:user:UFAY", public) == []
    assert People.about("slack:user:UGUS", public) == []
  end

  test "deleting a Slack channel forgets what was said in it, and nothing else",
       %{workspace: workspace, public: public} do
    kept = channel!(workspace, "CKEPT", false)
    gone = said!(workspace, "CPUBLIC", "UHAL", "My birthday is 1 January")
    stays = said!(workspace, "CKEPT", "UHAL", "I have a cat called Miso")
    learn!([gone], [item(gone, "birthday", "Birthday is 1 January.")])
    learn!([stays], [item(stays, "pets", "Has a cat called Miso.")])

    delete_channel!(workspace, "CPUBLIC")

    assert People.about("slack:user:UHAL", kept) == ["Has a cat called Miso."]
    assert People.about("slack:user:UHAL", public) == ["Has a cat called Miso."]
  end

  test "a person who talks about themselves a lot still has a bounded record",
       %{workspace: workspace, public: public} do
    many = said!(workspace, "CPUBLIC", "UIVY", "so many things about me")

    learn!([many], for(n <- 1..30, do: item(many, "thing-#{n}", "Thing #{n}.")))

    assert [%{facts: 24}] = People.people()
    assert length(People.about("slack:user:UIVY", public)) == 12
  end

  # The database and the answer's JSON Schema count a fact's length in code
  # points. Counted in letters as written, a fact of 280 letters with accents
  # made of two code points each passed the host and failed the database,
  # which would have failed the whole learning pass, topics and all.
  test "a fact too long to keep is left out without failing what else the pass learned",
       %{workspace: workspace, public: public} do
    told = said!(workspace, "CPUBLIC", "UJOE", "My name is written with accents")
    accented = String.duplicate("e\u0301", 200)
    assert String.length(accented) == 200 and length(String.codepoints(accented)) == 400

    learn!([told], [
      item(told, "preferred-name", accented),
      item(told, "time-zone", "Works on Lisbon time.")
    ])

    assert People.about("slack:user:UJOE", public) == ["Works on Lisbon time."]
  end

  # Every author's facts go into the learning prompt beside their messages,
  # and a batch holds up to sixteen messages: all of it together stays small.
  test "what the learning pass reads about its authors is bounded, however many there are",
       %{workspace: workspace} do
    authors =
      for n <- 1..16 do
        told = said!(workspace, "CPUBLIC", "UAUTHOR#{n}", "lots about me")
        learn!([told], for(k <- 1..12, do: item(told, "thing-#{k}", "Thing #{k} about #{n}.")))
        told
      end

    known = People.known_about_authors(authors)
    assert known |> Enum.flat_map(& &1["facts"]) |> length() == 24
  end

  # A statement in a private repository's pull request was used wherever the
  # person spoke next, as if said in a public channel (2026-10-04 review).
  # Only a Slack channel Ryker knows is public lets a fact travel.
  test "what a person says outside Slack stays in the conversation they said it in" do
    review = "github:ryker-app:octo/private-review:pull:74"

    comment = %Entry{
      id: Ecto.UUID.generate(),
      actor_kind: :user,
      actor_ref: "octo-dev",
      destination_conversation_ref: review,
      native_input_id: "github-comment:people:74",
      occurred_at: Repo.now!(),
      source_kind: "github"
    }

    learn!([comment], [item(comment, "time-zone", "Works on Kyiv time.")])

    assert People.about("github:user:octo-dev", review) == ["Works on Kyiv time."]
    assert People.about("github:user:octo-dev", "github:ryker-app:octo/public:pull:9") == []
  end

  # Each of a person's rows by its kind, or `:forgotten` for a forgotten row
  # whose kind is only a digest.
  defp kinds(person_ref) do
    Repo.all(from(f in PersonFact, where: f.person_ref == ^person_ref))
    |> Enum.map(fn
      %{status: :forgotten, key: key} ->
        if key =~ ~r/\Af[0-9a-f]{47}\z/, do: :forgotten, else: key

      %{key: key} ->
        key
    end)
  end

  defp learn!(entries, items) do
    assert Repo.transaction(fn -> People.learn_in_transaction(items, entries) end) == {:ok, :ok}
  end

  defp item(%Entry{id: id}, key, fact),
    do: %{"source_input_id" => id, "key" => key, "fact" => fact}

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  # A message received as Ryker receives every message.
  defp said!(workspace, channel, actor, text, options \\ []) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: Keyword.get(options, :kind, :user), ref: actor},
        channel_ref: channel,
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{unique}",
        message_ref: Keyword.get(options, :message, "#{1_790_000_000 + unique}.000100"),
        occurred_at: Keyword.get_lazy(options, :at, &Repo.now!/0),
        revision: 1,
        thread_ref: nil,
        workspace_ref: workspace
      })

    {:ok, %{status: :recorded, entry: entry}} = Inbox.record(input)
    entry
  end

  # The author edits or deletes the message, as Slack reports it.
  defp revise!(workspace, actor, %Entry{} = entry, message_ref, kind, content) do
    {:ok, revision} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: actor},
        channel_ref: "CPUBLIC",
        content: content,
        event_kind: kind,
        event_ref: "Ev-#{kind}-#{System.unique_integer([:positive])}",
        message_ref: message_ref,
        occurred_at: DateTime.add(entry.occurred_at, 30, :second),
        revision: 2,
        thread_ref: nil,
        workspace_ref: workspace
      })

    {:ok, %{status: :recorded}} = Inbox.record(revision)
  end

  defp channel!(workspace, channel, private) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: workspace,
      channel_ref: channel,
      status: :joined,
      generation: 1,
      joined_at: DateTime.utc_now(),
      private: private,
      external_shared: false
    })

    "slack:#{workspace}:#{channel}"
  end

  # Slack deletes the channel, as the membership event reports it.
  defp delete_channel!(workspace, channel) do
    {:ok, _deleted} =
      ChannelConfigurations.observe_membership(
        %{
          actor_ref: nil,
          channel_ref: channel,
          event_ref: "event:people-channel:#{System.unique_integer([:positive])}",
          kind: :deleted,
          occurred_at: Repo.now!(),
          workspace_ref: workspace
        },
        %{default_environment: nil, environments: []}
      )
  end
end
