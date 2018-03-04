-- query_latency.lua
-- TODO
-- - Actually show latency outliars ...
-- - Persist the Prepared Statement IDs to disk, or ask Cassandra > 3.11
--   from the system table
-- - Figure out lowest memory way to do this, separate capture + minimal
--   script which calls this one, or ... something else ...
-- - Support various protocol versions
--
-- Execute with:
--[[

tshark -q -X lua_script:query_latency.lua -i lo -w out -b filesize:10000 -b files:2 -f "tcp port 9042"

or to get all variables in the query:

PRINT_BINDS= tshark -q -X lua_script:query_latency.lua -i lo -w out -b filesize:10000 -b files:2 -f "tcp port 9042"

Options are controlled through environment variables

PRINT_BINDS. If set query bindings will be printed
DECODE_PREPARED . Do not attempt to decode prepared statements

]]--

print("Loading Real time CQL Latency Tracer")
lru = require('lru')
-- frame id -> query
query_cache = lru.new(100)

-- Doesn't exist in old tshark
-- tcp_data = Field.new("tcp.payload")
ip_hdr_len = Field.new("ip.hdr_len")
tcp_hdr_len = Field.new("tcp.hdr_len")

-- CQL fields
cql_query = Field.new("cql.string")
cql_opcode = Field.new("cql.opcode")
cql_query_id = Field.new("cql.query_id")
cql_query_cl = Field.new("cql.consistency")
cql_result_kind = Field.new("cql.result.kind")
cql_response_to = Field.new("cql.response_to")
cql_response_time = Field.new("cql.response_time")
cql_bytes = Field.new("cql.bytes")
cql_batch_type = Field.new("cql.batch_type")
cql_batch_query_size = Field.new("cql.batch_query_size")
cql_batch_query_type = Field.new("cql.batch_query_type")

-- query_id -> CQL statement
local prepared_statements = {}
-- packet id -> CQL statement
local pending_prepared_statements = {}

-- Consistency Levels
local cls = {
    [0x0000]    = "ANY",
    [0x0001]    = "ONE",
    [0x0002]    = "TWO",
    [0x0003]    = "THREE",
    [0x0004]    = "QUORUM",
    [0x0005]    = "ALL",
    [0x0006]    = "LOCAL_QUORUM",
    [0x0007]    = "EACH_QUORUM",
    [0x0008]    = "SERIAL",
    [0x0009]    = "LOCAL_SERIAL",
    [0x000A]    = "LOCAL_ONE",
}

-- batch types
local batch_types = {"LOGGED", "UNLOGGED", "COUNTER"}

-- Decoding options
local PRINT_BINDS = os.getenv('PRINT_BINDS')
local DECODE_PREPARED = os.getenv('DECODE_PREPARED')

function decode_batch(pinfo)
    if cql_query_id().value then
        local query = (
            batch_types[cql_batch_type().value + 1] ..
            " BATCH of " .. cql_batch_query_size().value .. " "
        )
        local query_bytes = {"NA"}
        local query_cl = cls[cql_query_cl().value]

        if prepared_statements[tostring(cql_query_id().value)] then
            query = query .. prepared_statements[tostring(cql_query_id().value)]
        else
            query = query .. tostring(cql_query_id().value)
        end
        if PRINT_BINDS then
            for i,b in ipairs({ cql_bytes() }) do
                query_bytes[i] = tostring(b.value)
            end
        end
        query_cache:set(
            pinfo.number, {query, query_cl, query_bytes}
        )
    end
end

function decode_prepared_statement(pinfo)
    if cql_query_id().value then
        local query
        local query_bytes = {"NA"}
        local query_cl = cls[cql_query_cl().value]

        if prepared_statements[tostring(cql_query_id().value)] then
            query = prepared_statements[tostring(cql_query_id().value)]
        else
            query = tostring(cql_query_id().value)
        end

        if PRINT_BINDS then
            for i,b in ipairs({ cql_bytes() }) do
                query_bytes[i] = tostring(b.value)
            end
        end

        query_cache:set(
            pinfo.number, {query, query_cl, query_bytes}
        )
    end
end

function decode_normal_statement(pinfo)
    if cql_query().value then
        local query = cql_query().value
        local query_cl = cls[cql_query_cl().value]
        local query_bytes = {"NA"}
        query_cache:set(
            pinfo.number, {query, query_cl, query_bytes}
        )
    end
end

function record_prepared_statement(pinfo)
    print("PENDING PREPARE", pinfo.number, cql_query())
    pending_prepared_statements[pinfo.number] = cql_query().value
end

function finalize_prepared_statement(pinfo, tvb)
    -- Earlier version of wireshark (< 2.4) don't have proper opcode
    -- Versions of wireshark <2.4 don't have tcp.payload either
    -- So we do it manually
    -- Fixed offset into the packet assuming tcp/ip
    -- Ethernet, IP, TCP = 14 + 20 + 32 = 66
    local base = 14 + ip_hdr_len().value + tcp_hdr_len().value
    -- 9 bytes in the header, and then 4 more for the result type
    local length = tvb:range(base + 13, 2):int()
    -- We then read the query_id directly out of the data
    local query_id = tvb:range(base + 15, length):bytes()
    local query = pending_prepared_statements[cql_response_to().value]
    prepared_statements[tostring(query_id)] = query
    pending_prepared_statements[cql_response_to().value] = nil
    print("PREPARED", tostring(query_id), query)
end

function decode_response()
    if cql_response_to() and query_cache:get(cql_response_to().value) then
        local query = query_cache:get(cql_response_to().value)
        local binds = query[3]
        local key = binds[1]
        if key ~= "NA" then
            if PRINT_BINDS then
                key = table.concat(binds, ':')
            end
        end

        print(string.format(
            "[%s][%s][BINDS=%s] took: [%s]s",
            query[1], query[2], key,
            cql_response_time().value)
        )
    end
end

-- Setup the capture
-- On each packet, decode the query and log it
local tap = Listener.new();
function tap.packet(pinfo, tvb)
    if cql_opcode() == nil then
        return
    end

    -- BATCH
    if cql_opcode().value == 13 then
        decode_batch(pinfo)
    -- EXECUTE
    elseif cql_opcode().value == 10 then
        decode_prepared_statement(pinfo)
    -- PREPARE
    elseif cql_opcode().value == 9 then
        record_prepared_statement(pinfo)
    -- RESULT
    elseif cql_opcode().value == 8 then
        if cql_result_kind().value == 4 and DECODE_PREPARED then
            finalize_prepared_statement(pinfo, tvb)
        else
            decode_response()
        end
    -- QUERY
    elseif cql_opcode().value == 7 then
        decode_normal_statement(pinfo)
    end
end

function tap.reset()
    print "GOT ROLLOVER"
    -- todo sync prepared statement state or somethin
end