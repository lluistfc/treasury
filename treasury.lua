--[[
Standalone Ashita v4 port inspired by Windower Treasury.
Original Treasury Copyright (c) 2014-2018, Windower contributors.
Original code is BSD 3-Clause licensed; see LICENSE-WINDOWER.
]]

addon.name = 'treasury'
addon.author = 'Ihina; Windower contributors; Ashita v4 port'
addon.version = '1.2.0'
addon.desc = 'Manages configured treasure-pool items and removes unwanted inventory items.'

require 'common'

local chat = require 'chat'
local imgui = require 'imgui'
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
    config_open = { false },
    inventory_open = { false },
    rule_rows = { pass = {}, lot = {}, drop = {} },
    rule_pages = { pass = 1, lot = 1, drop = 1 },
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
    for _, kind in ipairs { 'pass', 'lot', 'drop' } do
        local rows = {}
        for id, _ in pairs(state[kind .. '_ids']) do
            table.insert(rows, { id = id, name = item_name(id) })
        end
        table.sort(rows, function(left, right)
            local left_name = left.name:lower()
            local right_name = right.name:lower()
            return left_name == right_name and left.id < right.id or left_name < right_name
        end)
        state.rule_rows[kind] = rows
    end
end

local scan_pool
local scan_inventory

settings.register('settings', 'settings_update', function(s)
    state.settings = s
    rebuild()
    state.queue = {}
    state.handled = {}
    state.drop_queue = {}
    state.drop_handled = {}
    if scan_pool ~= nil then
        scan_pool()
    end
    if scan_inventory ~= nil then
        scan_inventory()
    end
end)

local function save()
    settings.save()
    rebuild()
end

local function refresh_rules(kind)
    if kind == 'drop' then
        state.drop_queue = {}
        state.drop_handled = {}
        scan_inventory()
    else
        state.queue = {}
        state.handled = {}
        scan_pool()
    end
end

local function save_rules(kind)
    save()
    refresh_rules(kind)
end

local function remove_id(kind, id)
    local list = state.settings[kind]
    for index = #list, 1, -1 do
        if tonumber(list[index]) == id then
            table.remove(list, index)
        end
    end
    save_rules(kind)
end

local function add_drop_id(id)
    if state.drop_ids[id] then
        return false
    end
    state.settings.drop:append(id)
    save_rules 'drop'
    return true
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
    save_rules(kind)
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
    print_message(table.concat({
        'Commands:',
        '  /tr config                         Open configuration',
        '  /tr inventory                      Open main Inventory list',
        '  /tr <pass|lot|drop> add <query>    Add matching items',
        '  /tr <pass|lot|drop> remove <query> Remove matching items',
        '  /tr <pass|lot|drop> list           Show configured items',
        '  /tr <pass|lot|drop> clear          Clear configured items',
        '  /tr <passall|lotall|done>          Act on the treasure pool',
        '  /tr clean                          Drop matching Inventory stacks',
        '  /tr delay <seconds>                Set action delay',
        '  /tr verbose [on|off]               Toggle verbose output',
        '  /tr reload                         Reload settings',
        'Queries: item name, ID, wildcard, group, or pool',
        'Groups: crystals, seals, currency, geodes, avatarites, detritus, heroism',
    }, '\n'))
end

local function draw_rule_list(kind)
    local rows = state.rule_rows[kind]
    local page_size = 100
    local page_count = math.max(1, math.ceil(#rows / page_size))
    state.rule_pages[kind] = math.min(state.rule_pages[kind], page_count)
    local page = state.rule_pages[kind]
    imgui.Text(('%u configured item(s)'):format(#rows))
    if page_count > 1 then
        imgui.SameLine()
        if imgui.SmallButton('Previous##' .. kind) and page > 1 then
            page = page - 1
        end
        imgui.SameLine()
        imgui.Text(('Page %u/%u'):format(page, page_count))
        imgui.SameLine()
        if imgui.SmallButton('Next##' .. kind) and page < page_count then
            page = page + 1
        end
        state.rule_pages[kind] = page
    end
    imgui.Separator()
    imgui.BeginChild('##' .. kind .. '_rules', { 420, 300 }, ImGuiChildFlags_Borders)
    local remove = nil
    local first = (page - 1) * page_size + 1
    local last = math.min(page * page_size, #rows)
    for index = first, last do
        local row = rows[index]
        if imgui.SmallButton(('Remove##%s_%u'):format(kind, row.id)) then
            remove = row.id
        end
        imgui.SameLine()
        imgui.Text(('%s [%u]'):format(row.name, row.id))
    end
    imgui.EndChild()
    if remove ~= nil then
        remove_id(kind, remove)
    end
end

local function draw_config_window()
    if not state.config_open[1] then
        return
    end
    if imgui.Begin('Treasury Configuration##treasury_config', state.config_open) then
        if imgui.Button 'Open Inventory List' then
            state.inventory_open[1] = true
        end
        imgui.SameLine()
        imgui.Text 'Use the tabs to review or remove configured items.'
        if imgui.BeginTabBar '##treasury_rule_tabs' then
            if imgui.BeginTabItem 'Pass' then
                draw_rule_list 'pass'
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem 'Lot' then
                draw_rule_list 'lot'
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem 'Drop' then
                draw_rule_list 'drop'
                imgui.EndTabItem()
            end
            imgui.EndTabBar()
        end
    end
    imgui.End()
end

local function inventory_rows()
    local result = {}
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    local resources = AshitaCore:GetResourceManager()
    if inventory == nil then
        return result
    end
    local maximum = tonumber(inventory:GetContainerCountMax(0)) or 0
    for slot = 1, maximum do
        local entry = inventory:GetContainerItem(0, slot)
        local id = entry and tonumber(entry.Id) or 0
        local resource = is_valid_item_id(id) and resources:GetItemById(id) or nil
        local equipment_slots = resource and tonumber(resource.Slots) or 0
        if is_valid_item_id(id) and equipment_slots == 0 then
            table.insert(result, {
                id = id,
                slot = slot,
                count = tonumber(entry.Count) or 1,
                name = item_name(id),
            })
        end
    end
    table.sort(result, function(left, right)
        local left_name = left.name:lower()
        local right_name = right.name:lower()
        return left_name == right_name and left.slot < right.slot or left_name < right_name
    end)
    return result
end

local function draw_inventory_window()
    if not state.inventory_open[1] then
        return
    end
    if imgui.Begin('Treasury Inventory##treasury_inventory', state.inventory_open) then
        imgui.Text 'Main Inventory items'
        imgui.SameLine()
        if imgui.SmallButton 'Refresh##inventory' then
            state.inventory_counter = nil
        end
        imgui.Separator()
        imgui.BeginChild('##treasury_inventory_list', { 480, 360 }, ImGuiChildFlags_Borders)
        local rows = inventory_rows()
        if #rows == 0 then
            imgui.TextDisabled 'Inventory is empty or unavailable.'
        end
        for _, row in ipairs(rows) do
            if state.drop_ids[row.id] then
                imgui.TextDisabled 'Added'
            elseif imgui.SmallButton(('Add##inventory_%u_%u'):format(row.slot, row.id)) then
                add_drop_id(row.id)
            end
            imgui.SameLine()
            imgui.Text(('%s x%u [%u]'):format(row.name, row.count, row.id))
        end
        imgui.EndChild()
        imgui.TextWrapped 'Adding an item schedules matching stacks for removal. Dropping is destructive.'
    end
    imgui.End()
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
    draw_config_window()
    draw_inventory_window()

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
            save_rules(kind)
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
    elseif command:any('config', 'settings', 'ui') then
        state.config_open[1] = not state.config_open[1]
    elseif command:any('inventory', 'inv') then
        state.inventory_open[1] = not state.inventory_open[1]
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
        refresh_rules 'pass'
        refresh_rules 'drop'
        print_message 'Settings reloaded.'
    elseif command:any('help', 'h') then
        print_help()
    else
        print_help()
    end
end)
