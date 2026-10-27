import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {runInNewContext} from "node:vm"
import {resolve} from "node:path"

function connectionOptions() {
  const source = readFileSync(new URL("../../priv/static/control-plane.js", import.meta.url), "utf8")
  const imports = [...source.matchAll(/^import \{([^}]+)\} from .+$/gm)]
  const environment = Object.fromEntries(imports.flatMap(([, names]) => names.split(",").map(name => [name.trim(), () => ({start() {}})])))
  let options
  environment.LiveSocket = class {
    constructor(_path, _socket, received) { options = received }
    connect() {}
  }
  environment.document = {addEventListener() {}, querySelector: () => ({content: "csrf-test"})}
  environment.window = {matchMedia() {}}
  environment.URL = URL
  runInNewContext(source.replace(/^import .+$/gm, "").replaceAll("import.meta.url", JSON.stringify("https://example.test/assets/current/control-plane.js")), environment)
  return options
}

test("a retained long timeline can finish joining before the client abandons its reply", () => {
  // The production case's 6.6 MB join arrived in 11,813 ms (11,690 ms over
  // the direct tunnel). Phoenix's default 10 seconds discarded that success
  // and reloaded forever, leaving recovery buttons unusable.
  const options = connectionOptions()
  const deadline = options.timeout ?? 10_000
  assert.ok(deadline > 11_813, "the measured successful join must not be abandoned")
  assert.ok(deadline <= 30_000, "an unreachable server must still time out within 30 seconds")
  assert.equal(options.params()._csrf_token, "csrf-test")
  assert.equal(options.params().asset_bundle, "/assets/current/control-plane.js")
})

function channelClock() {
  let now = 0, serial = 0
  const timers = new Map(), sent = []
  const source = readFileSync(resolve(process.env.MIX_DEPS_PATH || "deps", "phoenix/priv/static/phoenix.mjs"), "utf8")
  const {Socket} = runInNewContext(source.replace(/export \{[^}]+\};/, "") + "\n({Socket})", {
    setTimeout(callback, delay) { const id = ++serial; timers.set(id, {at: now + delay, callback}); return id },
    clearTimeout(id) { timers.delete(id) }, console
  })
  const socket = new Socket("/live", {...connectionOptions(), transport: class {}})
  socket.isConnected = () => true
  socket.push = message => sent.push(message)
  const channel = socket.channel("lv:retained-timeline", {})
  const outcomes = []
  channel.join().receive("ok", () => outcomes.push("joined")).receive("timeout", () => outcomes.push("timeout"))
  return {outcomes, channel,
    tick(to) {
      while (true) {
        const due = [...timers].filter(([, timer]) => timer.at <= to).sort((a, b) => a[1].at - b[1].at)[0]
        if (!due) break
        const [id, timer] = due; timers.delete(id); now = timer.at; timer.callback()
      }
      now = to
    },
    acknowledge() { channel.trigger("phx_reply", {status: "ok", response: {}}, sent[0].ref) }
  }
}

test("the real Phoenix channel accepts both prompt and twelve-second joins without timing out", () => {
  for (const latency of [50, 12_000]) {
    const clock = channelClock()
    clock.tick(latency)
    clock.acknowledge()
    clock.tick(30_001)
    assert.deepEqual(clock.outcomes, ["joined"])
    assert.ok(clock.channel.isJoined())
  }
})

test("the real Phoenix channel still reports an unanswered join at thirty seconds", () => {
  const clock = channelClock()
  clock.tick(29_999)
  assert.deepEqual(clock.outcomes, [])
  clock.tick(30_000)
  assert.deepEqual(clock.outcomes, ["timeout"])
})
