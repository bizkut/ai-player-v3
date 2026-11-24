-- Hand-crafting bookkeeping for the AI character.
--
-- The AI is a script-created character with no player attached. The engine runs
-- its crafting queue and records the ingredients it consumes, but the PRODUCT
-- side is only recorded for players: nothing an unattached character finishes
-- reaches the force's production statistics. Those statistics are also what
-- "craft-item" trigger technologies watch, so the AI could hand-craft the lab
-- that unlocks automation-science-pack and never get the research (reproduced
-- on 2.0.72: lab crafted, "lab made = 0", technology not researched; one
-- stats.on_flow("lab", 1) and the engine researches it on the next tick).
--
-- So every hand-craft is queued through AICrafting.begin, and AICrafting.poll
-- (on_tick) reports what the queue has finished since the last look.

AICrafting = {}

-- Crafts still queued, summed per recipe (auto-queued prerequisites included).
local function queue_counts(character)
  local counts = {}
  for _, item in pairs(character.crafting_queue or {}) do
    counts[item.recipe] = (counts[item.recipe] or 0) + item.count
  end
  return counts
end

-- Record `crafts` finished runs of a recipe as production. Products with a random
-- amount (ranged or probabilistic) are skipped: the real outcome is unknown here.
local function credit(character, recipe_name, crafts)
  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return end
  local stats = character.force.get_item_production_statistics(character.surface)
  for _, product in pairs(recipe.products) do
    if product.type == "item" and product.amount and (product.probability or 1) == 1 then
      local made = (product.amount - (product.ignored_by_stats or 0)) * crafts
      if made > 0 then stats.on_flow(product.name, made) end
    end
  end
end

-- Credit everything the queue finished since the last poll, then remember what is
-- still queued: storage.ai_player.craft_queue = {owner = unit_number, counts =
-- {recipe -> crafts}}, or nil while nothing is queued. `owner` keeps a respawned
-- character from being credited for the queue its predecessor lost.
function AICrafting.poll(character)
  local s = storage.ai_player
  local seen = s.craft_queue
  if not seen and character.crafting_queue_size == 0 then return end
  local now = queue_counts(character)
  if seen and seen.owner == character.unit_number then
    for recipe, before in pairs(seen.counts) do
      local finished = before - (now[recipe] or 0)
      if finished > 0 then credit(character, recipe, finished) end
    end
  end
  s.craft_queue = next(now) and {owner = character.unit_number, counts = now} or nil
end

-- character.begin_crafting, tracked. Returns the number of crafts queued.
function AICrafting.begin(character, recipe, count)
  AICrafting.poll(character)  -- settle what finished before the queue changes
  local queued = character.begin_crafting{recipe = recipe, count = count}
  AICrafting.poll(character)  -- start tracking the new entries
  return queued
end

return AICrafting
