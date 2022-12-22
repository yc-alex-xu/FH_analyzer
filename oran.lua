---
-- (C) 2022 - Alex Xu (xuyc@sina.com)
--
-- configuration
local mu = 1
local eAxC_offset_prach = 32
local eAxC_offset_srs = 64

-- window defined per symbol; in usec; [min,max]
local str_Tx_type = {"UL-C", "DL-C", "DL-U"}
-- Table 6. Front Haul Interface Latency (numerology 1 - Sub6) from FlexRAN 22.11
local Tx_wnd = {{285, 429}, {285, 429}, {71, 428}} -- {UL_CP, DL_CP,DL_UP}
local Rx_wnd_up = {{0, 350}, {0, 1050}, {0, 1050}} -- {normal, prach,srs}

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

local function get_time_diff(isAdv, isSlotLevel)
    local epoch = tonumber(tostring(get_time_epoch()))
    local gps_epoch = epoch - 315964782
    local sfn = math.floor(gps_epoch * 100) % 256
    local offset = math.floor(gps_epoch * 10 ^ 6) % 10000 -- offset in usec inside the frame,
    local baseline = get_subframe_id().value * 1000
    if isSlotLevel then
        baseline = baseline + (get_slotId().value + 1) * (1000 / 2 ^ mu)
    else
        baseline = baseline + get_slotId().value * (1000 / 2 ^ mu) + get_startSymbolId().value * (1000 / (2 ^ mu * 14))
        baseline = math.floor(baseline)
    end
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

local function menuable_TX_timing()
    local tw = TextWindow.new("DU Tx timing check")
    local text = "packet\tcell\tANT\tDIR\tstatus\tahead(μs)\n"

    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    function tap.packet(pinfo, tvb)
        local cus_type = get_cus_type().value
        local data_direction = get_data_direction().value
        if cus_type == 0x02 or (cus_type == 0 and data_direction == 1) then
            local time_in_advance = get_time_diff(true, false)
            local idx = 3
            if cus_type == 0x02 then
                idx = data_direction + 1
            end
            local result = check_Tx_timing(idx, time_in_advance)
            if result then
                text = text .. pinfo.number .. "\t" .. get_cc_id().value .. "\t" .. get_ru_port().value .. "\t" .. str_Tx_type[idx] .. "\t" .. result .. "\t" .. time_in_advance .. "\n"
            end
        end
    end

    retap_packets()
    tw:set(text)
end

local function menuable_UL_timing()
    local tw = TextWindow.new("DU Rx timing check")
    local text = "packet\tcell\tANT\tSYM\tstatus\tlag(μs)\n"
    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    tw:set_atclose(remove)

    function tap.packet(pinfo, tvb)
        local ru_port = get_ru_port().value
        if get_cus_type().value == 0 and get_data_direction().value == 0 then
            local time_lag = get_time_diff(false, false)
            local result = check_Rx_timing(ru_port, time_lag)
            if result then
                text = text .. pinfo.number .. "\t" .. get_cc_id().value .. "\t" .. ru_port .. "\t" .. get_startSymbolId().value .. "\t" .. result .. "\t" .. time_lag .. "\n"
            end
        end
    end

    retap_packets()
    tw:set(text)
end

local function menuable_UL_timing_slot_level()
    local tw = TextWindow.new("DU Rx timing check")
    local text = "packet\tcell\tANT\tSYM\tstatus\tlag(μs)\n"
    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    tw:set_atclose(remove)

    function tap.packet(pinfo, tvb)
        local ru_port = get_ru_port().value
        if get_cus_type().value == 0 and get_data_direction().value == 0 then
            local time_lag = get_time_diff(false, true)
            local result = check_Rx_timing(ru_port, time_lag)
            if result == "LATE" then
                text = text .. pinfo.number .. "\t" .. get_cc_id().value .. "\t" .. ru_port .. "\t" .. get_startSymbolId().value .. "\t" .. result .. "\t" .. time_lag .. "\n"
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
    local text = "packet\tcell\tANT\tmissing@Symbols\n"
    local last_slot, last_idx = -1, -1
    local NUM_SLOT = 10 * 2 ^ mu -- number of slot in a frame
    local t_cplane = {}

    local tap = Listener.new("frame", "eth.type == 0xaefe");

    local function remove()
        tap:remove();
    end

    tw:set_atclose(remove)

    local function get_idx()
        return get_cc_id().value * 256 + get_ru_port().value
    end

    local function get_cell_from_idx(idx)
        return math.floor(idx / 256)
    end

    local function get_port_from_idx(idx)
        return idx % 256
    end

    local function is_n_slots_before(i, slot, n)
        if slot - n >= 0 then
            return i <= slot and i >= slot - n
        else
            return i <= slot or i >= slot - n + NUM_SLOT
        end
    end

    local function check_missing_per_eAxC(slot, idx, packet_no)
        local str_missing = ''
        local missing = false
        for i = 0, 13 do -- chehck missing,per symbol
            if t_cplane[slot][idx][i] > 0 then
                str_missing = str_missing .. i .. ","
                missing = true
            end
        end
        if missing then
            text = text .. t_cplane[slot][idx][14] .. "\t" .. get_cell_from_idx(idx) .. "\t" .. get_port_from_idx(idx) .. "\t" .. str_missing .. "\n"
        end
        t_cplane[slot][idx] = nil

    end

    local function check_missing(slot, packet_no)
        for i in pairs(t_cplane) do
            if t_cplane[i] and (not is_n_slots_before(i, slot, 2)) then
                for idx in pairs(t_cplane[i]) do
                    if get_port_from_idx(idx) < eAxC_offset_prach then
                        check_missing_per_eAxC(i, idx, packet_no)
                    end
                end
            end

            if t_cplane[i] and (not is_n_slots_before(i, slot, 5)) then
                for idx in pairs(t_cplane[i]) do
                    if get_port_from_idx(idx) >= eAxC_offset_prach then
                        check_missing_per_eAxC(i, idx, packet_no)
                    end
                end
            end
        end
    end

    function tap.packet(pinfo, tvb)
        if get_data_direction().value == 1 then
            return -- UL only
        end

        local idx = get_idx()
        local cus_type = get_cus_type().value
        local slot = (get_subframe_id().value * 2 ^ mu + get_slotId().value)
        local startSymbolId = get_startSymbolId().value

        if cus_type == 0x02 then -- c-plane
            if slot ~= last_slot then
                check_missing(slot, pinfo.number)
            end
            if slot ~= last_slot or idx ~= last_idx then
                t_cplane[slot] = t_cplane[slot] or {}
                if t_cplane[slot][idx] == nil then
                    t_cplane[slot][idx] = {
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
                last_slot, last_idx = slot, idx
            end

            local numberOfSections = get_numberOfSections().value -- don't support symInc = 1
            local numSymbol = get_numSymbol().value
            for i = startSymbolId, startSymbolId + numSymbol - 1 do
                if t_cplane[slot][idx] then
                    t_cplane[slot][idx][i] = t_cplane[slot][idx][i] + numberOfSections
                end
            end
        end -- c-plane

        -- UL u-plane
        if cus_type == 0 and t_cplane[slot] and t_cplane[slot][idx] then
            t_cplane[slot][idx][startSymbolId] = t_cplane[slot][idx][startSymbolId] - 1 -- only 1 section allowed
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
register_menu("ORAN/UL timing(slot level)", menuable_UL_timing_slot_level, MENU_TOOLS_UNSORTED)
register_menu("ORAN/UL timing", menuable_UL_timing, MENU_TOOLS_UNSORTED)
register_menu("ORAN/UL missing ", menuable_UL_missing, MENU_TOOLS_UNSORTED)
