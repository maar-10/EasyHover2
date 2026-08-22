-- nav/lib/trilaterate.lua
-- Multilateration for the broadcast GPS: solve a receiver's world position from >=4 beacon
-- observations `{ pos = {x,y,z}, dist = <blocks> }` (the beacon's broadcast coordinates plus the
-- CC per-message `distance`). Because the EH2 GPS is passive/broadcast, it does NOT use CC's
-- request-based gps.locate() -- this is our own solver.
--
-- Method: take one beacon as the reference and subtract its sphere equation |X-P1|^2 = r1^2 from
-- the other three, which cancels the quadratic |X|^2 term and linearises into a 3x3 system
-- A*X = b. The determinant of A is the degeneracy guard: coplanar/collinear hosts make it ~0, and
-- that quartet is rejected rather than returning a garbage (or mirror-ambiguous) fix.
--
-- With MORE than 4 observations, every 4-subset is solved (C(n,4); n is small) and scored by the
-- summed squared residual against ALL observations -- so one badly-placed alphabetical quartet no
-- longer degrades (or nils) a fix that better geometry could deliver. Pure; no globals/peripherals.
local M = {}

local function det3(m)
  return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
       - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
       + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
end

--- Solve from exactly four observations (indices into obs). Returns { x, y, z } or nil if degenerate.
local function solveQuartet(o1, o2, o3, o4)
  local p1, r1 = o1.pos, o1.dist
  local s1 = p1.x * p1.x + p1.y * p1.y + p1.z * p1.z

  local A, b = {}, {}
  local others = { o2, o3, o4 }
  for i = 1, 3 do
    local p, r = others[i].pos, others[i].dist
    A[i] = { 2 * (p.x - p1.x), 2 * (p.y - p1.y), 2 * (p.z - p1.z) }
    local si = p.x * p.x + p.y * p.y + p.z * p.z
    b[i] = (si - s1) - (r * r - r1 * r1)
  end

  local D = det3(A)
  if math.abs(D) < 1e-9 then return nil end   -- coplanar / collinear -> no unique fix

  local function colReplaced(col)
    local m = { { A[1][1], A[1][2], A[1][3] },
                { A[2][1], A[2][2], A[2][3] },
                { A[3][1], A[3][2], A[3][3] } }
    m[1][col], m[2][col], m[3][col] = b[1], b[2], b[3]
    return m
  end

  return {
    x = det3(colReplaced(1)) / D,
    y = det3(colReplaced(2)) / D,
    z = det3(colReplaced(3)) / D,
  }
end

local function residual2(sol, obs)
  local sum = 0
  for i = 1, #obs do
    local p = obs[i].pos
    local dx, dy, dz = sol.x - p.x, sol.y - p.y, sol.z - p.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz) - obs[i].dist
    sum = sum + d * d
  end
  return sum
end

--- obs: array of >=4 { pos = {x,y,z}, dist = n }. Returns { x, y, z } or nil (too few / all degenerate).
function M.solve(obs)
  if type(obs) ~= "table" or #obs < 4 then return nil end
  local best, bestScore
  local n = #obs
  for a = 1, n - 3 do for b = a + 1, n - 2 do for c = b + 1, n - 1 do for d = c + 1, n do
    local sol = solveQuartet(obs[a], obs[b], obs[c], obs[d])
    if sol then
      local score = residual2(sol, obs)
      if not bestScore or score < bestScore then best, bestScore = sol, score end
    end
  end end end end
  return best
end

return M
