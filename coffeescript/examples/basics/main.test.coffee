# Keep the numeric acceptance rule visible beside the canonical teaching file.
test = require 'node:test'
assert = require 'node:assert/strict'

test 'Convex integral decimal JSON values remain JavaScript integers', ->
  assert.equal Number.isSafeInteger(0.0), true
  assert.equal Number.isSafeInteger(1.0), true
  assert.equal Number.isSafeInteger(1.5), false
  assert.equal Number.isSafeInteger('1'), false
