// [unit] studio/carousel's centerStops: where a spotlight row rests for each slide.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/carousel.js", import.meta.url), "utf8")
const { centerStops, currentStop, startStop } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A 1000px row padded 350px each end, five 300px slides 8px apart: each slide's
// centre is half a row from its stop, and the row runs 0 to 1232.
const slides = [0, 1, 2, 3, 4].map((i) => ({ left: 350 + i * 308, width: 300 }))
const MAX = 350 * 2 + 5 * 300 + 4 * 8 - 1000

test("each slide's stop centres it", () => {
  assert.deepEqual(centerStops(slides, 1000, MAX), [0, 308, 616, 924, 1232])
})

test("a stop is held to the row: a short pad cannot centre the first or last", () => {
  const unpadded = [0, 1, 2].map((i) => ({ left: i * 400, width: 400 }))
  assert.deepEqual(centerStops(unpadded, 1000, 200), [0, 100, 200])
})

test("an empty row rests at its start", () => {
  assert.deepEqual(centerStops([], 1000, 0), [0])
})

test("the centred slide is the nearest stop, and the last from the end", () => {
  const positions = centerStops(slides, 1000, MAX)
  assert.equal(currentStop(0, positions), 0)
  assert.equal(currentStop(150, positions), 0)
  assert.equal(currentStop(160, positions), 1)
  assert.equal(currentStop(1231, positions), 4)
})

test("a row opens on its start stop, held to the stops it has", () => {
  assert.equal(startStop(3, 7), 3)
  assert.equal(startStop(5, 4), 3)
  assert.equal(startStop(-1, 4), 0)
  assert.equal(startStop("2", 4), 2)
  assert.equal(startStop(2, 0), 0)
})
