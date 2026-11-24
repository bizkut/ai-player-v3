-- Event-driven machine registry.
--
-- A maintained SET of this AI force's production machines, keyed by unit_number,
-- so perception does NOT rescan the whole surface every tick (see
-- perception.lua gather_factory). Correctness model, in order of authority:
--   1. reconcile()  — periodic full surface scan; the backbone. Rebuilds the set
--                     from scratch, so anything missed by events self-corrects.
--   2. add()/remove()— event-driven updates for immediacy between reconciles.
--   3. lazy pruning  — machines() drops invalid refs on read (covers AI self-
--                     mining and any destroy path that fired no event).
--
-- LuaEntity references persist in `storage` across save/load (becoming invalid
-- if destroyed), so the set survives save/load with no work; only a fresh game
-- or a mod update needs the first reconcile.

AIRegistry = {}

-- Production machines worth tracking (mirrors perception MACHINE_TYPES).
local TRACKED_TYPES = {
  ["assembling-machine"] = true, ["furnace"] = true, ["mining-drill"] = true,
  ["lab"] = true, ["boiler"] = true, ["generator"] = true, ["ammo-turret"] = true,
  ["offshore-pump"] = true, ["pump"] = true, ["rocket-silo"] = true,
}

-- Array form for find_entities_filtered + a type-OR filter list for events.
local TYPE_LIST = {}
local EVENT_FILTERS = {}
for t in pairs(TRACKED_TYPES) do
  TYPE_LIST[#TYPE_LIST + 1] = t
  -- First filter must have NO mode; subsequent ones OR onto it. (Note: the
  -- `cond and nil or x` idiom can't express this — nil is falsy — so branch.)
  local f = {filter = "type", type = t}
  if #EVENT_FILTERS > 0 then f.mode = "or" end
  EVENT_FILTERS[#EVENT_FILTERS + 1] = f
end

function AIRegistry.is_tracked_type(t) return TRACKED_TYPES[t] == true end
function AIRegistry.event_filters() return EVENT_FILTERS end

local function store()
  storage.ai_player.machines = storage.ai_player.machines or {}
  return storage.ai_player.machines
end

local function ai_force_name()
  return storage.ai_player and storage.ai_player.force_name
end

-- Register a machine. Ignores non-tracked types and entities not on the AI force,
-- so human/enemy builds never enter the set. placed_by_ai records the AI's own
-- placements (see is_own).
function AIRegistry.add(entity, placed_by_ai)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not TRACKED_TYPES[entity.type] then return end
  if entity.force.name ~= ai_force_name() then return end
  store()[entity.unit_number] = entity
  if placed_by_ai then storage.ai_player.placed[entity.unit_number] = entity end
end

-- May the AI empty this machine's output? Solo: the AI has a force to itself, so
-- everything on it is its own. Co-op: the force is shared with the human, so only
-- machines the AI placed itself count; it never drains the human's production.
-- storage.ai_player.placed: unit_number -> LuaEntity for AI placements.
function AIRegistry.is_own(entity)
  if entity.force.name ~= "player" then return true end
  return storage.ai_player.placed[entity.unit_number] ~= nil
end

-- /ai-claim. Saves from before placement tracking hold no record of what the AI
-- placed. Its machines have no last_user (created by script), but neither do
-- machines whose builder has left the save, so claiming is the human's call and
-- never automatic. Returns how many machines were claimed.
function AIRegistry.claim_unowned()
  local placed, claimed = storage.ai_player.placed, 0
  for un, e in pairs(store()) do
    if e.valid and e.last_user == nil and not placed[un] then
      placed[un] = e
      claimed = claimed + 1
    end
  end
  return claimed
end

function AIRegistry.remove(unit_number)
  if unit_number then store()[unit_number] = nil end
end

-- Per-tick read path: valid tracked machines as a plain array, pruning invalid
-- refs as we go. No surface query.
function AIRegistry.machines()
  local m = store()
  local out = {}
  for un, e in pairs(m) do
    if e.valid then out[#out + 1] = e else m[un] = nil end
  end
  return out
end

function AIRegistry.count()
  local m = store()
  local n = 0
  for un, e in pairs(m) do
    if e.valid then n = n + 1 else m[un] = nil end
  end
  return n
end

-- Finished products waiting in the output slots of the AI's own machines: how
-- many `item` in total, and the machine holding some that is nearest to `origin`.
function AIRegistry.output_stock(item, origin)
  local total, nearest, nd = 0, nil, math.huge
  for _, e in ipairs(AIRegistry.machines()) do
    local out = AIRegistry.is_own(e) and e.get_output_inventory()
    local n = out and out.get_item_count(item) or 0
    if n > 0 then
      total = total + n
      local dx, dy = e.position.x - origin.x, e.position.y - origin.y
      local d = dx * dx + dy * dy
      if d < nd then nd = d; nearest = e end
    end
  end
  return total, nearest
end

-- Full reconciliation: rebuild the set from a surface scan. The authoritative
-- correction path — call periodically (not every tick) and on load/update.
function AIRegistry.reconcile(surface, force)
  if not (surface and force) then return end
  local m = {}
  for _, e in ipairs(surface.find_entities_filtered{force = force, type = TYPE_LIST}) do
    if e.valid and e.unit_number then m[e.unit_number] = e end
  end
  storage.ai_player.machines = m
  for un, e in pairs(storage.ai_player.placed) do
    if not e.valid then storage.ai_player.placed[un] = nil end
  end
  storage.ai_player.last_reconcile_tick = game.tick
end

return AIRegistry
