-- Minimal mutable global, for asserting that a revert really puts the Lua heap
-- back rather than only the value the caller happened to be holding.
count = 0

function bump()
  count = count + 1
  return count
end
