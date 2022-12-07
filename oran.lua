---
-- (C) 2022 - Alex Xu (xuyc@sina.com)
--
-- configuration
local mu = 1
local eAxC_offset_prach = 32
local eAxC_offset_srs = 64
local MAX_ANT_NORMAL_UL = 3

-- window defined per symbol; in usec; [min,max]
local str_Tx_type = {"UL-C", "DL-C", "DL-U"}
local Tx_wnd = {{125, 336}, {259, 669}, {172, 235}} -- {UL_CP, DL_CP,DL_UP}
-- local Tx_wnd = {{205, 642}, {277, 714}, {0, 0}} -- {UL_CP, DL_CP,DL_UP}
local Rx_wnd_up = {{0, 350}, {0, 1500}, {0, 1050}} -- {normal, prach,srs}

-- fields
local get_cus_type = Field.new("ecpri.type")
local get_cc_id = Field.new("oran_fh_cus.cc_id")
local get_ru_port = Field.new("oran_fh_cus.ru_port_id")
local get_time_epoch = Field.new("frame.time_epoch")
local get_frameId = Field.new("oran_fh_cus.frameId")
local get_subframe_id = Field.new("oran_fh_cus.subframe_id")
local get_slotId = Field.new("oran_fh_cus.slotId")
local get_startSymbolId = Field.new("oran_fh_cus.startSymbolId")
local get_data_direction = Field.new("oran_fh_cus.data_direction")
local get_numberOfSections = Field.new("oran_fh_cus.numberOfSections")
local get_numSymbol = Field.new("oran_fh_cus.numSymbol")

-- common functions
local function check_Tx_timing(idx, t)
    if t > Tx_wnd[idx][2] then
        return "EARLY"
    end
    if t < Tx_wnd[idx][1] then
        return "LATE"
    end
    return nil
end

local function check_Rx_timing(ru_port, t)
    local index = 1
    if ru_port >= eAxC_offset_srs then
        index = 3
    else
        if ru_port >= eAxC_offset_prach then
            index = 2
        end
    end

    if t < Rx_wnd_up[index][1] then
        return "EARLY"
    end
    if t > Rx_wnd_up[index][2] then
        return "LATE"
    end
    return nil
end

local function get_time_diff(isAdv)
    local epoch = tonumber(tostring(get_time_epoch()))
    local gps_epoch = epoch - 315964782
    local sfn = math.floor(gps_epoch * 100) % 256
    local offset = math.floor(gps_epoch * 10 ^ 6) % 10000 -- offset in usec inside the frame,
    local baseline = get_subframe_id().value * 1000 + get_slotId().value * (1000 / 2 ^ mu) + get_startSymbolId().value * (1000 / (2 ^ mu * 14))
    baseline = math.floor(baseline)
    local frameId = get_frameId().value
    if isAdv then
        local time_in_advance = baseline - offset
        if frameId ~= sfn then
            time_in_advance = time_in_advance + ((frameId + 256 - sfn) % 256) * 10000
        end
        return time_in_advance
    else
        local time_lag = offset - baseline
        if frameId ~= sfn then
            time_lag = time_lag + ((256 + sfn - frameId) % 256) * 10000
        end
        return time_lag
    end
end

local function compose_ru_port()
    -- the cc_id and ru_port is fixed to 4 bits
    return get_cc_id().value * 16 + get_ru_port().value
end

-- 
-- Taps
--
local function menuable_TX_timing()
    local tw = TextWindow.new("DU Tx timing check")
    local text = "packet\tANT\tDIR\tstatus\tahead\n"

    -- ecpri.type ONLY
    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        -- this way we remove the listener that otherwise will remain running indefinitely
        tap:remove();
    end

    -- we tell the window to call the remove() function when closed
    tw:set_atclose(remove)

    -- this function will be called once for each packet
    function tap.packet(pinfo, tvb)
        local ru_port = compose_ru_port()
        local cus_type = get_cus_type().value
        local data_direction = get_data_direction().value
        if cus_type == 0x02 or (cus_type == 0 and data_direction == 1) then
            local time_in_advance = get_time_diff(true)
            local idx = 3
            if cus_type == 0x02 then
                idx = data_direction + 1
            end
            local result = check_Tx_timing(idx, time_in_advance)
            if result then
                text = text .. pinfo.number .. "\t" .. ru_port .. "\t" .. str_Tx_type[idx] .. "\t" .. result .. "\t" .. time_in_advance .. "\n"
            end
        end
    end

    retap_packets()
    tw:set(text)
end

local function menuable_UL_timing()
    local tw = TextWindow.new("DU Rx timing check")
    local text = "packet\tANT\tstatus\tlag\n"
    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    tw:set_atclose(remove)

    function tap.packet(pinfo, tvb)
        local ru_port = compose_ru_port()
        if get_cus_type().value == 0 and get_data_direction().value == 0 then
            local time_lag = get_time_diff(false)
            local result = check_Rx_timing(ru_port, time_lag)
            if result then
                text = text .. pinfo.number .. "\t" .. ru_port .. "\t" .. result .. "\t" .. time_lag .. "\n"
            end
        end
    end

    retap_packets()
    tw:set(text)
end

-- don't support symInc
-- don't support  transport layer fraagmentatin
-- don't support  multi-section in u-plane
local function menuable_UL_missing()
    local tw = TextWindow.new("UL u-plane missing check")
    local text = "packet\tANT\tmissing@Symbols\n"
    local last_slot, last_ru_port = -1, -1
    local NUM_SLOT = 10 * 2 ^ mu -- number of slot in a frame
    local t_cplane = {}

    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    tw:set_atclose(remove)

    function is_nSlot_before(i, slot, n)
        result = false
        if slot - n >= 0 then
            return i <= slot and i >= slot - n
        else
            return i <= slot or i >= slot - n + NUM_SLOT
        end
    end

    function check_missing_per_ant(slot, ru_port, packet_no)
        local str_missing = t_cplane[slot][ru_port][14] .. "\t" .. ru_port .. "\t"
        local missing = false
        for i = 0, 13 do -- chehck missing,per symbol
            if t_cplane[slot][ru_port][i] > 0 then
                str_missing = str_missing .. i .. ","
                missing = true
            end
        end
        if missing then
            text = text .. str_missing .. "\n"
        end
        t_cplane[slot][ru_port] = nil

    end

    function check_missing(slot, packet_no)
        for i in pairs(t_cplane) do
            if t_cplane[i] and (not is_nSlot_before(i, slot, 2)) then
                for ant = 0, MAX_ANT_NORMAL_UL do
                    if t_cplane[i][ant] then
                        check_missing_per_ant(i, ant, packet_no)
                    end
                end
            end -- normal IQ

            if t_cplane[i] and (not is_nSlot_before(i, slot, 5)) then
                for ant in pairs(t_cplane[i]) do
                    if ant >= eAxC_offset_prach then
                        check_missing_per_ant(i, ant, packet_no)
                    end
                end
            end -- prach/srs
        end -- loop
    end

    function tap.packet(pinfo, tvb)
        if get_data_direction().value == 1 then
            return -- UL only
        end

        local ru_port = compose_ru_port()
        local cus_type = get_cus_type().value
        local slot = (get_subframe_id().value * 2 ^ mu + get_slotId().value)
        local startSymbolId = get_startSymbolId().value

        if cus_type == 0x02 then -- c-plane
            if slot ~= last_slot then
                check_missing(slot, pinfo.number)
            end
            if slot ~= last_slot or ru_port ~= last_ru_port then
                t_cplane[slot] = t_cplane[slot] or {}
                if t_cplane[slot][ru_port] == nil then
                    t_cplane[slot][ru_port] = {
                        [0] = 0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        pinfo.number
                    }
                end
                last_slot, last_ru_port = slot, ru_port
            end

            local numberOfSections = get_numberOfSections().value -- don't support symInc = 1
            local numSymbol = get_numSymbol().value
            for i = startSymbolId, startSymbolId + numSymbol - 1 do
                if t_cplane[slot][ru_port] then
                    t_cplane[slot][ru_port][i] = t_cplane[slot][ru_port][i] + numberOfSections
                end
            end
        end -- c-plane

        -- UL u-plane
        if cus_type == 0 and t_cplane[slot] and t_cplane[slot][ru_port] then
            t_cplane[slot][ru_port][startSymbolId] = t_cplane[slot][ru_port][startSymbolId] - 1 -- only 1 section allowed
        end
    end

    function tap.draw(t)
        tw:set(text)
    end

    function tap.reset()
        tw:clear()
    end

    retap_packets()
end

-- register menu
register_menu("ORAN/DU Tx timing", menuable_TX_timing, MENU_TOOLS_UNSORTED)
register_menu("ORAN/UL timing", menuable_UL_timing, MENU_TOOLS_UNSORTED)
register_menu("ORAN/UL missing ", menuable_UL_missing, MENU_TOOLS_UNSORTED)
