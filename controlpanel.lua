mon = peripheral.find("monitor")
if not mon then error("monitor not found! check your wired modems.") end

print("Using monitor: " .. tostring(peripheral.getName(mon)) .. "; starting operative task.")

mon.setTextScale(1)
local width, height = mon.getSize()
local old_term = term.redirect(mon)

local IO_SIDE = "front"

local config = {}
if fs.exists("config.json") then
    local file = fs.open("config.json", "r")
    config = textutils.unserializeJSON(file.readAll())
    file.close()
else
    error("error: config.json not found!")
end

local active_relays = { peripheral.find("redstone_relay") }
local start_hardware_registry = {}
local current_hardware_map = {}
for _, r in ipairs(active_relays) do
    start_hardware_registry[peripheral.getName(r)] = true
end

local count_fire = 0
local count_fault = 0
local global_fire_alarm = false
local global_fault_state = false
local manual_notification = false
local manual_firefighting = false

local pt_trigger_start = false
local pt_trigger_stop = false
local pt_pulse_timer = 0

local notification_fault = false
local firefighting_fault = false
local notification_fault_latched = false
local firefighting_fault_latched = false

local zone_db = {}
for _, z in ipairs(config.zones) do
    zone_db[z.id] = {
        name = z.name,
        inputs = z.inputs,
        status = "OK",
        active_address = "",
        col = z.col or 1,
        x_min = 0, x_max = 0, y_min = 0, y_max = 0, box_width = 0,
        was_fire = false,
        fault_latched = false
    }
end

local grid_width = 60
local box_w = math.floor(grid_width / 2) - 1

local col1_idx, col2_idx = 0, 0
for _, z in pairs(zone_db) do
    z.box_width = box_w
    if z.col == 1 then
        z.x_min = 2
        z.x_max = z.x_min + box_w - 1
        z.y_min = 8 + col1_idx * 5
        z.y_max = z.y_min + 3
        col1_idx = col1_idx + 1
    else
        z.x_min = box_w + 3
        z.x_max = z.x_min + box_w - 1
        z.y_min = 8 + col2_idx * 5
        z.y_max = z.y_min + 3
        col2_idx = col2_idx + 1
    end
end

local control_panel = {
    x_min = grid_width + 3, x_max = width - 1,
    btn_fire =    { y = 8,  label = "[ Manual fire     ]", active = false },
    btn_mute =    { y = 12, label = "[ Mute alarm      ]",  active = false },
    btn_pt =      { y = 16, label = "[ St./res. suppr. ]", active = false },
    btn_reset =   { y = 22, label = "[ Reset fire      ]", active = false },
    btn_fault =   { y = 26, label = "[ Reset fault     ]", active = false }
}

local function blit_line(x, y, len, text, fg, bg)
    if not text then text = "" end
    if not fg then fg = "f" end
    if not bg then bg = "f" end
    local f_text = text .. string.rep(" ", len - #text)
    term.setCursorPos(x, y)
    term.blit(f_text:sub(1, len), string.rep(fg, len), string.rep(bg, len))
end

local function render_ui()
    for y = 1, height do blit_line(1, y, width, "", "f", "f") end

    blit_line(1, 2, width, string.rep("=", width), "0", "7")
    blit_line(1, 3, width, "  " .. (config.system_title or "Operative task"))
    blit_line(1, 4, width, string.rep("=", width), "0", "7")

    for y = 6, height - 3 do
        blit_line(grid_width + 1, y, 1, "|", "8", "f")
    end

    for _, z in pairs(zone_db) do
        local bg, fg = "d", "f"
        local stat = "State: OK        "

        if z.status == "FIRE" then
            bg, fg = "e", "0"
            stat = "Fire: " .. z.active_address:sub(1, z.box_width - 9)
        elseif z.status == "FAULT" then
            bg, fg = "1", "f"
            stat = "Fault: disconnected   "
        elseif z.status == "UNARMED" then
            bg, fg = "1", "0"
            stat = "Fault: fail to arm    "
        end

        blit_line(z.x_min, z.y_min,     z.box_width, "+" .. string.rep("-", z.box_width - 2) .. "+", fg, bg)
        blit_line(z.x_min, z.y_min + 1, z.box_width, "| ZONE: " .. z.name, fg, bg)
        blit_line(z.x_min, z.y_min + 2, z.box_width, "| " .. stat, fg, bg)
        blit_line(z.x_min, z.y_min + 3, z.box_width, "+" .. string.rep("-", z.box_width - 2) .. "+", fg, bg)
    end

    local p_len = width - (grid_width + 3)
    local p_x = grid_width + 3
    blit_line(p_x, 6, p_len, "----  Control  ----", "7", "f")

    local b = control_panel
    blit_line(p_x, b.btn_fire.y,  p_len, b.btn_fire.label,  "0", control_panel.btn_fire.active and "e" or "7")
    blit_line(p_x, b.btn_mute.y,  p_len, b.btn_mute.label,  "f", manual_notification and "e" or "7")
    blit_line(p_x, b.btn_pt.y,    p_len, b.btn_pt.label,    "0", manual_firefighting and "4" or "7")
    blit_line(p_x, b.btn_reset.y, p_len, b.btn_reset.label, "f", "8")
    blit_line(p_x, b.btn_fault.y, p_len, b.btn_fault.label, "f", "8")

    local bar_y = height - 1
    blit_line(1, bar_y - 1, width, string.rep("-", width), "8", "f")

    local stat_bg = "d"
    local stat_fg = "f"
    local system_mode = "Armed"

    if global_fire_alarm then
        stat_bg, stat_fg = "e", "0"
        system_mode = "Fire"
    elseif global_fault_state then
        stat_bg, stat_fg = "1", "f"
        system_mode = "Fault"
    end

    local fault_line = ""
    if notification_fault_latched then
        fault_line = fault_line .. "Notification fault "
    end
    if firefighting_fault_latched then
        fault_line = fault_line .. "Suppression fault "
    end
    if fault_line ~= "" then
        fault_line = " || " .. fault_line
    end

    local status_bar_text = string.format("  Active alarms: %02d  ||  Faults: %02d%s  ||  %s  ",
        count_fire, count_fault, fault_line, system_mode)
    blit_line(1, bar_y, width, status_bar_text, stat_fg, stat_bg)
end

local function hardware_polling_loop()
    while true do
        local current_relays = { peripheral.find("redstone_relay") }
        current_hardware_map = {}
        for _, r in ipairs(current_relays) do
            current_hardware_map[peripheral.getName(r)] = r
        end

        global_fault_state = false
        local fire_found_this_tick = false
        count_fire = 0
        count_fault = 0

        notification_fault = false
        firefighting_fault = false

        for z_id, z in pairs(zone_db) do
            local zone_has_fault = false
            local zone_has_fire = false
            local last_triggered_address = ""

            for _, r_name in ipairs(z.inputs) do
                if not current_hardware_map[r_name] then
                    zone_has_fault = true
                else
                    local relay_obj = current_hardware_map[r_name]
                    if relay_obj.getInput(IO_SIDE) then
                        zone_has_fire = true
                        last_triggered_address = r_name
                    end
                end
            end

            if zone_has_fault then
                if z.status == "FIRE" then
                    global_fault_state = true
                    count_fault = count_fault + 1
                    fire_found_this_tick = true
                    count_fire = count_fire + 1
                else
                    z.status = "FAULT"
                    z.fault_latched = true
                    global_fault_state = true
                    count_fault = count_fault + 1
                end
            elseif zone_has_fire then
                z.status = "FIRE"
                z.was_fire = true
                z.active_address = last_triggered_address
                fire_found_this_tick = true
                count_fire = count_fire + 1
            else
                if z.status == "FIRE" and z.was_fire then
                    fire_found_this_tick = true
                    count_fire = count_fire + 1
                elseif z.status == "FAULT" and z.fault_latched then
                    count_fault = count_fault + 1
                    global_fault_state = true
                elseif z.status ~= "UNARMED" then
                    z.status = "OK"
                    z.was_fire = false
                end
                if z.status == "UNARMED" then 
                    count_fault = count_fault + 1 
                end
            end
        end

        for _, r_name in ipairs(config.notification) do
            if not current_hardware_map[r_name] then
                notification_fault = true
                notification_fault_latched = true
            end
        end
        
        for _, r_name in ipairs(config.firefighting) do
            if not current_hardware_map[r_name] then
                firefighting_fault = true
                firefighting_fault_latched = true
            end
        end

        if notification_fault or firefighting_fault then
            global_fault_state = true
            count_fault = count_fault + 1
        end

        global_fire_alarm = fire_found_this_tick or control_panel.btn_fire.active

        if global_fire_alarm and not pt_trigger_start then
            pt_trigger_start = true
            pt_pulse_timer = os.startTimer(1.0)
            manual_firefighting = true
        end

        local n_signal = (global_fire_alarm and not manual_notification)
        for _, r_name in ipairs(config.notification) do
            local obj = current_hardware_map[r_name]
            if obj then obj.setOutput(IO_SIDE, n_signal) end
        end

        for _, r_name in ipairs(config.firefighting) do
            local obj = current_hardware_map[r_name]
            if obj then obj.setOutput(IO_SIDE, manual_firefighting) end
        end

        render_ui()

        if (global_fire_alarm and not manual_notification) or global_fault_state then
            local speaker = peripheral.find("speaker")
            if speaker then speaker.playSound("block.note_block.bell", 3.0, 3.0) end
        end
        os.sleep(0.2)
    end
end

local function touchscreen_loop()
    while true do
        local event, side, x, y = os.pullEvent()
        if event == "timer" and side == pt_pulse_timer then
            manual_firefighting = false
            if pt_trigger_stop then
                pt_trigger_stop = false
                pt_trigger_start = false
            end
        end
        if event == "monitor_touch" and side == peripheral.getName(mon) then
            local p = control_panel
            if x >= p.x_min and x <= p.x_max then
                if y == p.btn_fire.y then
                    p.btn_fire.active = not p.btn_fire.active
                    manual_notification = false
                elseif y == p.btn_mute.y then
                    if global_fire_alarm then
                        manual_notification = true
                    end
                elseif y == p.btn_pt.y then
                    manual_firefighting = not manual_firefighting
                elseif y == p.btn_reset.y then
                    p.btn_fire.active = false
                    manual_notification = false
                    
                    for _, z in pairs(zone_db) do
                        local still_active = false
                        for _, r_name in ipairs(z.inputs) do
                            local obj = current_hardware_map[r_name]
                            if obj and obj.getInput(IO_SIDE) then
                                still_active = true
                            end
                        end
                        
                        if still_active then 
                            z.status = "FIRE"
                            z.was_fire = true
                            global_fire_alarm = true
                        else 
                            if z.status == "FAULT" and z.fault_latched then
                                z.status = "FAULT"
                            else
                                z.status = "OK"
                                z.was_fire = false
                            end
                        end
                    end
                elseif y == p.btn_fault.y then
                    for _, z in pairs(zone_db) do
                        if z.status == "UNARMED" or (z.status == "FAULT" and z.fault_latched) then
                            local still_active = false
                            for _, r_name in ipairs(z.inputs) do
                                local obj = current_hardware_map[r_name]
                                if obj and obj.getInput(IO_SIDE) then
                                    still_active = true
                                end
                            end
                            if still_active then
                                z.status = "FIRE"
                                z.was_fire = true
                            else
                                z.status = "OK"
                                z.was_fire = false
                                z.fault_latched = false
                            end
                        end
                    end
                    
                    if notification_fault_latched then
                        local all_ok = true
                        for _, r_name in ipairs(config.notification) do
                            if not current_hardware_map[r_name] then
                                all_ok = false
                            end
                        end
                        if all_ok then
                            notification_fault_latched = false
                        end
                    end
                    
                    if firefighting_fault_latched then
                        local all_ok = true
                        for _, r_name in ipairs(config.firefighting) do
                            if not current_hardware_map[r_name] then
                                all_ok = false
                            end
                        end
                        if all_ok then
                            firefighting_fault_latched = false
                        end
                    end
                end
            end
            render_ui()
        end
    end
end

mon.clear()
parallel.waitForAny(hardware_polling_loop, touchscreen_loop)
term.redirect(old_term)
