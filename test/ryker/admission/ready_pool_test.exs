defmodule Ryker.Admission.ReadyPoolTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [eventually: 1]
  alias Ryker.Admission.ReadyPool
  alias Ryker.Repo
  alias Ryker.TestSupport.FakeCoopAPI
  alias Ryker.Work.Session

  # The owner starts the pool from its assembled configuration and nothing
  # else ever asks it to run. A pool that started but never kept a session
  # ready would put every message back to paying the full session start
  # (5.6 s of a 28.6 s "hi", 2026-09-26) with nothing to say why.
  test "the running pool keeps its sessions ready without being asked" do
    {:ok, fake} = FakeCoopAPI.start_link([])

    start_supervised!(
      {ReadyPool,
       api: FakeCoopAPI,
       client: fake,
       policy: "admission-read-only",
       policy_digest: String.duplicate("a", 64),
       target: 2}
    )

    assert eventually(fn ->
             Repo.aggregate(
               from(session in Session, where: session.ready_state == :ready),
               :count
             ) ==
               2
           end)

    assert :ok = stop_supervised(ReadyPool)
  end
end
