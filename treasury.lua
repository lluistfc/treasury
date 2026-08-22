--[[
Standalone Ashita v4 port inspired by Windower Treasury.
Original Treasury Copyright (c) 2014-2018, Windower contributors.
Original code is BSD 3-Clause licensed; see LICENSE-WINDOWER.
]]

addon.name = 'treasury'
addon.author = 'Ihina; Windower contributors; Ashita v4 port'
addon.version = '1.1.0'
addon.desc = 'Manages configured treasure-pool items and removes unwanted inventory items.'

require 'common'

local chat = require 'chat'
local settings = require 'settings'

local defaults = T {
    pass = T {},
    lot = T {},
    drop = T {},
    delay = 0,
    verbose = false,
}

local state = {
    settings = settings.load(defaults),
    pass_ids = {},
    lot_ids = {},
    drop_ids = {},
    queue = {},
    handled = {},
    drop_queue = {},
    drop_handled = {},
    inventory_counter = nil,
}

local groups = {
    crystals = { 4096, 4097, 4098, 4099, 4100, 4101, 4102, 4103 },
    seals = { 1126, 1127, 2955, 2956, 2957 },
    currency = { 1449, 1450, 1451, 1452, 1453, 1454, 1455, 1456, 1457 },
    geodes = { 3297, 3298, 3299, 3300, 3301, 3302, 3303, 3304 },
    avatarites = { 3520, 3521, 3522, 3523, 3524, 3525, 3526, 3527 },
    detritus = { 9875, 9876 },
    heroism = { 9877, 9878 },
}

local function is_valid_item_id(id)
    return id ~= nil and id > 0 and id ~= 65535
end

local function build_id_set(values)
    local result = {}
    for _, value in ipairs(values or T {}) do
        local id = tonumber(value)
        if id ~= nil then
            result[id] = true
        end
    end
    return result
end

local function item_name(id)
    local item = AshitaCore:GetResourceManager():GetItemById(id)
    if item ~= nil and item.Name ~= nil and item.Name[1] ~= nil and item.Name[1] ~= '' then
        return item.Name[1]
    end
    return ('Item %u'):format(id)
end

local function rebuild()
    state.pass_ids = build_id_set(state.settings.pass)
    state.lot_ids = build_id_set(state.settings.lot)
    state.drop_ids = build_id_set(state.settings.drop)
end

settings.register('settings', 'settings_update', function(s)
    state.settings = s
    rebuild()
end)

local function save()
    settings.save()
    rebuild()
end

local function print_message(message)
    print(chat.header(addon.name):append(chat.message(message)))
end

local function print_error(message)
    print(chat.header(addon.name):append(chat.error(message)))
end

local function wildcard_pattern(value)
    local escaped = value:lower():gsub('([%%%^%$%(%)%.%[%]%+%-])', '%%%1')
    return '^' .. escaped:gsub('%*', '.*'):gsub('%?', '.') .. '$'
end

local function find_ids(query)
    query = (query or ''):lower()
    if query == 'pool' then
        local result = {}
        local inventory = AshitaCore:GetMemoryManager():GetInventory()
        if inventory ~= nil then
            for slot = 0, 9 do
                local entry = inventory:GetTreasurePoolItem(slot)
                if entry ~= nil and is_valid_item_id(entry.ItemId) then
                    result[entry.ItemId] = true
                end
            end
        end
        return result
    end
    if groups[query] ~= nil then
        local result = {}
        for _, id in ipairs(groups[query]) do
            result[id] = true
        end
        return result
    end
    local numeric = tonumber(query)
    if numeric ~= nil then
        numeric = math.floor(numeric)
        local item = AshitaCore:GetResourceManager():GetItemById(numeric)
        return item ~= nil and { [numeric] = true } or {}
    end

    local result = {}
    local pattern = wildcard_pattern(query)
    local resources = AshitaCore:GetResourceManager()
    for id = 1, 65535 do
        local item = resources:GetItemById(id)
        if item ~= nil and item.Name ~= nil then
            local name = (item.Name[1] or ''):lower()
            local log_name = (item.LogName and item.LogName[1] or ''):lower()
            if name:match(pattern) ~= nil or log_name:match(pattern) ~= nil then
                result[id] = true
            end
        end
    end
    return result
end

local function list_contains(list, id)
    for _, current in ipairs(list) do
        if tonumber(current) == id then
            return true
        end
    end
    return false
end

local scan_pool
local scan_inventory

local function mutate(kind, operation, query)
    local ids = find_ids(query)
    local count = 0
    local list = state.settings[kind]
    for id, _ in pairs(ids) do
        if operation == 'add' and not list_contains(list, id) then
            list:append(id)
            count = count + 1
        elseif operation == 'remove' then
            for index = #list, 1, -1 do
                if tonumber(list[index]) == id then
                    table.remove(list, index)
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then
        print_error 'No matching items were changed.'
        return
    end
    save()
    if kind == 'drop' then
        scan_inventory()
    else
        scan_pool()
    end
    print_message(
        ('%s %u item(s) %s the %s list.'):format(
            operation == 'add' and 'Added' or 'Removed',
            count,
            operation == 'add' and 'to' or 'from',
            kind
        )
    )
end

-- Sends FFXI's inventory discard packet. This is intentionally independent of
-- treasure-pool handling: entries on the drop list are never automatically passed.
local function send_drop(index, count)
    count = math.max(1, math.floor(tonumber(count) or 1))
    index = math.floor(tonumber(index) or 0)
    if index <= 0 or index > 255 then
        return
    end
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x028, {
        0x00,
        0x00,
        0x00,
        0x00,
        count % 0x100,
        math.floor(count / 0x100) % 0x100,
        math.floor(count / 0x10000) % 0x100,
        math.floor(count / 0x1000000) % 0x100,
        0x00, -- Inventory container only.
        index,
    })
end

scan_inventory = function()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if inventory == nil then
        return
    end
    local active = {}
    local maximum = tonumber(inventory:GetContainerCountMax(0)) or 0
    for slot = 1, maximum do
        local item = inventory:GetContainerItem(0, slot)
        local id = item and tonumber(item.Id) or 0
        if is_valid_item_id(id) and state.drop_ids[id] then
            local index = tonumber(item.Index) or slot
            local count = tonumber(item.Count) or 1
            local key = ('%u:%u'):format(index, id)
            active[key] = true
            if not state.drop_handled[key] then
                state.drop_handled[key] = true
                table.insert(state.drop_queue, {
                    index = index,
                    item_id = id,
                    count = count,
                    due = os.clock() + 0.25,
                    key = key,
                })
            end
        end
    end
    for key, _ in pairs(state.drop_handled) do
        if not active[key] then
            state.drop_handled[key] = nil
        end
    end
end

-- Forces a new cleanup pass over the main Inventory. Resetting the handled
-- state is important because a previous scan may have already seen the same
-- slot before the user explicitly requested cleanup.
local function clean_inventory()
    state.drop_queue = {}
    state.drop_handled = {}
    scan_inventory()
    return #state.drop_queue
end

local function send_action(action, slot)
    local id = action == 'lot' and 0x41 or 0x42
    local packet = struct.pack('bbbbbbbb', id, 0x04, 0x00, 0x00, slot, 0x00, 0x00, 0x00):totable()
    AshitaCore:GetPacketManager():AddOutgoingPacket(packet[1], packet)
end

local function queue_action(slot, item_id)
    if slot == nil or slot < 0 or slot > 9 or not is_valid_item_id(item_id) then
        return
    end
    local action = state.lot_ids[item_id] and 'lot' or (state.pass_ids[item_id] and 'pass' or nil)
    if action == nil then
        return
    end
    local key = ('%u:%u'):format(slot, item_id)
    if state.handled[key] then
        return
    end
    state.handled[key] = true
    local delay = math.max(0, tonumber(state.settings.delay) or 0)
    local due = os.clock() + (delay > 0 and delay * (0.5 + math.random() * 0.5) or 0)
    table.insert(state.queue, { slot = slot, item_id = item_id, action = action, due = due, key = key })
end

scan_pool = function()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if inventory == nil then
        return
    end
    local active = {}
    for slot = 0, 9 do
        local entry = inventory:GetTreasurePoolItem(slot)
        if entry ~= nil and is_valid_item_id(entry.ItemId) then
            active[('%u:%u'):format(slot, entry.ItemId)] = true
            queue_action(slot, entry.ItemId)
        end
    end
    for key, _ in pairs(state.handled) do
        if not active[key] then
            state.handled[key] = nil
        end
    end
end

local function print_list(kind)
    local list = state.settings[kind] or T {}
    print_message(('%s list (%u):'):format(kind, #list))
    for _, id in ipairs(list) do
        print_message(('  %s [%u]'):format(item_name(tonumber(id)), tonumber(id)))
    end
end

local function print_help()
    print_message 'Commands:'
    print_message '/tr pass/lot/drop add/remove <item name, id, wildcard, group, or pool>'
    print_message '/tr pass/lot/drop list/clear'
    print_message '/tr passall/lotall/done'
    print_message '/tr clean (or dropall) - Drop all Inventory matches'
    print_message '/tr delay <seconds>; verbose [on/off]; reload'
    print_message 'Groups: crystals, seals, currency, geodes, avatarites, detritus, heroism'
end

ashita.events.register('load', 'load_cb', function()
    rebuild()
    scan_pool()
    scan_inventory()
end)

ashita.events.register('packet_in', 'packet_in_cb', function(e)
    if e.id == 0x00D2 then
        local item_id = struct.unpack('H', e.data, 0x10 + 1)
        local slot = struct.unpack('B', e.data, 0x14 + 1)
        queue_action(slot, item_id)
    elseif e.id == 0x00D3 then
        local slot = struct.unpack('B', e.data, 0x14 + 1)
        if slot ~= nil and slot < 10 then
            local prefix = ('%u:'):format(slot)
            for key, _ in pairs(state.handled) do
                if key:sub(1, #prefix) == prefix then
                    state.handled[key] = nil
                end
            end
        end
    elseif e.id == 0x000A or e.id == 0x000B then
        state.queue = {}
        state.handled = {}
        state.drop_queue = {}
        state.drop_handled = {}
        state.inventory_counter = nil
    end
end)

ashita.events.register('d3d_present', 'present_cb', function()
    local now = os.clock()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if inventory ~= nil then
        local counter = inventory:GetContainerUpdateCounter()
        if counter ~= state.inventory_counter then
            state.inventory_counter = counter
            scan_inventory()
        end
    end

    -- Discard at most one stack per frame and revalidate the slot immediately
    -- before sending, so moved or changed items cannot be deleted accidentally.
    for index = #state.drop_queue, 1, -1 do
        local pending = state.drop_queue[index]
        if now >= pending.due then
            table.remove(state.drop_queue, index)
            local current = inventory and inventory:GetContainerItem(0, pending.index) or nil
            if current ~= nil and tonumber(current.Id) == pending.item_id and state.drop_ids[pending.item_id] then
                local count = tonumber(current.Count) or pending.count
                send_drop(pending.index, count)
                if state.settings.verbose then
                    print_message(('Dropping %s x%u.'):format(item_name(pending.item_id), count))
                end
            end
            break
        end
    end

    for index = #state.queue, 1, -1 do
        local pending = state.queue[index]
        if now >= pending.due then
            table.remove(state.queue, index)
            local inventory = AshitaCore:GetMemoryManager():GetInventory()
            local current = inventory and inventory:GetTreasurePoolItem(pending.slot) or nil
            if current ~= nil and current.ItemId == pending.item_id then
                local lot = tonumber(current.Lot) or 0
                local configured = state.lot_ids[pending.item_id] and 'lot'
                    or (state.pass_ids[pending.item_id] and 'pass' or nil)
                if
                    configured == pending.action
                    and (
                        (pending.action == 'pass' and lot ~= 65535)
                        or (pending.action == 'lot' and (lot == 0 or lot >= 65535))
                    )
                then
                    send_action(pending.action, pending.slot)
                    if state.settings.verbose then
                        print_message(
                            ('%s %s.'):format(
                                pending.action == 'lot' and 'Lotting' or 'Passing',
                                item_name(pending.item_id)
                            )
                        )
                    end
                end
            end
        end
    end
end)

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args()
    if #args == 0 or not args[1]:any('/treasury', '/tr') then
        return
    end
    e.blocked = true
    local command = (#args >= 2 and args[2]:lower()) or 'help'
    if command:any('pass', 'p', 'lot', 'l', 'drop', 'd') then
        local kind = command:any('lot', 'l') and 'lot' or (command:any('drop', 'd') and 'drop' or 'pass')
        local operation = (#args >= 3 and args[3]:lower()) or 'list'
        if operation:any('add', 'a', '+', 'remove', 'r', '-') and #args >= 4 then
            mutate(kind, operation:any('add', 'a', '+') and 'add' or 'remove', table.concat(args, ' ', 4))
        elseif operation == 'list' then
            print_list(kind)
        elseif operation == 'clear' then
            state.settings[kind] = T {}
            save()
            print_message(kind .. ' list cleared.')
        else
            print_help()
        end
    elseif command:any('clean', 'dropall') then
        local count = clean_inventory()
        if count > 0 then
            print_message(('Queued %u matching Inventory stack(s) for cleanup.'):format(count))
        else
            print_message 'No items in the main Inventory match the drop list.'
        end
    elseif command:any('passall', 'lotall', 'done') then
        local inventory = AshitaCore:GetMemoryManager():GetInventory()
        if inventory ~= nil then
            for slot = 0, 9 do
                local entry = inventory:GetTreasurePoolItem(slot)
                if entry ~= nil and is_valid_item_id(entry.ItemId) then
                    local lot = tonumber(entry.Lot) or 0
                    if command == 'passall' and lot ~= 65535 then
                        send_action('pass', slot)
                    elseif command == 'lotall' and (lot == 0 or lot >= 65535) then
                        send_action('lot', slot)
                    elseif command == 'done' and lot == 0 then
                        send_action('pass', slot)
                    end
                end
            end
        end
    elseif command == 'delay' and tonumber(args[3]) ~= nil then
        state.settings.delay = math.max(0, tonumber(args[3]))
        save()
        print_message(('Delay set to %.2f seconds.'):format(state.settings.delay))
    elseif command == 'verbose' then
        local value = args[3] and args[3]:lower() or nil
        if value == nil then
            state.settings.verbose = not state.settings.verbose
        elseif value:any('on', 'true', '1') then
            state.settings.verbose = true
        elseif value:any('off', 'false', '0') then
            state.settings.verbose = false
        else
            print_error 'Expected verbose on or off.'
            return
        end
        save()
        print_message('Verbose output ' .. (state.settings.verbose and 'enabled.' or 'disabled.'))
    elseif command:any('reload', 'rl') then
        settings.reload()
        scan_pool()
        scan_inventory()
        print_message 'Settings reloaded.'
    elseif command:any('help', 'h') then
        print_help()
    else
        print_help()
    end
end)
