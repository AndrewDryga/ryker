defmodule Ryker.ControlPlane.EpisodeCausality do
  @moduledoc """
  Who owns each step of a timeline, read from durable identities.

  The page used to group by the most recently encountered message: a step
  belonged to whichever message it happened to follow. That is fine until work
  overlaps, which it routinely does. A tool result from Turn 1 arriving after
  Message 2 was filed under Message 2, so a reader debugging "why did it do
  that for my new message" was reading evidence from work that started before
  the message existed. Queued later input cannot become earlier running-turn
  context, and no clock comparison can establish that it did.

  Ownership therefore comes from identities the system already stores: the
  input row, the Work turn, and the remote turn id carried on every activity
  event. A turn can own several inputs and an input can own no turn at all.
  Where the selection was never recorded, this module says so rather than
  guessing from proximity.
  """

  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.{ActivityEvent, Turn}

  @type owner :: {:input, String.t()} | {:turn, String.t()} | :episode

  @type t :: %{
          inputs: %{String.t() => map()},
          input_by_ref: %{String.t() => String.t()},
          turns: %{String.t() => map()},
          activity_owner: %{String.t() => owner()}
        }

  @doc """
  Builds the ownership index for one episode.

  `inputs` and `turns` are the durable rows and `activity_events` supply the
  remote turn and admission input each event was recorded against. `input_refs`
  maps the kernel's own input references -- the ones a turn records as its
  selection -- to input rows; without it a recorded selection cannot be
  resolved and is reported as unrecorded rather than guessed.
  """
  @spec index([Entry.t()], [Turn.t()], [ActivityEvent.t()], keyword()) :: t()
  def index(inputs, turns, activity_events \\ [], options \\ []) do
    inputs = Enum.sort_by(inputs, &{&1.occurred_at, &1.id}, &sort/2)
    turns = Enum.sort_by(turns, &{&1.inserted_at, &1.id}, &sort/2)

    input_index =
      inputs
      |> Enum.with_index(1)
      |> Map.new(fn {input, ordinal} ->
        {input.id,
         %{id: input.id, ordinal: ordinal, ref: input.dedupe_key, at: input.occurred_at}}
      end)

    input_by_ref = Keyword.get(options, :input_refs, %{})

    turn_index =
      turns
      |> Enum.with_index(1)
      |> Map.new(fn {turn, ordinal} ->
        {turn.id,
         %{
           id: turn.id,
           ordinal: ordinal,
           turn_ref: turn.turn_ref,
           at: turn.inserted_at,
           continues: if(ordinal > 1, do: ordinal - 1),
           input_ids: selected_input_ids(turn, input_by_ref)
         }}
      end)

    turn_by_remote =
      turns
      |> Enum.reject(&is_nil(&1.coop_turn_id))
      |> Map.new(&{&1.coop_turn_id, &1.id})

    %{
      inputs: input_index,
      input_by_ref: input_by_ref,
      turns: turn_index,
      activity_owner: activity_owners(activity_events, turn_by_remote, input_index)
    }
  end

  @doc """
  The owner an activity event was recorded against, or `:episode` when the
  event carries neither a remote turn nor an admission input.
  """
  @spec activity_owner(t(), String.t()) :: owner()
  def activity_owner(index, event_id), do: Map.get(index.activity_owner, event_id, :episode)

  @doc """
  Describes a group for display: its durable identity, the inputs it consumed
  and the earlier turn it continues.

  `input_ids` is `:not_recorded` for a turn frozen before the selection was
  captured. Rendering must keep that distinct from a turn that consumed nothing.
  """
  @spec describe(t(), owner()) :: map()
  def describe(index, {:turn, id}) do
    case Map.fetch(index.turns, id) do
      {:ok, turn} ->
        %{
          owner: {:turn, id},
          kind: :turn,
          ordinal: turn.ordinal,
          label: "Turn #{turn.ordinal}",
          continues: turn.continues,
          inputs: input_ordinals(index, turn.input_ids)
        }

      :error ->
        unknown({:turn, id})
    end
  end

  def describe(index, {:input, id}) do
    case Map.fetch(index.inputs, id) do
      {:ok, input} ->
        %{
          owner: {:input, id},
          kind: :input,
          ordinal: input.ordinal,
          label: "Message #{input.ordinal}",
          continues: nil,
          inputs: [input.ordinal]
        }

      :error ->
        unknown({:input, id})
    end
  end

  def describe(_index, :episode) do
    %{owner: :episode, kind: :episode, ordinal: nil, label: nil, continues: nil, inputs: []}
  end

  @doc """
  The conversation position a group belongs to, from durable identity only.

  A turn takes the position of the earliest input it actually selected. An
  unrecorded selection returns `nil`; the caller decides what to show, and must
  not substitute the nearest message in time.
  """
  @spec position(t(), owner()) :: pos_integer() | nil
  def position(index, owner) do
    case describe(index, owner) do
      %{kind: :input, ordinal: ordinal} -> ordinal
      %{inputs: [first | _rest]} -> first
      _none -> nil
    end
  end

  @doc """
  Groups chronologically ordered steps by their durable owner.

  Steps that carry no owner are episode-level and extend the group they are
  read within, never acquiring its identity. A step whose owner differs starts
  a new group even when it is adjacent in time, which is what keeps a late
  Turn 1 receipt labelled Turn 1.
  """
  @spec group(Enumerable.t(), (term() -> owner()), (term() -> term())) :: [
          {term(), owner(), [term()]}
        ]
  def group(steps, owner_fun, band_fun) do
    steps
    |> Enum.map_reduce(nil, fn step, carried ->
      band = band_fun.(step)

      owner =
        case owner_fun.(step) do
          :episode -> carry(carried, band)
          owner -> owner
        end

      {{band, owner, step}, {band, owner}}
    end)
    |> elem(0)
    |> Enum.chunk_by(fn {band, owner, _step} -> {band, owner} end)
    |> Enum.map(fn [{band, owner, _first} | _rest] = chunk ->
      {band, owner, Enum.map(chunk, fn {_band, _owner, step} -> step end)}
    end)
  end

  defp carry({band, owner}, band), do: owner
  defp carry(_carried, _band), do: :episode

  defp selected_input_ids(%Turn{selected_input_refs: nil}, _by_ref), do: :not_recorded

  defp selected_input_ids(%Turn{selected_input_refs: refs}, by_ref) do
    Enum.flat_map(refs, fn ref ->
      case Map.fetch(by_ref, ref) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
  end

  defp input_ordinals(_index, :not_recorded), do: :not_recorded

  defp input_ordinals(index, ids) do
    ids
    |> Enum.flat_map(fn id ->
      case Map.fetch(index.inputs, id) do
        {:ok, %{ordinal: ordinal}} -> [ordinal]
        :error -> []
      end
    end)
    |> Enum.sort()
  end

  defp activity_owners(events, turn_by_remote, input_index) do
    Map.new(events, fn event ->
      owner =
        cond do
          is_binary(event.coop_turn_id) and is_map_key(turn_by_remote, event.coop_turn_id) ->
            {:turn, Map.fetch!(turn_by_remote, event.coop_turn_id)}

          is_binary(event.admission_input_id) and
              is_map_key(input_index, event.admission_input_id) ->
            {:input, event.admission_input_id}

          true ->
            :episode
        end

      {event.id, owner}
    end)
  end

  defp unknown(owner) do
    %{owner: owner, kind: :unknown, ordinal: nil, label: nil, continues: nil, inputs: []}
  end

  defp sort({nil, left}, {nil, right}), do: left <= right
  defp sort({nil, _left}, _right), do: true
  defp sort(_left, {nil, _right}), do: false

  defp sort({left_at, left_id}, {right_at, right_id}) do
    case DateTime.compare(left_at, right_at) do
      :lt -> true
      :gt -> false
      :eq -> left_id <= right_id
    end
  end
end
