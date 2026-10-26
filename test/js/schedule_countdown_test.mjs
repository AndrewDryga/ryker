import {test} from "node:test"
import assert from "node:assert/strict"
import {createScheduleCountdown, formatCountdown} from "../../priv/static/schedule-countdown.mjs"

test("next run reads in days, hours and minutes, and never promises an overdue run", () => {
  for (const [seconds, text] of [
    [183600, "Next run in 2 days 3 hours"], [3660, "Next run in 1 hour 1 minute"],
    [120, "Next run in 2 minutes"], [60, "Next run in 1 minute"],
    [59, "Next run in less than a minute"], [0, "Due now"],
    [-59, "Due now"], [-60, "Overdue by 1 minute"], [-86400, "Overdue by 1 day"]
  ]) assert.equal(formatCountdown(seconds), text)
})

test("the countdown advances, accepts a new due time and stops after navigation", () => {
  let now = 1000
  let tick
  let cleared
  const element = {dataset: {remainingSeconds: "120"}, textContent: ""}
  const hook = createScheduleCountdown(element, {
    now: () => now,
    setInterval: callback => { tick = callback; return 42 },
    clearInterval: timer => { cleared = timer }
  })
  hook.mounted()
  assert.equal(element.textContent, "Next run in 2 minutes")
  now += 120000; tick()
  assert.equal(element.textContent, "Due now")
  now += 60000; tick()
  assert.equal(element.textContent, "Overdue by 1 minute")
  element.dataset.remainingSeconds = "3600"; hook.updated()
  assert.equal(element.textContent, "Next run in 1 hour")
  hook.destroyed()
  assert.equal(cleared, 42)
})
