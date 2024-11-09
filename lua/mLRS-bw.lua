--local toolName = "TNS|mLRS Configurator|TNE"
----------------------------------------------------------------------
-- Copyright (c) MLRS project
-- GPL3
-- https://www.gnu.org/licenses/gpl-3.0.de.html
-- OlliW @ www.olliw.eu
-- modify for B/W screen by Jason Wang
-- multi-page by Brad Bosch
----------------------------------------------------------------------
-- Lua TOOLS script
----------------------------------------------------------------------
-- copy script to SCRIPTS\TOOLS folder on OpenTx SD card
-- works with OTX, ETX, mOTX v33

-- local version = '2024-11-07.00'

local required_tx_mLRS_version_int = 1000 -- 'v1.0.0'
local required_rx_mLRS_version_int = 1000 -- 'v1.0.0'

-- experimental
local paramLoadDeadTime_10ms = 400 -- 150 was a bit too short
local disableParamLoadErrorWarnings = false

----------------------------------------------------------------------
-- black/white helper
----------------------------------------------------------------------
local Current_Page = 0
local Max_Page = 6 -- It would be nice if MBRIDGE_CMD_INFO message included the number of parameters so we could calcuate this

-- idxes of options on main page
local BindPhrase_idx = 0 -- must not be changed

-- tools (max 4)
local Bind_main_idx = 4
local Boot_main_idx = 5

-- save/load/nav (max 4)
local Next_main_idx = 9

local Save_idx = 7
local Reload_idx = 8
local Prev_idx = 9
local Next_idx = 10

local PAGE_MAIN_CURSOR_IDX_PARAM_MAX = 3
local PAGE_CURSOR_IDX_PARAM_MAX = 6
local PAGE_CURSOR_IDX_MAX = Next_idx -- 10

-- convert param id to param list index
local function param_idx_to_list_index(param_id, page)
    if page == 0 then
        count = 4
        idx = param_id
    else
        count = 7
        idx = param_id + 3 - page * count
    end
    if idx < count and idx >= 0 then return true, idx; end
    return false
end

-- convert param list index to cmd id
local function list_index_to_param_idx(idx, page)
    if page == 0 then
        count = 4
        parm_idx = idx
    else
        count = 7
        parm_idx = idx + page * count - 3
    end
    if idx < count and idx >= 0 then return true, parm_idx; end
    return false
end

--------lines and colors
-- local CUSTOM_COLOR = INVERS
local TEXT_COLOR = 0
local MENU_TITLE_COLOR = INVERS
-- local TEXT_DISABLE_COLOR = 0

local function liney(line)
    return 8*line;
end


----------------------------------------------------------------------
-- MBridge CRSF emulation
----------------------------------------------------------------------

local MBRIDGE_COMMANDPACKET_STX  = 0xA0
local MBRIDGE_COMMANDPACKET_MASK = 0xE0

local MBRIDGE_CMD_TX_LINK_STATS_LEN  = 22
local MBRIDGE_CMD_DEVICE_ITEM_LEN    = 24
local MBRIDGE_CMD_PARAM_ITEM_LEN     = 24
local MBRIDGE_CMD_REQUEST_CMD_LEN    = 18
local MBRIDGE_CMD_INFO_LEN           = 24
local MBRIDGE_CMD_PARAM_SET_LEN      = 7
local MBRIDGE_CMD_MODELID_SET_LEN    = 3

local MBRIDGE_PARAM_TYPE_UINT8       = 0
local MBRIDGE_PARAM_TYPE_INT8        = 1
local MBRIDGE_PARAM_TYPE_UINT16      = 2
local MBRIDGE_PARAM_TYPE_INT16       = 3
local MBRIDGE_PARAM_TYPE_LIST        = 4
local MBRIDGE_PARAM_TYPE_STR6        = 5

local MBRIDGE_CMD_TX_LINK_STATS      = 2
local MBRIDGE_CMD_REQUEST_INFO       = 3
local MBRIDGE_CMD_DEVICE_ITEM_TX     = 4
local MBRIDGE_CMD_DEVICE_ITEM_RX     = 5
local MBRIDGE_CMD_PARAM_REQUEST_LIST = 6
local MBRIDGE_CMD_PARAM_ITEM         = 7
local MBRIDGE_CMD_PARAM_ITEM2        = 8
local MBRIDGE_CMD_PARAM_ITEM3        = 9
local MBRIDGE_CMD_REQUEST_CMD        = 10
local MBRIDGE_CMD_INFO               = 11
local MBRIDGE_CMD_PARAM_SET          = 12
local MBRIDGE_CMD_PARAM_STORE        = 13
local MBRIDGE_CMD_BIND_START         = 14
local MBRIDGE_CMD_BIND_STOP          = 15
local MBRIDGE_CMD_MODELID_SET        = 16
local MBRIDGE_CMD_SYSTEM_BOOTLOADER  = 17

local function mbridgeCmdLen(cmd)
    if cmd == MBRIDGE_CMD_TX_LINK_STATS then return MBRIDGE_CMD_TX_LINK_STATS_LEN; end
    if cmd == MBRIDGE_CMD_REQUEST_INFO then return 0; end
    if cmd == MBRIDGE_CMD_DEVICE_ITEM_TX then return MBRIDGE_CMD_DEVICE_ITEM_LEN; end
    if cmd == MBRIDGE_CMD_DEVICE_ITEM_RX then return MBRIDGE_CMD_DEVICE_ITEM_LEN; end
    if cmd == MBRIDGE_CMD_PARAM_REQUEST_LIST then return 0; end
    if cmd == MBRIDGE_CMD_PARAM_ITEM then return MBRIDGE_CMD_PARAM_ITEM_LEN; end
    if cmd == MBRIDGE_CMD_PARAM_ITEM2 then return MBRIDGE_CMD_PARAM_ITEM_LEN; end
    if cmd == MBRIDGE_CMD_PARAM_ITEM3 then return MBRIDGE_CMD_PARAM_ITEM_LEN; end
    if cmd == MBRIDGE_CMD_REQUEST_CMD then return MBRIDGE_CMD_REQUEST_CMD_LEN; end
    if cmd == MBRIDGE_CMD_INFO then return MBRIDGE_CMD_INFO_LEN; end
    if cmd == MBRIDGE_CMD_PARAM_SET then return MBRIDGE_CMD_PARAM_SET_LEN; end
    if cmd == MBRIDGE_CMD_PARAM_STORE then return 0; end
    if cmd == MBRIDGE_CMD_BIND_START then return 0; end
    if cmd == MBRIDGE_CMD_BIND_STOP then return 0; end
    if cmd == MBRIDGE_CMD_MODELID_SET then return MBRIDGE_CMD_MODELID_SET_LEN; end
    if cmd == MBRIDGE_CMD_SYSTEM_BOOTLOADER then return 0; end
    return 0;
end

local function isConnected()
    if getRSSI() ~= 0 then return true end
    return false
end

local function cmdPush(cmd, payload)
    -- 'O', 'W', len/cmd, payload bytes
    local data = { 79, 87, cmd + MBRIDGE_COMMANDPACKET_STX }
    for i=1, mbridgeCmdLen(cmd) do data[#data + 1] = 0 end -- fill with zeros of correct length
    for i=1, #payload do data[3 + i] = payload[i] end -- fill in data
    -- crossfireTelemetryPush() extends it to
    -- 0xEE, len, 129, 'O', 'W', len/cmd, payload bytes, crc8
    return crossfireTelemetryPush(129, data)
end

local function cmdPop()
    -- crossfireTelemetryPop() is invoked if
    -- address = RADIO_ADDRESS (0xEA) or UART_SYNC (0xC8)
    -- frame id != normal crsf telemetry sensor id
    -- 0xEE, len, 130, len/cmd, payload bytes, crc8
    local cmd, data = crossfireTelemetryPop()
    -- cmd = 130
    -- data = len/cmd, payload bytes
    if cmd == nil then return nil end
    if data == nil or data[1] == nil then return nil end -- Huston, we have a problem
    local command = data[1] - MBRIDGE_COMMANDPACKET_STX
    local res = {
        cmd = command,
        len = mbridgeCmdLen(command),
        payload = {}
    }
    for i=2, #data do res.payload[i-2] = data[i] end
    return res
end


----------------------------------------------------------------------
-- Info/Warning box
----------------------------------------------------------------------

local popup = false
local popup_text = ""
local popup_t_end_10ms = -1

local function setPopup(txt)
    popup = true
    popup_text = txt
    popup_t_end_10ms = getTime() + 150
end

local function setPopupWTmo(txt, tmo_10ms)
    popup = true
    popup_text = txt
    popup_t_end_10ms = getTime() + tmo_10ms
end

local function setPopupBlocked(txt)
    popup = true
    popup_text = txt
    popup_t_end_10ms = -1
end

local function isPopupBlocked()
    if popup and popup_t_end_10ms < 0 then return true; end
    return false;
end

local function clearPopup()
    popup = false
end

local function drawPopup()
    lcd.drawFilledRectangle(0, liney(1)+2, LCD_W, liney(4)-2, SOLID)

    local i = string.find(popup_text, "\n")
    local attr = MENU_TITLE_COLOR+MIDSIZE
    if i == nil then
        lcd.drawText(2, liney(1)+2, popup_text, attr)
    else
        local t1 = string.sub(popup_text, 1,i-1)
        local t2 = string.sub(popup_text, i+1)
        lcd.drawText(2, liney(1)+4, t1, attr)
        lcd.drawText(2, liney(1)+4+12, t2, attr)
    end
end

local function doPopup()
    if popup then
        drawPopup()
        if popup_t_end_10ms > 0 then
            local t_10ms = getTime()
            if t_10ms > popup_t_end_10ms then clearPopup() end
        end
    end
end


----------------------------------------------------------------------
-- helper to handle connect
----------------------------------------------------------------------

local connected = false
local connected_has_changed = false
local has_connected = false
local has_disconnected = false

local function doConnected()
    local is_connected = isConnected()

    connected_has_changed = false
    if is_connected ~= connected then connected_has_changed = true end

    has_connected = false
    if connected_has_changed and is_connected then has_connected = true end

    has_disconnected = false
    if connected_has_changed and not is_connected then has_disconnected = true end

    connected = is_connected
end


----------------------------------------------------------------------
-- variables for mBridge traffic
----------------------------------------------------------------------

local paramloop_t_last = 0
local DEVICE_ITEM_TX = nil
local DEVICE_ITEM_RX = nil
local DEVICE_INFO = nil
local DEVICE_PARAM_LIST = nil
local extra_payload = nil
local list_index = 0
local param_index_current = -1
local DEVICE_PARAM_LIST_error = 0
local DEVICE_PARAM_LIST_complete = false
local DEVICE_DOWNLOAD_is_running = true -- we start the script with this
local DEVICE_SAVE_t_last = 0
local mem_max1 = 0
local mem_max2 = 0

local function checkmem()
    local mem = collectgarbage("count")
    if mem > mem_max1 then mem_max1 = mem end
    collectgarbage("collect")
    local mem = collectgarbage("count")
    if mem > mem_max2 then mem_max2 = mem end
end

local function clearParams()
    checkmem()
    DEVICE_ITEM_TX = nil
    DEVICE_ITEM_RX = nil
    DEVICE_INFO = nil
    DEVICE_PARAM_LIST = nil
    list_index = 0
    param_index_current = -1
    DEVICE_PARAM_LIST_error = 0
    DEVICE_PARAM_LIST_complete = false
    DEVICE_DOWNLOAD_is_running = true
end


local function paramsError(err)
    DEVICE_PARAM_LIST_error = DEVICE_PARAM_LIST_error * 100 + err
end


----------------------------------------------------------------------
-- helper to convert command payloads
----------------------------------------------------------------------

local function mb_to_string(payload,pos,len)
    local str = ""
    for i = 0,len-1 do
        if payload[pos+i] == 0 then break end
        str = str .. string.char(payload[pos+i])
    end
    return str
end

local function mb_to_u8(payload, pos)
    return payload[pos]
end

local function mb_to_i8(payload, pos)
    local v = payload[pos+0]
    if v >= 128 then v = v - 256 end
    return v
end

local function mb_to_u16(payload, pos)
    return payload[pos+0] + payload[pos+1]*256
end

local function mb_to_i16(payload, pos)
    local v = payload[pos+0] + payload[pos+1]*256
    if v >= 32768 then v = v - 65536 end
    return v
end

local function mb_to_value(payload, pos, typ)
    if typ == MBRIDGE_PARAM_TYPE_UINT8 then -- UINT8
        return mb_to_u8(payload,pos)
    elseif typ == MBRIDGE_PARAM_TYPE_INT8 then -- INT8
        return mb_to_i8(payload,pos)
    elseif typ == MBRIDGE_PARAM_TYPE_UINT16 then -- UINT16
        return mb_to_u16(payload,pos)
    elseif typ == MBRIDGE_PARAM_TYPE_INT16 then -- INT16
        return mb_to_i16(payload,pos)
    elseif typ == MBRIDGE_PARAM_TYPE_LIST then -- LIST
        return payload[pos+0]
    end
    return 0
end

local function mb_to_value_or_str6(payload, pos, typ)
    if typ == 5 then --MBRIDGE_PARAM_TYPE_STR6 then
        return mb_to_string(payload,pos,6)
    else
        return mb_to_value(payload,pos,typ)
    end
end

local function mb_to_options(payload, pos, len)
    local r = {}
    local idx = 0
    local opt = ''
    for i = 0,len-1 do
        if payload[pos+i] == 0 then break end
        if payload[pos+i] == 44 then -- 44 = ','
            r[idx] = opt
            idx = idx + 1
            opt = ''
        else
          opt = opt .. string.char(payload[pos+i])
        end
    end
    r[idx] = opt
    return r
end

local function mb_to_firmware_u16_int(u16)
    local major = bit32.rshift(bit32.band(u16, 0xF000), 12)
    local minor = bit32.rshift(bit32.band(u16, 0x0FC0), 6)
    local patch = bit32.band(u16, 0x003F)
    return major * 10000 + minor * 100 + patch
end

local function mb_to_firmware_u16_string(u16)
    local major = bit32.rshift(bit32.band(u16, 0xF000), 12)
    local minor = bit32.rshift(bit32.band(u16, 0x0FC0), 6)
    local patch = bit32.band(u16, 0x003F)
    return string.format("v%d.%d.%02d", major, minor, patch)
end

local function mb_to_u8_bits(payload, pos, bitpos, bitmask)
    local v = payload[pos]
    v = bit32.rshift(v, bitpos)
    v = bit32.band(v, bitmask)
    return v
end

local function mb_allowed_mask_editable(allowed_mask)
    -- if none or only one option allowed -> not editable
    if allowed_mask == 0 then return false; end
    if allowed_mask == 1 then return false; end
    if allowed_mask == 2 then return false; end
    if allowed_mask == 4 then return false; end
    if allowed_mask == 8 then return false; end
    if allowed_mask == 16 then return false; end
    if allowed_mask == 32 then return false; end
    if allowed_mask == 64 then return false; end
    if allowed_mask == 128 then return false; end
    if allowed_mask == 256 then return false; end
    return true
end


----------------------------------------------------------------------
-- looper to send and read command frames
----------------------------------------------------------------------

local function doParamLoop(page)
    -- trigger getting device items and param items
    local t_10ms = getTime()
    if t_10ms - paramloop_t_last > 15 then -- was 10 = 100 ms
      paramloop_t_last = t_10ms
      if t_10ms < DEVICE_SAVE_t_last + paramLoadDeadTime_10ms then
          -- skip, we don't send a cmd if the last Save was recent
      elseif DEVICE_ITEM_TX == nil and page == 0 then
          cmdPush(MBRIDGE_CMD_REQUEST_INFO, {}) -- triggers sending DEVICE_ITEM_TX, DEVICE_ITEM_RX, INFO
      else
          if DEVICE_INFO ~= nil or page ~= 0 then -- wait for it to be populated
              extra_payload = nil
              if DEVICE_PARAM_LIST == nil then
                  DEVICE_PARAM_LIST = {}
              end
              local valid, param_item = list_index_to_param_idx(list_index, page)
              if valid then
                  cmdPush(MBRIDGE_CMD_REQUEST_CMD, {MBRIDGE_CMD_PARAM_ITEM, param_item})
              else
                  DEVICE_PARAM_LIST_complete = true
                  DEVICE_DOWNLOAD_is_running = false
                  return
              end
          end
      end
    end

    -- handle received commands
    for ijk = 1,6 do -- handle only up to 6 per lua cycle
        checkmem()
        local cmd = cmdPop()
        if cmd == nil then
            -- list_index = list_index + 1 -- error, skip?
            break
        end
        if cmd.cmd == MBRIDGE_CMD_DEVICE_ITEM_TX then
            DEVICE_ITEM_TX = cmd
            DEVICE_ITEM_TX.version_u16 = mb_to_u16(cmd.payload, 0)
            DEVICE_ITEM_TX.setuplayout = mb_to_u16(cmd.payload, 2)
            --DEVICE_ITEM_TX.name = mb_to_string(cmd.payload, 4, 20)
            DEVICE_ITEM_TX.version_int = mb_to_firmware_u16_int(DEVICE_ITEM_TX.version_u16)
            DEVICE_ITEM_TX.version_str = mb_to_firmware_u16_string(DEVICE_ITEM_TX.version_u16)
        elseif cmd.cmd == MBRIDGE_CMD_DEVICE_ITEM_RX then
            DEVICE_ITEM_RX = cmd
            DEVICE_ITEM_RX.version_u16 = mb_to_u16(cmd.payload, 0)
            DEVICE_ITEM_RX.setuplayout = mb_to_u16(cmd.payload, 2)
            --DEVICE_ITEM_RX.name = mb_to_string(cmd.payload, 4, 20)
            DEVICE_ITEM_RX.version_int = mb_to_firmware_u16_int(DEVICE_ITEM_RX.version_u16)
            DEVICE_ITEM_RX.version_str = mb_to_firmware_u16_string(DEVICE_ITEM_RX.version_u16)
        elseif cmd.cmd == MBRIDGE_CMD_INFO then
            DEVICE_INFO = cmd
            DEVICE_INFO.receiver_sensitivity = mb_to_i16(cmd.payload,0)
            -- DEVICE_INFO.has_status = mb_to_u8_bits(cmd.payload, 2, 0, 0x01)
            -- DEVICE_INFO.binding = mb_to_u8_bits(cmd.payload, 2, 1, 0x01)
            -- DEVICE_INFO.LQ_low = 0 -- mb_to_u8_bits(cmd.payload, 2, 3, 0x03)
            DEVICE_INFO.tx_power_dbm = mb_to_i8(cmd.payload,3)
            DEVICE_INFO.rx_power_dbm = mb_to_i8(cmd.payload,4)
            DEVICE_INFO.rx_available = mb_to_u8_bits(cmd.payload,5,0,0x1)
            --DEVICE_INFO.tx_diversity = mb_to_u8_bits(cmd.payload,5,1,0x3)
            --DEVICE_INFO.rx_diversity = mb_to_u8_bits(cmd.payload,5,3,0x3)
            DEVICE_INFO.tx_config_id = mb_to_u8(cmd.payload,6)
            DEVICE_INFO.tx_diversity = mb_to_u8_bits(cmd.payload,7,0,0x0F)
            DEVICE_INFO.rx_diversity = mb_to_u8_bits(cmd.payload,7,4,0x0F)
        elseif cmd.cmd == MBRIDGE_CMD_PARAM_ITEM then
            local param_index = cmd.payload[0]
            local valid, param_item = list_index_to_param_idx(list_index, page)
            list_index = list_index + 1 -- prepare for next
            if param_index ~= param_item then
                break -- unexpected skip
            end
            if DEVICE_PARAM_LIST == nil then
                paramsError(1)
            else
                local valid,index = param_idx_to_list_index(param_index, page)
                if valid then
                    param_index_current = param_index -- inform potential Item2/3 calls
                    DEVICE_PARAM_LIST[index] = cmd
                    DEVICE_PARAM_LIST[index].typ = mb_to_u8(cmd.payload, 1)
                    DEVICE_PARAM_LIST[index].name = mb_to_string(cmd.payload, 2, 16)
                    DEVICE_PARAM_LIST[index].value = mb_to_value_or_str6(cmd.payload, 18, DEVICE_PARAM_LIST[index].typ)
                    DEVICE_PARAM_LIST[index].min = 0
                    DEVICE_PARAM_LIST[index].max = 0
                    DEVICE_PARAM_LIST[index].unit = ""
                    DEVICE_PARAM_LIST[index].options = {}
                    DEVICE_PARAM_LIST[index].allowed_mask = 65536
                    DEVICE_PARAM_LIST[index].editable = true
                else
                    paramsError(2)
                end
            end
        elseif cmd.cmd == MBRIDGE_CMD_PARAM_ITEM2 then
            local param_index = cmd.payload[0]
            if param_index ~= param_index_current then
                paramsError(3)
            else
                local valid,index = param_idx_to_list_index(param_index, page)
                if valid then
                    if DEVICE_PARAM_LIST[index].typ < MBRIDGE_PARAM_TYPE_LIST then
                        DEVICE_PARAM_LIST[index].min = mb_to_value(cmd.payload, 1, DEVICE_PARAM_LIST[index].typ)
                        DEVICE_PARAM_LIST[index].max = mb_to_value(cmd.payload, 3, DEVICE_PARAM_LIST[index].typ)
                        DEVICE_PARAM_LIST[index].unit = mb_to_string(cmd.payload, 7, 6)
                    elseif DEVICE_PARAM_LIST[index].typ == MBRIDGE_PARAM_TYPE_LIST then
                        DEVICE_PARAM_LIST[index].allowed_mask = mb_to_u16(cmd.payload, 1)
                        DEVICE_PARAM_LIST[index].options = mb_to_options(cmd.payload, 3, 21)
                        extra_payload = cmd.payload
                        DEVICE_PARAM_LIST[index].min = 0
                        DEVICE_PARAM_LIST[index].max = #DEVICE_PARAM_LIST[index].options
                        DEVICE_PARAM_LIST[index].editable = mb_allowed_mask_editable(DEVICE_PARAM_LIST[index].allowed_mask)
                    elseif DEVICE_PARAM_LIST[index].typ == MBRIDGE_PARAM_TYPE_STR6 then
                        -- nothing to do, is sent but hasn't any content
                    else
                        paramsError(4)
                    end
                else
                    paramsError(5)
                end
            end
        elseif cmd.cmd == MBRIDGE_CMD_PARAM_ITEM3 then
            local param_index = cmd.payload[0]
            local is_item4 = false
            if (param_index >= 128) then -- this is actually ITEM4
                param_index = param_index - 128;
                is_item4 = true
            end
            if param_index ~= param_index_current then
                paramsError(6)
            else
                local valid,index = param_idx_to_list_index(param_index, page)
                if valid then
                    if DEVICE_PARAM_LIST[index].typ ~= MBRIDGE_PARAM_TYPE_LIST then
                        paramsError(7)
                    elseif extra_payload == nil then
                        paramsError(8)
                        -- paramsError(index)
                    else
                        if not is_item4 then
                            for i=1,23 do extra_payload[23+i] = cmd.payload[i] end
                            DEVICE_PARAM_LIST[index].options = mb_to_options(extra_payload, 3, 21+23)
                        else
                            for i=1,23 do extra_payload[23+23+i] = cmd.payload[i]; end
                            DEVICE_PARAM_LIST[index].options = mb_to_options(extra_payload, 3, 21+23+23)
                            extra_payload = nil
                        end
                        DEVICE_PARAM_LIST[index].max = #DEVICE_PARAM_LIST[index].options
                    end
                end
            end
        end
        cmd = nil
    end --for
    if DEVICE_PARAM_LIST_error > 0 then
        if not disableParamLoadErrorWarnings then -- ignore any errors
            -- Huston, we have a problem,
            DEVICE_PARAM_LIST_complete = false
            setPopupWTmo("Er("..tostring(DEVICE_PARAM_LIST_error)..")!\nTry Reload", 300)
        end
    end
end


local function sendParamSet(idx, page)
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    local valid,idx = list_index_to_param_idx(idx, page)
    if not valid then return end
    if p.typ < MBRIDGE_PARAM_TYPE_LIST then
        cmdPush(MBRIDGE_CMD_PARAM_SET, {idx, p.value})
    elseif p.typ == MBRIDGE_PARAM_TYPE_LIST then
        cmdPush(MBRIDGE_CMD_PARAM_SET, {idx, p.value})
    elseif p.typ == MBRIDGE_PARAM_TYPE_STR6 then
        local cmd = {idx}
        for i = 1,6 do
            cmd[i+1] = string.byte(string.sub(p.value, i,i))
        end
        cmdPush(MBRIDGE_CMD_PARAM_SET, cmd)
    end
end


local function sendParamStore()
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    cmdPush(MBRIDGE_CMD_PARAM_STORE, {})
    DEVICE_SAVE_t_last = getTime()
    setPopupWTmo("Save Parameters", 250)
end


local function sendBind()
    --if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    if DEVICE_DOWNLOAD_is_running then return end
    cmdPush(MBRIDGE_CMD_BIND_START, {})
    setPopupBlocked("Binding")
end


local function sendBoot()
    --if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    if DEVICE_DOWNLOAD_is_running then return end
    cmdPush(MBRIDGE_CMD_SYSTEM_BOOTLOADER, {})
    setPopupBlocked("In System Bootloader")
end


----------------------------------------------------------------------
-- Edit stuff
----------------------------------------------------------------------

local cursor_idx = Next_main_idx
local edit = false
local option_value = 0

local page_param_cnt = 0 -- number of parameters available on page

local cursor_x_idx = 0 -- index into string for string edits
local bindphrase_chars = "abcdefghijklmnopqrstuvwxyz0123456789_#-."


local function cur_attr(idx) -- used in menu
    local attr = TEXT_COLOR
    if cursor_idx == idx then
        attr = attr + INVERS
        if edit then attr = attr + BLINK end
    end
    return attr
end


local function cur_attr_x(idx, x_idx) -- for Bind Phrase character editing
    local attr = TEXT_COLOR
    if DEVICE_PARAM_LIST_complete and cursor_idx == idx then
        if edit then
            if cursor_x_idx == x_idx then attr = attr + BLINK + INVERS end
        else
            attr = attr + INVERS
        end
    end
    return attr
end


local function cur_attr_p(idx, pidx) -- used for parameters
    local attr = cur_attr(idx)
    return attr
end


local function param_value_inc(idx)
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    if p.typ < MBRIDGE_PARAM_TYPE_LIST then
        p.value = p.value + 1
    elseif p.typ == MBRIDGE_PARAM_TYPE_LIST then
        local value = p.value
        while value <= p.max do
            value = value + 1
            local m = bit32.lshift(1,value)
            if bit32.btest(m, p.allowed_mask) then p.value = value; break end
        end
    end
    if p.value > p.max then p.value = p.max end
    DEVICE_PARAM_LIST[idx].value = p.value
end


local function param_value_dec(idx)
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    if p.typ < MBRIDGE_PARAM_TYPE_LIST then
        p.value = p.value - 1
    elseif p.typ == MBRIDGE_PARAM_TYPE_LIST then
        local value = p.value
        while value >= p.min do
            value = value - 1
            local m = bit32.lshift(1,value)
            if bit32.btest(m, p.allowed_mask) then p.value = value; break end
        end
    end
    if p.value < p.min then p.value = p.min end
    DEVICE_PARAM_LIST[idx].value = p.value
end


local function param_str6_inc(idx)
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    if p.typ == MBRIDGE_PARAM_TYPE_STR6 then
        local c = string.sub(p.value, cursor_x_idx+1, cursor_x_idx+1)
        local i = string.find(bindphrase_chars, c, 1, true) -- true for plain search
        i = i + 1
        if i > string.len(bindphrase_chars) then i = 1 end
        c = string.sub(bindphrase_chars, i,i)
        p.value = string.sub(p.value, 1, cursor_x_idx) .. c .. string.sub(p.value, cursor_x_idx+2, string.len(p.value))
    end
    DEVICE_PARAM_LIST[idx].value = p.value
end


local function param_str6_dec(idx)
    if not DEVICE_PARAM_LIST_complete then return end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    if p.typ == MBRIDGE_PARAM_TYPE_STR6 then
        local c = string.sub(p.value, cursor_x_idx+1, cursor_x_idx+1)
        local i = string.find(bindphrase_chars, c, 1, true) -- true for plain search
        i = i - 1
        if i < 1 then i = string.len(bindphrase_chars) end
        c = string.sub(bindphrase_chars, i,i)
        p.value = string.sub(p.value, 1, cursor_x_idx) .. c .. string.sub(p.value, cursor_x_idx+2, string.len(p.value))
    end
    DEVICE_PARAM_LIST[idx].value = p.value
end


local function param_str6_next(idx)
    if not DEVICE_PARAM_LIST_complete then return false end -- needed here??
    local p = DEVICE_PARAM_LIST[idx]
    if p.typ == MBRIDGE_PARAM_TYPE_STR6 then
        cursor_x_idx = cursor_x_idx + 1
        if cursor_x_idx >= string.len(p.value) then
            return true -- last char
        end
    end
    return false
end


----------------------------------------------------------------------
-- Render Pages
----------------------------------------------------------------------

local function drawPage()
    local x, y
    local s = 0
    local param_max = PAGE_CURSOR_IDX_PARAM_MAX

    if DEVICE_DOWNLOAD_is_running then
        lcd.drawText(LCD_W/3, LCD_H-24, "MLRS", DBLSIZE+TEXT_COLOR+BLINK+INVERS)
        lcd.drawText(12, LCD_H-9, "parameters loading ...", TEXT_COLOR+BLINK+INVERS)
        return
    end

  if Current_Page == 0 then
    checkmem()
    param_max = PAGE_MAIN_CURSOR_IDX_PARAM_MAX
    local version_error = false
    if DEVICE_ITEM_TX ~= nil and DEVICE_ITEM_TX.version_int < required_tx_mLRS_version_int then
        version_error = true
        popup_text = "Tx version not supported\nby this Lua script!"
    end
    if DEVICE_ITEM_RX ~= nil and connected and DEVICE_ITEM_RX.version_int < required_rx_mLRS_version_int then
        version_error = true
        popup_text = "Rx version not supported\nby this Lua script!"
    end
    if version_error then
        drawPopup()
        return
    end

    y = liney(0)
    if DEVICE_PARAM_LIST_complete then
        --lcd.drawText(0, y, DEVICE_PARAM_LIST[0].name, TEXT_COLOR)
        lcd.drawText(0, y, "Phrase", TEXT_COLOR)
        for i = 1,6 do
            local c = string.sub(DEVICE_PARAM_LIST[0].value, i, i) -- param_idx = 0 = BindPhrase
            local attr = cur_attr_x(0, i-1)
            lcd.drawText(LCD_W*2/3+(i-1)*6, y, c, attr)
        end
    end
    s = 1
  end

    if DEVICE_PARAM_LIST_complete then
        for i=s,param_max do
            if DEVICE_PARAM_LIST[i] ~= nil and DEVICE_PARAM_LIST[i].name ~= nil then
                lcd.drawText(0, liney(i), string.sub(DEVICE_PARAM_LIST[i].name, 1, 14), TEXT_COLOR)
                if DEVICE_PARAM_LIST[i].typ < MBRIDGE_PARAM_TYPE_LIST then
                    lcd.drawText(LCD_W*2/3, liney(i), DEVICE_PARAM_LIST[i].value.." "..DEVICE_PARAM_LIST[i].unit, cur_attr(i))
                else
                    lcd.drawText(LCD_W*2/3, liney(i), DEVICE_PARAM_LIST[i].options[DEVICE_PARAM_LIST[i].value], cur_attr(i))
                end
            else
                lcd.drawText(LCD_W*2/3, liney(i), ".", cur_attr(i))
            end
        end
    end

  if Current_Page == 0 then
    y = liney(4)
    attr = SMLSIZE + TEXT_COLOR
    lcd.drawText(0, y, "TxPwr", attr)
    if DEVICE_INFO ~= nil then
        lcd.drawText(LCD_W/4, y, tostring(DEVICE_INFO.tx_power_dbm).."dBm", attr)
    else
        lcd.drawText(LCD_W/4, y, "--dBm", attr)
    end

    if DEVICE_ITEM_TX ~= nil then
        lcd.drawText(LCD_W/2, y, DEVICE_ITEM_TX.version_str, attr)
    else
        lcd.drawText(LCD_W/2, y, "v-.--.--", attr)
    end

    y = liney(5)
    lcd.drawText(0, y, "RxPwr", attr)
    if DEVICE_INFO ~= nil and DEVICE_INFO.rx_available then
        lcd.drawText(LCD_W/4, y, tostring(DEVICE_INFO.rx_power_dbm).."dBm", attr)
    else
        lcd.drawText(LCD_W/4, y, "--dBm", attr)
    end

    if not connected then
        lcd.drawText(LCD_W/2, y, "disconnected", attr)
    elseif not DEVICE_PARAM_LIST_complete then
        lcd.drawText(LCD_W/2, y, "loading..", attr)
    elseif DEVICE_ITEM_RX ~= nil then
        lcd.drawText(LCD_W/2, y, DEVICE_ITEM_RX.version_str, attr)
    else
        lcd.drawText(LCD_W/2, y, "v-.--.--", attr)
    end

    -- Tools
    y = liney(6)
    lcd.drawText(0, y, "bind", cur_attr(Bind_main_idx))
    lcd.drawText(LCD_W/4, y, "boot", cur_attr(Boot_main_idx))
    lcd.drawText(LCD_W/2, y, tostring(mem_max1), TEXT_COLOR)
    lcd.drawText(LCD_W*3/4, y, tostring(mem_max2), TEXT_COLOR)
  
  end
  
    -- Save/Load and Navigation
    y = liney(7)
    lcd.drawText(0, y, "save", cur_attr(Save_idx - s))
    lcd.drawText(LCD_W/4, y, "load", cur_attr(Reload_idx - s))
    lcd.drawText(LCD_W/2, y, "prev", cur_attr(Prev_idx - s))
    lcd.drawText(LCD_W*3/4, y, "next", cur_attr(Next_idx - s))
end

local function doPage(event)
    local s = 0
    if Current_Page == 0 then
      s = 1
    end

    if not edit then
        if event == EVT_VIRTUAL_EXIT then
            -- nothing to do
        elseif event == EVT_VIRTUAL_ENTER then
            if cursor_idx == Save_idx - s and DEVICE_PARAM_LIST_complete then -- Save pressed
                sendParamStore()
                clearParams()
            elseif Current_Page == 0 and cursor_idx == Bind_main_idx then -- Bind pressed
                sendBind()
            elseif Current_Page == 0 and cursor_idx == Boot_main_idx then -- Boot pressed
                sendBoot()
            elseif cursor_idx == Reload_idx - s then -- Reload pressed
                clearParams()
            elseif cursor_idx == Prev_idx - s then -- Prev pressed
                clearParams()
                Current_Page = Current_Page - 1
                if Current_Page == 0 then
                    cursor_idx = cursor_idx - 1 -- 1 fewer positions on page 0; move back to "next"
                end
                if Current_Page < 0 then
                    Current_Page = Max_Page
                    cursor_idx = cursor_idx + 1 -- 1 more positions on subsequent pages; move forward to "next"
                 end
            elseif cursor_idx == Next_idx - s then -- Next pressed
                clearParams()
                if Current_Page == 0 then
                    cursor_idx = cursor_idx + 1 -- 1 more positions on subsequent pages; move forward to "next"
                end
                Current_Page = Current_Page + 1
                if Current_Page > Max_Page then
                    Current_Page = 0
                    cursor_idx = cursor_idx - 1 -- 1 fewer positions on page 0; move back to "next"
                end
            elseif DEVICE_PARAM_LIST_complete then -- edit option
                cursor_x_idx = 0
                edit = true
            end
        elseif event == EVT_VIRTUAL_NEXT then -- and DEVICE_PARAM_LIST_complete then
            cursor_idx = cursor_idx + 1
            if cursor_idx > PAGE_CURSOR_IDX_MAX - s then cursor_idx = PAGE_CURSOR_IDX_MAX - s end
        elseif event == EVT_VIRTUAL_PREV then -- and DEVICE_PARAM_LIST_complete then
            cursor_idx = cursor_idx - 1
            if cursor_idx < 0 then cursor_idx = 0 end
        end
    else -- edit
        if event == EVT_VIRTUAL_EXIT then
            if cursor_idx <= PAGE_CURSOR_IDX_PARAM_MAX - 3 * s then -- BindPhrase, user defined params
                sendParamSet(cursor_idx, Current_Page)
            end
            edit = false
        elseif event == EVT_VIRTUAL_ENTER then
            if current_page == 0 and cursor_idx == BindPhrase_idx then -- BindPhrase
                if param_str6_next(0) then
                    sendParamSet(0, Current_Page)
                    edit = false
                end
            elseif cursor_idx <= PAGE_CURSOR_IDX_PARAM_MAX - 3 * s then -- user defined params
                sendParamSet(cursor_idx, Current_Page)
                edit = false
            else
                edit = false
            end
        elseif event == EVT_VIRTUAL_NEXT then
            if current_page == 0 and cursor_idx == BindPhrase_idx then -- BindPhrase
                param_str6_inc(0)
            elseif cursor_idx <= PAGE_CURSOR_IDX_PARAM_MAX - 3 * s then -- user defined params
                param_value_inc(cursor_idx)
            end
        elseif event == EVT_VIRTUAL_PREV then
            if current_page == 0 and cursor_idx == BindPhrase_idx then -- BindPhrase
                param_str6_dec(0)
            elseif cursor_idx <= PAGE_CURSOR_IDX_PARAM_MAX - 3 * s then -- user defined params
                param_value_dec(cursor_idx)
            end
        end
    end

    drawPage()
end

----------------------------------------------------------------------
----------------------------------------------------------------------

local function Do(event)
    lcd.clear()

    doConnected()

    if has_connected then
        clearParams()
        if not popup then setPopup("Receiver connected!") end
        if isPopupBlocked() then clearPopup() end
    end
    if has_disconnected then
        if not popup then setPopup("Receiver\nhas disconnected!") end
    end

    doParamLoop(Current_Page)
    doPage(event)

    doPopup()
end


----------------------------------------------------------------------
-- Script OTX Interface
----------------------------------------------------------------------

local function scriptInit()
    checkmem()
    DEVICE_DOWNLOAD_is_running = true -- we start the script with this
    local tnow_10ms = getTime()
    if tnow_10ms < 300 then
        DEVICE_SAVE_t_last = 300 - tnow_10ms -- treat script start like a Save
    else
        DEVICE_SAVE_t_last = 0
    end
end


local function scriptRun(event)
    checkmem()
    if event == nil then
        error("Cannot be run as a model script!")
        return 2
    end
    if model.getModule(1).Type ~= 5 then
        error("mLRS not accessible: CRSF not enabled!")
        return 2
    end

    if not edit then
        if event == EVT_VIRTUAL_EXIT then
            return 2
        end
    end

    Do(event)

    return 0
end

checkmem()
return { init=scriptInit, run=scriptRun }
